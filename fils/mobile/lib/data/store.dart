import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../core/domain/categories.dart';
import '../core/ledger/ledger.dart';
import 'db/database.dart';

const _uuid = Uuid();
String newId() => _uuid.v4();

/// Entity names used by the sync outbox and the audit log.
class Entities {
  static const account = 'account';
  static const transaction = 'transaction';
  static const category = 'category';
  static const budget = 'budget';
  static const goal = 'goal';
  static const recurring = 'recurring';
  static const merchantAlias = 'merchant_alias';
  static const asset = 'asset';
  static const setting = 'setting';
}

/// Settings keys.
class SettingKeys {
  static const locale = 'locale'; // ar|en
  static const themeMode = 'theme_mode'; // system|light|dark
  static const baseCurrency = 'base_currency';
  static const cycleStartDay = 'cycle_start_day';
  static const onboarded = 'onboarded';
  static const biometricLock = 'biometric_lock';
  static const retainRawDays = 'retain_raw_days';
  static const lastCaptureAt = 'last_capture_at';
  static const lastCaptureSource = 'last_capture_source';
  static const demoMode = 'demo_mode';
  static const monitoredPackages = 'monitored_packages';
  static const defaultPayerAccount = 'default_payer_account';
  static const aiCloudEnabled = 'ai_cloud_enabled';
  static const voiceProvider = 'voice_provider'; // device|azure
  static const shortcutTestReceivedAt = 'shortcut_test_received_at';
  static const syncedKeys = {baseCurrency, cycleStartDay};
}

/// Local-first data access. Every user-visible mutation:
///  1. runs in a single database transaction,
///  2. writes an audit record (before/after JSON),
///  3. enqueues a sync outbox entry (uploaded only when sync consent exists).
class FinanceStore {
  final AppDatabase db;
  DateTime Function() clock;
  FinanceStore(this.db, {DateTime Function()? clock}) : clock = clock ?? (() => DateTime.now().toUtc());

  DateTime get now => clock();

  // ---------------------------------------------------------------- bootstrap
  Future<void> ensureSeeded() async {
    final existing = await (db.select(db.categories)..where((c) => c.isSystem.equals(true))).get();
    final have = existing.map((e) => e.id).toSet();
    await db.batch((b) {
      for (final c in systemCategories) {
        if (have.contains(c.id)) continue;
        b.insert(
          db.categories,
          CategoriesCompanion.insert(
            id: c.id,
            nameEn: c.en,
            nameAr: c.ar,
            icon: c.icon,
            color: c.color,
            kind: c.income ? 'income' : 'expense',
            isSystem: const Value(true),
            updatedAt: now,
          ),
        );
      }
    });
  }

  // ---------------------------------------------------------------- settings
  Future<String?> getSetting(String key) async =>
      (await (db.select(db.settings)..where((s) => s.key.equals(key))).getSingleOrNull())?.value;

  Stream<String?> watchSetting(String key) =>
      (db.select(db.settings)..where((s) => s.key.equals(key))).watchSingleOrNull().map((r) => r?.value);

  Future<void> setSetting(String key, String value) async {
    await db.into(db.settings).insertOnConflictUpdate(SettingsCompanion.insert(key: key, value: value));
    if (SettingKeys.syncedKeys.contains(key)) await _enqueue(Entities.setting, key);
  }

  Future<int> cycleStartDay() async => int.tryParse(await getSetting(SettingKeys.cycleStartDay) ?? '') ?? 1;
  Future<String> baseCurrency() async => await getSetting(SettingKeys.baseCurrency) ?? 'KWD';

  // ---------------------------------------------------------------- internals
  Future<void> _enqueue(String entity, String id) async {
    // Coalesce: one pending outbox row per entity is enough (the latest state is sent).
    final existing = await (db.select(db.outbox)
          ..where((o) => o.entity.equals(entity) & o.entityId.equals(id) & o.state.equals('pending')))
        .getSingleOrNull();
    if (existing != null) return;
    await db.into(db.outbox).insert(OutboxCompanion.insert(entity: entity, entityId: id, createdAt: now));
  }

