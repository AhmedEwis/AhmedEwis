/// The ingestion pipeline:
/// source adapter → validation/filtering → normalization → parsing → account matching →
/// deduplication → financial classification → ledger posting or review queue → local
/// persistence (→ sync outbox) → analytics refresh (reactive streams).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../core/domain/categories.dart';
import '../core/ledger/ledger.dart';
import '../core/parsing/bank_registry.dart';
import '../core/parsing/kuwait_parser.dart';
import '../core/parsing/merchant_directory.dart';
import '../core/parsing/models.dart';
import 'db/database.dart';
import 'store.dart';

enum IngestOutcome { posted, merged, settledPending, review, ignored, duplicate, possibleDuplicate, failed }

class IngestResult {
  final IngestOutcome outcome;
  final String sourceEventId;
  final String? transactionId;
  final ParsedEvent? parsed;
  final String message;
  const IngestResult(this.outcome, this.sourceEventId, {this.transactionId, this.parsed, this.message = ''});
  @override
  String toString() => 'IngestResult($outcome tx=$transactionId $message)';
}

/// Optional cloud fallback for messages the deterministic parser can't read.
abstract class AiExtractor {
  /// Returns a parsed event or null. Implementations must sanitize text before sending
  /// and validate that every returned value is evidenced in the input.
  Future<ParsedEvent?> extract(RawEvent e);
}

class IngestionService {
  final FinanceStore store;
  final AiExtractor? ai;
  final int maxTextLength;

  /// Test hook: called at named stages inside the atomic section, to simulate a crash
  /// (by throwing) at the worst possible moment. Null in production.
  final void Function(String stage)? faultInjector;
  IngestionService(this.store, {this.ai, this.maxTextLength = 2000, this.faultInjector});

  AppDatabase get db => store.db;

  static String textHash(String text) =>
      sha256.convert(utf8.encode(normalizeForMatch(text).replaceAll(RegExp(r'\s+'), ' ').trim())).toString();

  Future<IngestResult> ingest(RawEvent e) async {
    final eventId = newId();
    final text = e.text.length > maxTextLength ? e.text.substring(0, maxTextLength) : e.text;
    final hash = textHash(e.source == SourceKind.wallet ? jsonEncode(e.fields ?? {}) : text);

    // Validation and filtering: empty input is rejected.
    if (text.trim().isEmpty && (e.fields == null || e.fields!.isEmpty)) {
      return IngestResult(IngestOutcome.ignored, eventId, message: 'empty');
    }

    // Fast replay check (no lock). The authoritative check is the claim inside the
    // transaction below, backed by the unique index on (source, platform_id).
    if (e.sourceId != null) {
      final dup = await _existingClaim(e);
      if (dup != null) {
        return IngestResult(IngestOutcome.duplicate, dup.id, transactionId: dup.transactionId, message: 'replayed event');
      }
    }

    // Parsing (and the optional network AI fallback) runs outside the database
    // transaction, so no lock is held during I/O.
    final aliases = await store.merchantAliasMap();
    final base = await store.baseCurrency();
    var parsed = KuwaitParser(homeCurrency: base, userAliases: aliases).parse(e);
    if ((parsed.kind == TxKind.unknown && parsed.confidence >= 0.3 || parsed.needsReview) && ai != null) {
      try {
        final aiParsed = await ai!.extract(e);
        if (aiParsed != null && aiParsed.amount != null) parsed = aiParsed;
      } catch (_) {
        // The AI path is best-effort; the deterministic result stands.
      }
    }

    // ATOMIC SECTION. Claiming the event, every financial write and completing the
    // source event commit together or not at all. A crash anywhere inside leaves no
    // trace, so the native inbox (which acks only after this returns) replays it safely.
    // The claim is the transaction's first statement, a write, so a second connection
    // (UI engine vs headless engine) blocks on SQLite's write lock instead of racing; it
    // then sees the committed claim and reports a duplicate.
    try {
      return await db.transaction(() => _ingestLocked(e, eventId, text, hash, parsed, aliases));
    } catch (_) {
      // The whole unit rolled back. If another connection committed this platform event
      // meanwhile (a unique-constraint race), that's a duplicate, not a failure. Anything
      // else is rethrown, and the event stays un-acked in the native inbox for a retry.
      if (e.sourceId != null) {
        final dup = await _existingClaim(e);
        if (dup != null && dup.id != eventId) {
          return IngestResult(IngestOutcome.duplicate, dup.id, transactionId: dup.transactionId, message: 'replayed event');
        }
      }
      rethrow;
    }
  }

  Future<SourceEventRow?> _existingClaim(RawEvent e) => (db.select(db.sourceEvents)
        ..where((s) => s.source.equals(e.source.name) & s.platformId.equals(e.sourceId!)))
      .getSingleOrNull();

  Future<IngestResult> _ingestLocked(
      RawEvent e, String eventId, String text, String hash, ParsedEvent parsed, Map<String, (String, String?)> aliases) async {
    final now = store.now;

    // 1. Claim. INSERT OR IGNORE against the unique index: if another connection or an
    // earlier run already claimed this platform event, nothing is written here.
    // Events with no platform id (paste, manual, some imports) can't be claimed by
    // identity. They're always processed, and an identical text seen moments earlier is
    // flagged as a possible duplicate for review, never dropped.
    await db.into(db.sourceEvents).insert(
          SourceEventsCompanion.insert(
            id: eventId,
            source: e.source.name,
            platformId: Value(e.sourceId),
            textHash: hash,
            receivedAt: e.receivedAt.toUtc(),
            status: 'processing',
            createdAt: now,
          ),
          mode: InsertMode.insertOrIgnore,
        );
    if (e.sourceId != null) {
      final owner = await _existingClaim(e);
      if (owner != null && owner.id != eventId) {
        return IngestResult(IngestOutcome.duplicate, owner.id, transactionId: owner.transactionId, message: 'replayed event');
      }
    }

    // 3. Completion: fills in the claimed row. Runs in the same transaction as the
    // financial writes that came before it.
    Future<void> recordEvent(String status, {String? txId, bool keepRaw = false, String? notes}) async {
      faultInjector?.call('after_financial_write');
      final retainDays = int.tryParse(await store.getSetting(SettingKeys.retainRawDays) ?? '') ?? 30;
      await (db.update(db.sourceEvents)..where((s) => s.id.equals(eventId))).write(SourceEventsCompanion(
        sender: Value(e.sender),
        packageName: Value(e.packageName),
        // OTPs are never stored; raw text is kept only for review items, then purged.
        rawText: Value(keepRaw && parsed.kind != TxKind.otp ? text : null),
        status: Value(status),
        kind: Value(parsed.kind.name),
        parserId: Value(parsed.parserId),
        parserVersion: Value(parsed.parserVersion),
        transactionId: Value(txId),
        bankId: Value(parsed.bankId),
        counterLast4: Value(parsed.counterAccountLast4),
        notes: Value(notes ?? (parsed.notes.isEmpty ? null : parsed.notes.join(' | '))),
        purgeAfter: Value(keepRaw ? now.add(Duration(days: retainDays)) : null),
      ));
      await store.setSetting(SettingKeys.lastCaptureAt, now.toIso8601String());
      await store.setSetting(SettingKeys.lastCaptureSource, e.source.name);
    }

    // Shortcut automations give every run a fresh id, so the platform id can't detect a
    // retry of the same SMS (the automation re-running, or the user tapping it again).
    // Defined handling: the exact same message text via Shortcuts within 24 hours is a
    // replay. It's recorded (status "duplicate", linked to the original) and not counted
    // again. Bank SMS normally carry a time, balance or reference, so two real purchases
    // rarely produce byte-identical text; if they do, the user sees "Already in Fils" and
    // can add the second one by hand. Wallet events are excluded: identical Wallet fields
    // are expected for genuine repeat purchases.
    if (e.source == SourceKind.shortcut) {
      final prior = await (db.select(db.sourceEvents)
            ..where((s) =>
                s.id.isNotValue(eventId) &
                s.source.equals(e.source.name) &
                s.textHash.equals(hash) &
                s.status.isNotIn(const ['processing', 'duplicate']) &
                s.receivedAt.isBiggerOrEqualValue(e.receivedAt.toUtc().subtract(const Duration(hours: 24))) &
                s.receivedAt.isSmallerOrEqualValue(e.receivedAt.toUtc().add(const Duration(hours: 24))))
            ..limit(1))
          .getSingleOrNull();
      if (prior != null) {
        await recordEvent('duplicate', txId: prior.transactionId, notes: 'Same message text already imported via Shortcuts; not counted again.');
        return IngestResult(IngestOutcome.duplicate, eventId, transactionId: prior.transactionId, parsed: parsed, message: 'shortcut retry');
      }
    }

    // 2. Financial classification and writes.
    // Non-financial messages are ignored.
    if (parsed.kind == TxKind.otp || parsed.kind == TxKind.promo) {
      await recordEvent('ignored');
      return IngestResult(IngestOutcome.ignored, eventId, parsed: parsed, message: parsed.kind.name);
    }

    // Match the account and update the bank-reported balance.
    final account = await _matchAccount(parsed);
    if (parsed.kind == TxKind.balanceOnly) {
      if (account != null) {
        await store.setReportedBalance(account.id,
            balance: _sameCur(parsed.balance, account), available: _sameCur(parsed.available, account), at: e.receivedAt);
      }
      await recordEvent('ignored', notes: 'balance update');
      return IngestResult(IngestOutcome.ignored, eventId, parsed: parsed, message: 'balance only');
    }

    // Anything we can't post reliably goes to review. Raw text is retained (encrypted at
    // rest), so the user can correct it.
    if (parsed.kind == TxKind.unknown || parsed.amount == null) {
      await recordEvent('review', keepRaw: true);
      return IngestResult(IngestOutcome.review, eventId, parsed: parsed, message: 'needs review');
    }

    // Exact-text possible duplicate (e.g. two identical SMS in quick succession). Never
    // silently drop: identical purchases are real (two coffees). Flag for review instead.
    final recentSame = await (db.select(db.sourceEvents)
          ..where((s) =>
              s.id.isNotValue(eventId) &
              s.textHash.equals(hash) &
              s.receivedAt.isBiggerOrEqualValue(e.receivedAt.subtract(const Duration(minutes: 3))) &
              s.receivedAt.isSmallerOrEqualValue(e.receivedAt.add(const Duration(minutes: 3)))))
        .get();
    final sameSourceSameText = recentSame.where((s) => s.source == e.source.name).toList();
    final crossSourceSameText = recentSame.where((s) => s.source != e.source.name && s.transactionId != null).toList();
    if (crossSourceSameText.isNotEmpty) {
      // The same text from SMS and from a notification is one real event.
      final txId = crossSourceSameText.first.transactionId;
      await recordEvent('merged', txId: txId, notes: 'same text already captured via ${crossSourceSameText.first.source}');
      return IngestResult(IngestOutcome.merged, eventId, transactionId: txId, parsed: parsed, message: 'cross-source duplicate');
    }

    if (account != null && (parsed.balance != null || parsed.available != null)) {
      await store.setReportedBalance(account.id,
          balance: _sameCur(parsed.balance, account), available: _sameCur(parsed.available, account), at: e.receivedAt);
    }
    final occurredAt = parsed.occurredAt ?? e.receivedAt.toUtc();
    final amount = parsed.amount!;

    // A settlement of an earlier pending authorization updates the pending row in place
    // (I6). This runs before cross-source matching, so a settlement that arrives through
    // another channel (notification after SMS) still settles the pending row.
    if (account != null && parsed.status == TxStatus.posted && parsed.kind == TxKind.purchase) {
      final pend = await (db.select(db.transactions)
            ..where((t) =>
                t.deletedAt.isNull() &
                t.status.equals(TxStatuses.pending) &
                t.accountId.equals(account.id) &
                t.occurredAt.isBiggerOrEqualValue(occurredAt.subtract(const Duration(days: 10))) &
                t.occurredAt.isSmallerOrEqualValue(occurredAt.add(const Duration(minutes: 5)))))
          .get();
      for (final p in pend) {
        final sameMerchant = p.merchant != null && p.merchant == parsed.merchant;
        final within = (p.amountMinor - amount.minor).abs() <= (p.amountMinor * 0.2).round();
        if (sameMerchant && within && p.currency == amount.currency) {
          await store.updateTransaction(
            p.id,
            TransactionsCompanion(
              status: const Value(TxStatuses.posted),
              amountMinor: Value(amount.minor),
              occurredAt: Value(occurredAt),
            ),
            action: 'settle',
          );
          await recordEvent('merged', txId: p.id, notes: 'settled pending authorization');
          return IngestResult(IngestOutcome.settledPending, eventId, transactionId: p.id, parsed: parsed, message: 'settled');
        }
      }
    }

    // Semantic cross-source dedupe: Wallet + bank SMS, or SMS + notification with
    // different wording. Requirements:
    //  - a different source kind, the same amount and currency, within 10 minutes;
    //  - a compatible merchant and a compatible kind *and status*: a successful purchase
    //    never matches a declined or voided row, and a decline matches only a decline;
    //  - no conflicting known accounts (see [_accountsCompatible]);
    //  - the candidate isn't already paired with an event from this same source (two
    //    genuine identical purchases stay two).
    // Exactly one match merges. More than one is ambiguous and goes to review.
    final windowStart = occurredAt.subtract(const Duration(minutes: 10));
    final windowEnd = occurredAt.add(const Duration(minutes: 10));
    final isDecline = parsed.kind == TxKind.declined;
    final candidates = await (db.select(db.transactions)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.amountMinor.equals(amount.minor) &
              t.currency.equals(amount.currency) &
              t.occurredAt.isBiggerOrEqualValue(windowStart) &
              t.occurredAt.isSmallerOrEqualValue(windowEnd) &
              t.source.isNotValue(_txSource(e.source)) &
              (isDecline ? t.status.equals(TxStatuses.declined) : t.status.isIn([TxStatuses.posted, TxStatuses.pending]))))
        .get();
    final allAccounts = {for (final a in await store.accounts()) a.id: a};
    final matches = <TxRow>[];
    for (final c in candidates) {
      final merchantOk = c.merchant == null || parsed.merchant == null || c.merchant == parsed.merchant;
      if (!merchantOk || !_kindCompatible(c, parsed)) continue;
      if (!_accountsCompatible(allAccounts[c.accountId], account, parsed)) continue;
      final paired = await (db.select(db.sourceEvents)
            ..where((s) => s.transactionId.equals(c.id) & s.source.equals(e.source.name) & s.id.isNotValue(eventId)))
          .get();
      if (paired.isNotEmpty) continue;
      matches.add(c);
    }
    var ambiguous = false;
    if (matches.length == 1) {
      final c = matches.single;
      final cAcct = allAccounts[c.accountId];
      // An Unassigned transaction (e.g. Wallet with no card) that a bank message now
      // reliably identifies moves to that account. Its ledger effect moves with it,
      // atomically (same transaction).
      String? moveTo;
      if (_isUnassigned(cAcct) && _identifies(account, parsed)) {
        moveTo = (account ?? await _autoCreateAccount(parsed)).id;
        if (parsed.balance != null || parsed.available != null) {
          final target = (await store.account(moveTo))!;
          await store.setReportedBalance(moveTo,
              balance: _sameCur(parsed.balance, target), available: _sameCur(parsed.available, target), at: e.receivedAt);
        }
      }
      // Prefer richer data (bank SMS over Wallet): fill gaps only, never overwrite.
      await store.updateTransaction(
        c.id,
        TransactionsCompanion(
          accountId: moveTo != null ? Value(moveTo) : const Value.absent(),
          merchant: c.merchant == null && parsed.merchant != null ? Value(parsed.merchant) : const Value.absent(),
          merchantRaw: c.merchantRaw == null && parsed.merchantRaw != null ? Value(parsed.merchantRaw) : const Value.absent(),
        ),
        action: 'merge',
      );
      await recordEvent('merged', txId: c.id, notes: 'matched ${c.source} transaction${moveTo != null ? '; moved from Unassigned' : ''}');
      return IngestResult(IngestOutcome.merged, eventId, transactionId: c.id, parsed: parsed, message: 'cross-source match');
    } else if (matches.length > 1) {
      ambiguous = true;
    }