  Future<void> _audit(String entity, String id, String action, Object? before, Object? after) async {
    String? enc(Object? o) => o == null ? null : jsonEncode(o is DataClass ? o.toJson() : o);
    await db.into(db.auditEvents).insert(AuditEventsCompanion.insert(
          at: now,
          entity: entity,
          entityId: id,
          action: action,
          beforeJson: Value(enc(before)),
          afterJson: Value(enc(after)),
        ));
  }

  // ---------------------------------------------------------------- accounts
  Stream<List<AccountRow>> watchAccounts({bool includeArchived = false}) {
    final q = db.select(db.accounts)..where((a) => a.deletedAt.isNull());
    if (!includeArchived) q.where((a) => a.archived.equals(false));
    q.orderBy([(a) => OrderingTerm(expression: a.sortOrder), (a) => OrderingTerm(expression: a.name)]);
    return q.watch();
  }

  Future<List<AccountRow>> accounts({bool includeArchived = true}) {
    final q = db.select(db.accounts)..where((a) => a.deletedAt.isNull());
    if (!includeArchived) q.where((a) => a.archived.equals(false));
    return q.get();
  }

  Future<AccountRow?> account(String id) =>
      (db.select(db.accounts)..where((a) => a.id.equals(id))).getSingleOrNull();

  Future<AccountRow> createAccount({
    String? id,
    required String name,
    required String kind,
    required String currency,
    String? institutionId,
    String? maskLast4,
    int openingBalanceMinor = 0,
    DateTime? openingBalanceDate,
    bool? isLiability,
    int? creditLimitMinor,
    int? color,
    bool isDefault = false,
  }) async {
    final rowId = id ?? newId();
    return db.transaction(() async {
      final count = (await accounts()).length;
      await db.into(db.accounts).insert(AccountsCompanion.insert(
            id: rowId,
            name: name,
            kind: kind,
            currency: currency.toUpperCase(),
            institutionId: Value(institutionId),
            maskLast4: Value(maskLast4),
            openingBalanceMinor: Value(openingBalanceMinor),
            openingBalanceDate: openingBalanceDate ?? now,
            isLiability: Value(isLiability ?? (kind == 'card' || kind == 'loan')),
            creditLimitMinor: Value(creditLimitMinor),
            color: Value(color),
            sortOrder: Value(count),
            isDefault: Value(isDefault || count == 0),
            updatedAt: now,
          ));
      final row = (await account(rowId))!;
      await _audit(Entities.account, rowId, 'create', null, row);
      await _enqueue(Entities.account, rowId);
      return row;
    });
  }

  Future<void> updateAccount(String id, AccountsCompanion changes) async {
    await db.transaction(() async {
      final before = await account(id);
      if (before == null) throw StateError('account $id not found');
      await (db.update(db.accounts)..where((a) => a.id.equals(id))).write(changes.copyWith(updatedAt: Value(now)));
      await _audit(Entities.account, id, 'update', before, await account(id));
      await _enqueue(Entities.account, id);
    });
  }

  Future<void> archiveAccount(String id, bool archived) =>
      updateAccount(id, AccountsCompanion(archived: Value(archived)));

  /// Record a bank-reported balance (from a message or user entry). This never changes
  /// the calculated balance; the two are displayed separately.
  Future<void> setReportedBalance(String id, {int? balance, int? available, required DateTime at}) async {
    final a = await account(id);
    if (a == null) return;
    if (a.reportedBalanceAt != null && a.reportedBalanceAt!.isAfter(at)) return; // never go backwards
    await (db.update(db.accounts)..where((x) => x.id.equals(id))).write(AccountsCompanion(
      reportedBalanceMinor: balance != null ? Value(balance) : const Value.absent(),
      reportedAvailableMinor: available != null ? Value(available) : const Value.absent(),
      reportedBalanceAt: Value(at),
      updatedAt: Value(now),
    ));
    await _enqueue(Entities.account, id);
  }

  /// Reconcile: create an adjustment so the calculated balance equals [actualMinor].
  /// Adjustments are excluded from income and spending (I9).
  Future<TxRow?> reconcile(String accountId, int actualMinor, {String? note}) async {
    final a = await account(accountId);
    if (a == null) return null;
    final bal = calculatedBalance(a, await transactionsForAccount(accountId));
    final diff = actualMinor - bal;
    if (diff == 0) return null;
    return addTransaction(
      accountId: accountId,
      kind: diff > 0 ? TxKinds.adjustUp : TxKinds.adjustDown,
      amountMinor: diff.abs(),
      currency: a.currency,
      occurredAt: now,
      source: 'manual',
      note: note ?? 'Reconciliation adjustment',
    );
  }