    final acct = account ?? await _autoCreateAccount(parsed);
    if (account == null && (parsed.balance != null || parsed.available != null)) {
      await store.setReportedBalance(acct.id,
          balance: _sameCur(parsed.balance, acct), available: _sameCur(parsed.available, acct), at: e.receivedAt);
    }

    final possibleDup = sameSourceSameText.isNotEmpty && e.sourceId == null;
    final needsReview = parsed.needsReview || possibleDup || ambiguous;
    final mm = parsed.merchant != null ? matchMerchant(parsed.merchantRaw ?? parsed.merchant, userAliases: aliases) : null;
    final category = _category(parsed, mm);
    final common = (
      currency: amount.currency,
      occurredAt: occurredAt,
      receivedAt: e.receivedAt,
      source: _txSource(e.source),
      parserId: parsed.parserId,
      parserVersion: parsed.parserVersion,
      confidence: parsed.confidence,
    );

    TxRow tx;
    switch (parsed.kind) {
      case TxKind.declined:
        tx = await _add(acct.id, TxKinds.expense, amount.minor, common, parsed, eventId,
            status: TxStatuses.declined, category: category, review: false);
      case TxKind.atmWithdrawal:
        final cash = await _cashWallet(amount.currency);
        tx = await _add(acct.id, TxKinds.transfer, amount.minor, common, parsed, eventId,
            counter: cash.id, category: null, review: needsReview);
        if (parsed.fee != null && parsed.fee!.minor > 0 && parsed.fee!.currency == amount.currency) {
          await _add(acct.id, TxKinds.expense, parsed.fee!.minor, common, parsed, eventId, category: Cat.fees, review: false, note: 'ATM fee');
        }
      case TxKind.cardPayment:
        // Repaying a card is a transfer into the card account (I4), from the default
        // payer account if one is configured. Otherwise it waits for review.
        final payerId = await store.getSetting(SettingKeys.defaultPayerAccount);
        final payer = payerId == null ? null : await store.account(payerId);
        if (payer != null && payer.id != acct.id) {
          tx = await _add(payer.id, TxKinds.transfer, amount.minor, common, parsed, eventId,
              counter: acct.id, category: null, review: needsReview);
        } else {
          tx = await _add(acct.id, TxKinds.adjustUp, amount.minor, common, parsed, eventId,
              category: null, review: true, note: 'Card payment: choose the account it was paid from');
        }
      case TxKind.transferOut:
      case TxKind.transferIn:
        tx = await _transferLeg(acct, amount.minor, common, parsed, eventId, needsReview);
      case TxKind.refund:
      case TxKind.reversal:
        tx = await _refundOrReversal(acct, amount.minor, common, parsed, eventId, category, needsReview);
      case TxKind.income:
      case TxKind.salary:
        tx = await _add(acct.id, TxKinds.income, amount.minor, common, parsed, eventId,
            category: parsed.kind == TxKind.salary ? Cat.salary : Cat.otherIncome, review: needsReview);
      case TxKind.fee:
        tx = await _add(acct.id, TxKinds.expense, amount.minor, common, parsed, eventId, category: Cat.fees, review: needsReview);
      default:
        tx = await _add(acct.id, TxKinds.expense, amount.minor, common, parsed, eventId,
            status: parsed.status == TxStatus.pending ? TxStatuses.pending : TxStatuses.posted,
            category: category,
            review: needsReview,
            note: ambiguous ? 'Matches more than one captured transaction: confirm it is not a duplicate.' : null);
    }