  // ---------------------------------------------------------------- transactions
  Future<TxRow?> transaction(String id) =>
      (db.select(db.transactions)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<TxRow>> allTransactions({bool includeDeleted = false}) {
    final q = db.select(db.transactions);
    if (!includeDeleted) q.where((t) => t.deletedAt.isNull());
    return q.get();
  }

  Future<List<TxRow>> transactionsForAccount(String accountId) => (db.select(db.transactions)
        ..where((t) => t.deletedAt.isNull() & (t.accountId.equals(accountId) | t.counterAccountId.equals(accountId))))
      .get();

  Future<List<TxRow>> transactionsBetween(DateTime start, DateTime end) => (db.select(db.transactions)
        ..where((t) =>
            t.deletedAt.isNull() &
            t.occurredAt.isBiggerOrEqualValue(start) &
            t.occurredAt.isSmallerThanValue(end)))
      .get();

  Stream<List<TxRow>> watchTransactions({
    int limit = 50,
    int offset = 0,
    String? search,
    String? accountId,
    String? categoryId,
    bool? needsReview,
    DateTime? from,
    DateTime? to,
    bool includeDeclined = true,
  }) {
    final q = db.select(db.transactions)..where((t) => t.deletedAt.isNull());
    if (accountId != null) {
      q.where((t) => t.accountId.equals(accountId) | t.counterAccountId.equals(accountId));
    }
    if (categoryId != null) q.where((t) => t.categoryId.equals(categoryId));
    if (needsReview != null) q.where((t) => t.needsReview.equals(needsReview));
    if (from != null) q.where((t) => t.occurredAt.isBiggerOrEqualValue(from));
    if (to != null) q.where((t) => t.occurredAt.isSmallerThanValue(to));
    if (!includeDeclined) q.where((t) => t.status.isNotIn([TxStatuses.declined, TxStatuses.voided]));
    if (search != null && search.trim().isNotEmpty) {
      final s = '%${search.trim()}%';
      q.where((t) => t.merchant.like(s) | t.merchantRaw.like(s) | t.note.like(s));
    }
    q
      ..orderBy([(t) => OrderingTerm(expression: t.occurredAt, mode: OrderingMode.desc)])
      ..limit(limit, offset: offset);
    return q.watch();
  }

  /// Items waiting for the user: transactions flagged for review, plus captures with
  /// no transaction yet (unreadable messages and held possible duplicates).
  Stream<int> watchReviewCount() => db
      .customSelect(
        "SELECT (SELECT COUNT(*) FROM transactions WHERE deleted_at IS NULL AND needs_review = 1) + "
        "(SELECT COUNT(*) FROM source_events WHERE status IN ('review', 'held') AND transaction_id IS NULL) AS n",
        readsFrom: {db.transactions, db.sourceEvents},
      )
      .watchSingle()
      .map((r) => r.read<int>('n'));

  /// Watches all effective transactions. Analytics recompute from this stream; the local
  /// database stays small enough (benchmarked in test/perf) for in-memory aggregation.
  Stream<List<TxRow>> watchAllEffective() =>
      (db.select(db.transactions)..where((t) => t.deletedAt.isNull())).watch();

  Future<TxRow> addTransaction({
    String? id,
    required String accountId,
    required String kind,
    required int amountMinor,
    required String currency,
    required DateTime occurredAt,
    required String source,
    String status = TxStatuses.posted,
    String? counterAccountId,
    int? counterAmountMinor,
    int? originalAmountMinor,
    String? originalCurrency,
    String? fxRate,
    String? fxSource,
    String? merchant,
    String? merchantRaw,
    String? processor,
    String? categoryId,
    String? note,
    DateTime? receivedAt,
    String? sourceEventId,
    String? refundOfId,
    String? transferGroupId,
    String? recurringId,
    String? parserId,
    String? parserVersion,
    double? confidence,
    bool needsReview = false,
    List<({String categoryId, int amountMinor, String? note})> splits = const [],
  }) async {
    if (!TxKinds.all.contains(kind)) throw ArgumentError('bad kind $kind');
    if (amountMinor < 0) throw ArgumentError('amountMinor must be >= 0; direction comes from kind');
    if (kind == TxKinds.transfer && counterAccountId == accountId) {
      throw ArgumentError('transfer to the same account');
    }
    if (splits.isNotEmpty && splits.fold<int>(0, (s, e) => s + e.amountMinor) != amountMinor) {
      throw ArgumentError('splits must add up to the transaction amount');
    }
    final rowId = id ?? newId();
    return db.transaction(() async {
      await db.into(db.transactions).insert(TransactionsCompanion.insert(
            id: rowId,
            accountId: accountId,
            kind: kind,
            status: status,
            amountMinor: amountMinor,
            currency: currency.toUpperCase(),
            counterAccountId: Value(counterAccountId),
            counterAmountMinor: Value(counterAmountMinor),
            originalAmountMinor: Value(originalAmountMinor),
            originalCurrency: Value(originalCurrency),
            fxRate: Value(fxRate),
            fxSource: Value(fxSource),
            merchant: Value(merchant),
            merchantRaw: Value(merchantRaw),
            processor: Value(processor),
            categoryId: Value(categoryId),
            note: Value(note),
            occurredAt: occurredAt.toUtc(),
            receivedAt: Value(receivedAt?.toUtc()),
            source: source,
            sourceEventId: Value(sourceEventId),
            refundOfId: Value(refundOfId),
            transferGroupId: Value(transferGroupId),
            recurringId: Value(recurringId),
            parserId: Value(parserId),
            parserVersion: Value(parserVersion),
            confidence: Value(confidence),
            needsReview: Value(needsReview),
            updatedAt: now,
          ));
      for (final s in splits) {
        await db.into(db.transactionSplits).insert(TransactionSplitsCompanion.insert(
            id: newId(), transactionId: rowId, categoryId: s.categoryId, amountMinor: s.amountMinor, note: Value(s.note)));
      }
      final row = (await transaction(rowId))!;
      await _audit(Entities.transaction, rowId, 'create', null, row);
      await _enqueue(Entities.transaction, rowId);
      await setSetting(SettingKeys.lastCaptureAt, now.toIso8601String());
      return row;
    });
  }

  Future<void> updateTransaction(String id, TransactionsCompanion changes, {String action = 'update'}) async {
    await db.transaction(() async {
      final before = await transaction(id);
      if (before == null) throw StateError('transaction $id not found');
      if (changes.amountMinor.present && changes.amountMinor.value < 0) {
        throw ArgumentError('amountMinor must be >= 0');
      }
      await (db.update(db.transactions)..where((t) => t.id.equals(id))).write(changes.copyWith(updatedAt: Value(now)));
      await _audit(Entities.transaction, id, action, before, await transaction(id));
      await _enqueue(Entities.transaction, id);
    });
  }

  /// Recategorize, and optionally remember the merchant → category mapping.
  Future<void> setCategory(String id, String categoryId, {bool remember = false}) async {
    final t = await transaction(id);
    if (t == null) return;
    await updateTransaction(id, TransactionsCompanion(categoryId: Value(categoryId), needsReview: const Value(false)));
    if (remember && (t.merchant ?? t.merchantRaw) != null) {
      await upsertMerchantAlias(pattern: (t.merchantRaw ?? t.merchant)!, merchant: t.merchant ?? t.merchantRaw!, categoryId: categoryId);
    }
  }

  Future<void> replaceSplits(String txId, List<({String categoryId, int amountMinor, String? note})> splits) async {
    final t = await transaction(txId);
    if (t == null) return;
    if (splits.isNotEmpty && splits.fold<int>(0, (s, e) => s + e.amountMinor) != t.amountMinor) {
      throw ArgumentError('splits must add up to the transaction amount');
    }
    await db.transaction(() async {
      final before = await splitsFor(txId);
      await (db.delete(db.transactionSplits)..where((s) => s.transactionId.equals(txId))).go();
      for (final s in splits) {
        await db.into(db.transactionSplits).insert(TransactionSplitsCompanion.insert(
            id: newId(), transactionId: txId, categoryId: s.categoryId, amountMinor: s.amountMinor, note: Value(s.note)));
      }
      await _audit(Entities.transaction, txId, 'split', before.map((e) => e.toJson()).toList(), splits.map((e) => {'category_id': e.categoryId, 'amount_minor': e.amountMinor}).toList());
      await (db.update(db.transactions)..where((t) => t.id.equals(txId))).write(TransactionsCompanion(updatedAt: Value(now)));
      await _enqueue(Entities.transaction, txId);
    });
  }

  Future<List<SplitRow>> splitsFor(String txId) =>
      (db.select(db.transactionSplits)..where((s) => s.transactionId.equals(txId))).get();

  Future<Map<String, List<SplitRow>>> allSplits() async {
    final rows = await db.select(db.transactionSplits).get();
    final m = <String, List<SplitRow>>{};
    for (final r in rows) {
      m.putIfAbsent(r.transactionId, () => []).add(r);
    }
    return m;
  }

  /// Soft delete with undo. Tombstones sync as deletions and are never resurrected by sync.
  Future<void> deleteTransaction(String id) =>
      updateTransaction(id, TransactionsCompanion(deletedAt: Value(now)), action: 'delete');

  Future<void> restoreTransaction(String id) =>
      updateTransaction(id, const TransactionsCompanion(deletedAt: Value(null)), action: 'restore');

  /// Turn two separately captured legs (an outflow from A and an inflow to B) into one
  /// internal transfer, so the movement is neither spending nor income (I2).
  Future<TxRow> linkAsTransfer(String outId, String inId) async {
    final o = await transaction(outId);
    final i = await transaction(inId);
    if (o == null || i == null) throw StateError('missing legs');
    if (o.accountId == i.accountId) throw ArgumentError('both legs are on the same account');
    return db.transaction(() async {
      final group = newId();
      await updateTransaction(
        outId,
        TransactionsCompanion(
          kind: const Value(TxKinds.transfer),
          counterAccountId: Value(i.accountId),
          counterAmountMinor: Value(i.amountMinor),
          transferGroupId: Value(group),
          categoryId: const Value(null),
          needsReview: const Value(false),
        ),
        action: 'merge',
      );
      await updateTransaction(inId, TransactionsCompanion(deletedAt: Value(now), transferGroupId: Value(group)), action: 'merge');
      return (await transaction(outId))!;
    });
  }

  /// Record a (partial) refund linked to the original expense.
  Future<TxRow> recordRefund(String originalId, int amountMinor, {DateTime? at, String source = 'manual'}) async {
    final o = await transaction(originalId);
    if (o == null) throw StateError('original missing');
    final refundedSoFar = (await (db.select(db.transactions)
              ..where((t) => t.refundOfId.equals(originalId) & t.deletedAt.isNull()))
            .get())
        .fold<int>(0, (s, t) => s + t.amountMinor);
    if (refundedSoFar + amountMinor > o.amountMinor) {
      throw ArgumentError('refunds would exceed the original amount');
    }
    return addTransaction(
      accountId: o.accountId,
      kind: TxKinds.refund,
      amountMinor: amountMinor,
      currency: o.currency,
      occurredAt: at ?? now,
      source: source,
      merchant: o.merchant,
      categoryId: o.categoryId,
      refundOfId: originalId,
    );
  }

  // ---------------------------------------------------------------- categories & aliases
  Stream<List<CategoryRow>> watchCategories() =>
      (db.select(db.categories)..where((c) => c.deletedAt.isNull() & c.archived.equals(false))).watch();

  Future<List<CategoryRow>> categories() =>
      (db.select(db.categories)..where((c) => c.deletedAt.isNull())).get();

  Future<CategoryRow> createCategory({required String nameEn, required String nameAr, required String icon, required int color, String kind = 'expense'}) async {
    final id = newId();
    await db.into(db.categories).insert(CategoriesCompanion.insert(
        id: id, nameEn: nameEn, nameAr: nameAr, icon: icon, color: color, kind: kind, updatedAt: now));
    await _enqueue(Entities.category, id);
    return (await (db.select(db.categories)..where((c) => c.id.equals(id))).getSingle());
  }

  Future<Map<String, (String, String?)>> merchantAliasMap() async {
    final rows = await (db.select(db.merchantAliases)..where((a) => a.deletedAt.isNull())).get();
    return {for (final r in rows) r.pattern.toLowerCase(): (r.merchant, r.categoryId)};
  }

  Future<void> upsertMerchantAlias({required String pattern, required String merchant, String? categoryId}) async {
    final existing = await (db.select(db.merchantAliases)..where((a) => a.pattern.equals(pattern.toLowerCase()))).getSingleOrNull();
    final id = existing?.id ?? newId();
    await db.into(db.merchantAliases).insertOnConflictUpdate(MerchantAliasesCompanion.insert(
        id: id, pattern: pattern.toLowerCase(), merchant: merchant, categoryId: Value(categoryId), updatedAt: now));
    await _enqueue(Entities.merchantAlias, id);
  }

  // ---------------------------------------------------------------- budgets
  Stream<List<BudgetRow>> watchBudgets() => (db.select(db.budgets)..where((b) => b.deletedAt.isNull())).watch();

  Future<BudgetRow> saveBudget({String? id, String? categoryId, required int amountMinor, required String currency, String period = 'cycle', bool rollover = false, String thresholds = '80,100'}) async {
    final rowId = id ?? newId();
    final before = await (db.select(db.budgets)..where((b) => b.id.equals(rowId))).getSingleOrNull();
    await db.into(db.budgets).insertOnConflictUpdate(BudgetsCompanion.insert(
          id: rowId,
          categoryId: Value(categoryId),
          amountMinor: amountMinor,
          currency: currency,
          period: period,
          rollover: Value(rollover),
          alertThresholds: Value(thresholds),
          startDate: before?.startDate ?? now,
          updatedAt: now,
          version: Value(before?.version ?? 0),
        ));
    await _audit(Entities.budget, rowId, before == null ? 'create' : 'update', before, null);
    await _enqueue(Entities.budget, rowId);
    return (await (db.select(db.budgets)..where((b) => b.id.equals(rowId))).getSingle());
  }

  Future<void> deleteBudget(String id) async {
    await (db.update(db.budgets)..where((b) => b.id.equals(id))).write(BudgetsCompanion(deletedAt: Value(now), updatedAt: Value(now)));
    await _enqueue(Entities.budget, id);
  }

  // ---------------------------------------------------------------- goals
  Stream<List<GoalRow>> watchGoals() =>
      (db.select(db.goals)..where((g) => g.deletedAt.isNull() & g.archived.equals(false))).watch();

  Stream<List<GoalContributionRow>> watchContributions() => db.select(db.goalContributions).watch();

  Future<GoalRow> saveGoal({String? id, required String name, String? emoji, required int targetMinor, required String currency, DateTime? targetDate, int? plannedMonthlyMinor}) async {
    final rowId = id ?? newId();
    final before = await (db.select(db.goals)..where((g) => g.id.equals(rowId))).getSingleOrNull();
    await db.into(db.goals).insertOnConflictUpdate(GoalsCompanion.insert(
          id: rowId,
          name: name,
          emoji: Value(emoji),
          targetMinor: targetMinor,
          currency: currency,
          targetDate: Value(targetDate),
          plannedMonthlyMinor: Value(plannedMonthlyMinor),
          updatedAt: now,
          version: Value(before?.version ?? 0),
        ));
    await _enqueue(Entities.goal, rowId);
    return (await (db.select(db.goals)..where((g) => g.id.equals(rowId))).getSingle());
  }

  Future<void> addContribution(String goalId, int amountMinor, {String? note, DateTime? date}) async {
    await db.into(db.goalContributions).insert(GoalContributionsCompanion.insert(
        id: newId(), goalId: goalId, amountMinor: amountMinor, date: date ?? now, note: Value(note)));
    await (db.update(db.goals)..where((g) => g.id.equals(goalId))).write(GoalsCompanion(updatedAt: Value(now)));
    await _enqueue(Entities.goal, goalId);
  }

  Future<void> archiveGoal(String id) async {
    await (db.update(db.goals)..where((g) => g.id.equals(id))).write(GoalsCompanion(archived: const Value(true), updatedAt: Value(now)));
    await _enqueue(Entities.goal, id);
  }

  // ---------------------------------------------------------------- recurring
  Stream<List<RecurringRow>> watchRecurring() =>
      (db.select(db.recurrings)..where((r) => r.deletedAt.isNull())..orderBy([(r) => OrderingTerm(expression: r.nextDueDate)])).watch();

  Future<List<RecurringRow>> recurring() => (db.select(db.recurrings)..where((r) => r.deletedAt.isNull())).get();

  Future<RecurringRow> saveRecurring(RecurringsCompanion c) async {
    final id = c.id.present ? c.id.value : newId();
    await db.into(db.recurrings).insertOnConflictUpdate(c.copyWith(id: Value(id), updatedAt: Value(now)));
    await _enqueue(Entities.recurring, id);
    return (await (db.select(db.recurrings)..where((r) => r.id.equals(id))).getSingle());
  }

  Future<void> setRecurringStatus(String id, String status) async {
    await (db.update(db.recurrings)..where((r) => r.id.equals(id))).write(RecurringsCompanion(status: Value(status), updatedAt: Value(now)));
    await _enqueue(Entities.recurring, id);
  }

  Future<void> deleteRecurring(String id) async {
    await (db.update(db.recurrings)..where((r) => r.id.equals(id))).write(RecurringsCompanion(deletedAt: Value(now), updatedAt: Value(now)));
    await _enqueue(Entities.recurring, id);
  }

  // ---------------------------------------------------------------- assets
  Stream<List<AssetRow>> watchAssets() => (db.select(db.assets)..where((a) => a.deletedAt.isNull())).watch();

  Future<AssetRow> saveAsset({String? id, required String name, required String kind, required int valueMinor, required String currency, bool isLiability = false, DateTime? valuationDate, String? linkedAccountId, String? note}) async {
    final rowId = id ?? newId();
    await db.into(db.assets).insertOnConflictUpdate(AssetsCompanion.insert(
          id: rowId,
          name: name,
          kind: kind,
          isLiability: Value(isLiability),
          valueMinor: valueMinor,
          currency: currency,
          valuationDate: valuationDate ?? now,
          linkedAccountId: Value(linkedAccountId),
          note: Value(note),
          updatedAt: now,
        ));
    await _enqueue(Entities.asset, rowId);
    return (await (db.select(db.assets)..where((a) => a.id.equals(rowId))).getSingle());
  }

  Future<void> deleteAsset(String id) async {
    await (db.update(db.assets)..where((a) => a.id.equals(id))).write(AssetsCompanion(deletedAt: Value(now), updatedAt: Value(now)));
    await _enqueue(Entities.asset, id);
  }

  // ---------------------------------------------------------------- source events
  Stream<List<SourceEventRow>> watchSourceEvents({int limit = 50}) => (db.select(db.sourceEvents)
        ..orderBy([(s) => OrderingTerm(expression: s.receivedAt, mode: OrderingMode.desc)])
        ..limit(limit))
      .watch();

  Stream<List<SourceEventRow>> watchReviewEvents() => (db.select(db.sourceEvents)
        ..where((s) => s.status.equals('review'))
        ..orderBy([(s) => OrderingTerm(expression: s.receivedAt, mode: OrderingMode.desc)]))
      .watch();

  /// Delete raw text past its retention window. Run on app start and daily.
  Future<int> purgeExpiredRawText() => (db.update(db.sourceEvents)
        ..where((s) => s.purgeAfter.isSmallerThanValue(now) & s.rawText.isNotNull()))
      .write(const SourceEventsCompanion(rawText: Value(null)));

  /// Wipe all local financial data (logout with "remove data", or account deletion).
  Future<void> wipeAll() async {
    await db.transaction(() async {
      // Children before parents (foreign keys are enforced), then everything else.
      final ordered = <TableInfo>[db.transactionSplits, db.goalContributions, db.transactions, db.goals, db.accounts];
      for (final t in ordered) {
        await db.delete(t).go();
      }
      for (final t in db.allTables) {
        if (!ordered.contains(t)) await db.delete(t).go();
      }
    });
    await ensureSeeded();
  }
}