    final txReview = tx.needsReview;
    await recordEvent(txReview ? 'review' : 'posted', txId: tx.id, keepRaw: txReview,
        notes: possibleDup
            ? 'Identical message received moments ago: confirm it is a separate purchase.'
            : ambiguous
                ? 'Ambiguous cross-source match (${matches.length} candidates); sent to review.'
                : null);
    return IngestResult(
      possibleDup ? IngestOutcome.possibleDuplicate : (txReview ? IngestOutcome.review : IngestOutcome.posted),
      eventId,
      transactionId: tx.id,
      parsed: parsed,
    );
  }

  int? _sameCur(dynamic m, AccountRow a) => (m != null && m.currency == a.currency) ? m.minor as int : null;

  static bool _isUnassigned(AccountRow? a) => a == null || a.institutionId == '_unassigned';

  /// Whether the incoming event carries account identity (a known account, a card or
  /// account number, or a bank).
  static bool _identifies(AccountRow? matched, ParsedEvent p) =>
      matched != null || p.cardLast4 != null || p.accountLast4 != null || p.bankId != null;

  /// No automatic merge across conflicting known accounts:
  ///  - same account → compatible;
  ///  - candidate on Unassigned → compatible (the incoming event may identify it);
  ///  - incoming event carries no account identity at all (e.g. Wallet without a card)
  ///    → compatible with the candidate's account;
  ///  - incoming names only the bank (no digits) and the candidate is on that bank →
  ///    compatible;
  ///  - anything else (different known account, or digits that don't match) → not.
  bool _accountsCompatible(AccountRow? candidate, AccountRow? incoming, ParsedEvent p) {
    if (candidate == null) return false;
    if (incoming != null && candidate.id == incoming.id) return true;
    if (_isUnassigned(candidate)) return true;
    if (!_identifies(incoming, p)) return true;
    final digits = p.cardLast4 ?? p.accountLast4;
    if (incoming == null && digits == null && p.bankId != null) return candidate.institutionId == p.bankId;
    return false;
  }

  bool _kindCompatible(TxRow c, ParsedEvent p) {
    if (p.kind == TxKind.declined) return c.kind == TxKinds.expense && c.status == TxStatuses.declined;
    if (c.status == TxStatuses.declined || c.status == TxStatuses.voided) return false;
    final pk = switch (p.kind) {
      TxKind.purchase || TxKind.installment || TxKind.fee => TxKinds.expense,
      TxKind.income || TxKind.salary => TxKinds.income,
      TxKind.refund || TxKind.reversal => TxKinds.refund,
      _ => TxKinds.transfer,
    };
    return c.kind == pk;
  }

  String _txSource(SourceKind s) => switch (s) {
        SourceKind.sms => 'sms',
        SourceKind.notification => 'notification',
        SourceKind.shortcut => 'shortcut',
        SourceKind.wallet => 'wallet',
        SourceKind.paste => 'paste',
        SourceKind.share => 'share',
        SourceKind.csv => 'csv',
        SourceKind.pdf => 'pdf',
        SourceKind.image => 'image',
        SourceKind.voice => 'voice',
        SourceKind.manual => 'manual',
      };

  String _category(ParsedEvent p, MerchantMatch? mm) {
    if (p.kind == TxKind.installment) return Cat.installments;
    if (mm != null && mm.category != Cat.other) return mm.category;
    if (p.kind == TxKind.transferOut) return Cat.transfers;
    return Cat.other;
  }

  Future<TxRow> _add(
    String accountId,
    String kind,
    int amountMinor,
    ({String currency, DateTime occurredAt, DateTime receivedAt, String source, String parserId, String parserVersion, double confidence}) c,
    ParsedEvent p,
    String eventId, {
    String status = TxStatuses.posted,
    String? counter,
    String? category,
    bool review = false,
    String? note,
    String? refundOf,
    String? transferGroup,
  }) =>
      store.addTransaction(
        accountId: accountId,
        kind: kind,
        amountMinor: amountMinor,
        currency: c.currency,
        occurredAt: c.occurredAt,
        receivedAt: c.receivedAt,
        source: c.source,
        status: status,
        counterAccountId: counter,
        originalAmountMinor: p.originalAmount?.minor,
        originalCurrency: p.originalAmount?.currency,
        fxSource: p.originalAmount != null ? 'bank_billed' : null,
        merchant: p.merchant,
        merchantRaw: p.merchantRaw,
        processor: p.processor,
        categoryId: category,
        note: note,
        sourceEventId: eventId,
        refundOfId: refundOf,
        transferGroupId: transferGroup,
        parserId: c.parserId,
        parserVersion: c.parserVersion,
        confidence: c.confidence,
        needsReview: review,
      );

  /// A transfer leg. Two legs on different owned accounts are merged into one internal
  /// transfer (I2) only on reliable evidence: one message names the other account's
  /// digits ("to account XXXX9012"), and those digits belong to the account the opposite
  /// leg is on. Amount, currency and timing alone are never enough: an unrelated KWD 20
  /// received and a KWD 20 sent stay separate. Without evidence, a same-amount opposite
  /// leg within 30 minutes only flags the new leg for review, so the user can confirm it
  /// with "Link as transfer". Otherwise this records an external transfer: outgoing
  /// counts as money sent to others, incoming as other income.
  Future<TxRow> _transferLeg(AccountRow acct, int amount, dynamic c, ParsedEvent p, String eventId, bool review) async {
    final out = p.kind == TxKind.transferOut;
    final t0 = (c.occurredAt as DateTime).subtract(const Duration(minutes: 30));
    final t1 = (c.occurredAt as DateTime).add(const Duration(minutes: 30));
    final opposite = await (db.select(db.transactions)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.accountId.isNotValue(acct.id) &
              t.transferGroupId.isNull() &
              t.amountMinor.equals(amount) &
              t.currency.equals(c.currency as String) &
              t.kind.equals(out ? TxKinds.income : TxKinds.expense) &
              t.categoryId.equals(out ? Cat.otherIncome : Cat.transfers) &
              t.occurredAt.isBiggerOrEqualValue(t0) &
              t.occurredAt.isSmallerOrEqualValue(t1)))
        .get();
    final accounts = {for (final a in await store.accounts()) a.id: a};
    final evidenced = <TxRow>[];
    for (final o in opposite) {
      final oAcct = accounts[o.accountId];
      // This message names the opposite leg's account.
      final forward = p.counterAccountLast4 != null && oAcct?.maskLast4 == p.counterAccountLast4;
      // The opposite leg's message named this account.
      var backward = false;
      if (o.sourceEventId != null && acct.maskLast4 != null) {
        final se = await (db.select(db.sourceEvents)..where((s) => s.id.equals(o.sourceEventId!))).getSingleOrNull();
        backward = se?.counterLast4 != null && se!.counterLast4 == acct.maskLast4;
      }
      if (forward || backward) evidenced.add(o);
    }
    if (evidenced.length == 1) {
      final other = evidenced.single;
      final leg = await _add(acct.id, out ? TxKinds.expense : TxKinds.income, amount, c, p, eventId,
          category: out ? Cat.transfers : Cat.otherIncome);
      return out ? store.linkAsTransfer(leg.id, other.id) : store.linkAsTransfer(other.id, leg.id);
    }
    // The counter account is named and isn't one of ours → definitely external.
    final namedExternal = p.counterAccountLast4 != null && !accounts.values.any((a) => a.maskLast4 == p.counterAccountLast4);
    final suggest = !namedExternal && opposite.isNotEmpty;
    return _add(acct.id, out ? TxKinds.expense : TxKinds.income, amount, c, p, eventId,
        category: out ? Cat.transfers : Cat.otherIncome,
        review: review || suggest,
        note: suggest
            ? 'Possible transfer between your accounts (same amount ${out ? 'received' : 'sent'} nearby). Link as transfer if so.'
            : null);
  }

  Future<TxRow> _refundOrReversal(AccountRow acct, int amount, dynamic c, ParsedEvent p, String eventId, String category, bool review) async {
    final since = (c.occurredAt as DateTime).subtract(Duration(days: p.kind == TxKind.reversal ? 30 : 120));
    final originals = await (db.select(db.transactions)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.accountId.equals(acct.id) &
              t.kind.equals(TxKinds.expense) &
              t.status.isIn([TxStatuses.posted, TxStatuses.pending]) &
              t.currency.equals(c.currency as String) &
              t.amountMinor.isBiggerOrEqualValue(amount) &
              t.occurredAt.isBiggerOrEqualValue(since))
          ..orderBy([(t) => OrderingTerm(expression: t.occurredAt, mode: OrderingMode.desc)]))
        .get();
    TxRow? original;
    for (final o in originals) {
      if (p.merchant != null && o.merchant == p.merchant) {
        original = o;
        break;
      }
    }
    // A reversal of a pending authorization voids it: the money never left.
    if (p.kind == TxKind.reversal && original != null && original.status == TxStatuses.pending && original.amountMinor == amount) {
      await store.updateTransaction(original.id, const TransactionsCompanion(status: Value(TxStatuses.voided)), action: 'void');
      return original;
    }
    return _add(acct.id, TxKinds.refund, amount, c, p, eventId,
        category: original?.categoryId ?? category, refundOf: original?.id, review: review || original == null && p.merchant == null);
  }

  Future<AccountRow?> _matchAccount(ParsedEvent p) async {
    final all = (await store.accounts()).where((a) => !a.archived).toList();
    final last4 = p.cardLast4 ?? p.accountLast4;
    if (last4 != null) {
      final hits = all.where((a) => a.maskLast4 == last4 && (p.bankId == null || a.institutionId == null || a.institutionId == p.bankId)).toList();
      if (hits.length == 1) return hits.first;
      if (hits.length > 1) {
        final byBank = hits.where((a) => a.institutionId == p.bankId).toList();
        if (byBank.length == 1) return byBank.first;
      }
      return null; // unknown card → auto-create a distinct account rather than misroute
    }
    if (p.bankId != null) {
      final bankAccts = all.where((a) => a.institutionId == p.bankId && a.kind != 'cash').toList();
      if (bankAccts.length == 1) return bankAccts.first;
      final def = bankAccts.where((a) => a.isDefault).toList();
      if (def.length == 1) return def.first;
    }
    return null;
  }

  Future<AccountRow> _autoCreateAccount(ParsedEvent p) async {
    final last4 = p.cardLast4 ?? p.accountLast4;
    final bank = bankById(p.bankId);
    final all = await store.accounts();
    if (last4 == null && bank == null) {
      // No identifying information: use (or create) a single "Unassigned" account in the
      // transaction currency, flagged for the user to route.
      final cur = p.amount?.currency ?? 'KWD';
      final unassigned = all.where((a) => a.institutionId == '_unassigned' && a.currency == cur).toList();
      if (unassigned.isNotEmpty) return unassigned.first;
      return store.createAccount(name: 'Unassigned', kind: 'bank', currency: cur, institutionId: '_unassigned');
    }
    final isCard = p.cardLast4 != null;
    final name = '${bank?.shortCode ?? 'Card'} ${isCard ? 'Card' : 'Account'}${last4 != null ? ' •$last4' : ''}';
    return store.createAccount(
      name: name,
      kind: isCard ? 'card' : 'bank',
      currency: p.amount?.currency == null || p.originalAmount != null ? (p.amount?.currency ?? 'KWD') : p.amount!.currency,
      institutionId: bank?.id,
      maskLast4: last4,
      // A debit card is not a liability; we can't know which card type it is, so cards
      // start as non-liabilities and the user can switch.
      isLiability: false,
      color: bank?.brandColor,
    );
  }

  Future<AccountRow> _cashWallet(String currency) async {
    final all = await store.accounts();
    final hit = all.where((a) => a.kind == 'cash' && a.currency == currency && !a.archived).toList();
    if (hit.isNotEmpty) return hit.first;
    return store.createAccount(name: 'Cash', kind: 'cash', currency: currency);
  }
}
