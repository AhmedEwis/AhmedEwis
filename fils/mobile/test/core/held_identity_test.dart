// Codex review round 4: held-capture grouping must be identity-safe; the settlement
// predicate must require an incoming posted purchase.
import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/core/parsing/models.dart';
import 'package:fils/core/time/kuwait_time.dart';
import 'package:fils/data/db/database.dart';
import 'package:fils/data/ingestion.dart';
import 'package:fils/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_db.dart';

final t0 = DateTime.utc(2026, 11, 22, 11, 5);
RawEvent ev(String text, DateTime at, {required String sender, String? id, SourceKind src = SourceKind.sms, Map<String, String>? fields}) =>
    RawEvent(text: text, receivedAt: at, source: src, sender: sender, sourceId: id, fields: fields);

Future<SourceEventRow> event(FinanceStore s, String id) => (s.db.select(s.db.sourceEvents)..where((x) => x.id.equals(id))).getSingle();

/// Everything about a held capture and the ledger that must not change.
Future<String> snapshot(FinanceStore s, String eventId, Iterable<String> accountIds) async {
  final e = await event(s, eventId);
  final txs = <String>[];
  for (final a in accountIds) {
    for (final t in await s.transactionsForAccount(a)) {
      txs.add('${t.id}:${t.status}:${t.amountMinor}:${t.deletedAt}:${t.accountId}');
    }
  }
  txs.sort();
  return '${e.status}|${e.transactionId}|${e.rawText}|${e.matchCandidates}|${e.notes}|${txs.join(',')}';
}

const settle11 = 'Purchase of KWD 11.000 at STARBUCKS on card ending 1234';

/// NBK and KFH both own a card •1234. Each bank has pending 10.000 and 12.000 at
/// STARBUCKS, so the identical settlement text is held independently for each bank:
/// NBK via SMS, KFH via notification, 30 seconds apart.
Future<({String nbkHeld, String kfhHeld, String nbk, String kfh, List<String> nbkCands, List<String> kfhCands})> crossBank(FinanceStore s) async {
  final nbk = await s.createAccount(name: 'NBK', kind: 'card', currency: 'KWD', institutionId: 'nbk', maskLast4: '1234');
  final kfh = await s.createAccount(name: 'KFH', kind: 'card', currency: 'KWD', institutionId: 'kfh', maskLast4: '1234');
  final ing = IngestionService(s);
  for (final (bank, src) in [('NBK', SourceKind.sms), ('KFH', SourceKind.notification)]) {
    await ing.ingest(ev('Authorization of KWD 10.000 at STARBUCKS on card ending 1234 is pending', t0, sender: bank, src: src, id: '$bank-a'));
    await ing.ingest(ev('Authorization of KWD 12.000 at STARBUCKS on card ending 1234 is pending', t0.add(const Duration(minutes: 1)), sender: bank, src: src, id: '$bank-b'));
  }
  final n = await ing.ingest(ev(settle11, t0.add(const Duration(hours: 1)), sender: 'NBK', id: 'nbk-st'));
  final k = await ing.ingest(ev(settle11, t0.add(const Duration(hours: 1, seconds: 30)), sender: 'KFH', src: SourceKind.notification, id: 'kfh-st'));
  expect(n.outcome, IngestOutcome.possibleDuplicate);
  expect(k.outcome, IngestOutcome.possibleDuplicate);
  final nc = (await event(s, n.sourceEventId)).matchCandidates!.split(',');
  final kc = (await event(s, k.sourceEventId)).matchCandidates!.split(',');
  for (final c in nc) {
    expect((await s.transaction(c))!.accountId, nbk.id, reason: 'NBK candidates are NBK authorizations');
  }
  for (final c in kc) {
    expect((await s.transaction(c))!.accountId, kfh.id, reason: 'KFH candidates are KFH authorizations');
  }
  return (nbkHeld: n.sourceEventId, kfhHeld: k.sourceEventId, nbk: nbk.id, kfh: kfh.id, nbkCands: nc, kfhCands: kc);
}

void main() {
  group('held captures from different banks with identical text are independent', () {
    for (final action in ['same', 'separate', 'dismiss']) {
      for (final actOnNbk in [true, false]) {
        test('$action on ${actOnNbk ? 'NBK' : 'KFH'} leaves the other bank\'s held capture and records unchanged', () async {
          final s = await newTestStore(now: t0);
          final x = await crossBank(s);
          final (actOn, other, cands, otherAcct) =
              actOnNbk ? (x.nbkHeld, x.kfhHeld, x.nbkCands, x.kfh) : (x.kfhHeld, x.nbkHeld, x.kfhCands, x.nbk);
          final before = await snapshot(s, other, [otherAcct]);
          final ing = IngestionService(s);
          switch (action) {
            case 'same':
              await ing.confirmSameTransaction(actOn, cands.first);
            case 'separate':
              await ing.confirmSeparate(actOn);
            case 'dismiss':
              expect(await ing.dismissHeld(actOn), isTrue);
          }
          expect((await event(s, actOn)).status, isNot(kHeld));
          expect(await snapshot(s, other, [otherAcct]), before);
          expect((await event(s, other)).status, kHeld);
          // The other bank's capture can still be resolved on its own.
          final otherCands = (await event(s, other)).matchCandidates!.split(',');
          final r = await ing.confirmSameTransaction(other, otherCands.first);
          expect(r.outcome, IngestOutcome.settledPending);
          expect((await s.transaction(otherCands.first))!.accountId, otherAcct);
        });
      }
    }
  });

  test('same bank, conflicting accounts (two NBK accounts •1234): identical text via SMS and notification is not grouped', () async {
    final s = await newTestStore(now: t0);
    final a1 = await s.createAccount(name: 'NBK debit', kind: 'card', currency: 'KWD', institutionId: 'nbk', maskLast4: '1234');
    final a2 = await s.createAccount(name: 'NBK credit', kind: 'card', currency: 'KWD', institutionId: 'nbk', maskLast4: '1234');
    final ing = IngestionService(s);
    // Two unassigned Wallet purchases make each bank message ambiguous → held.
    await ing.ingest(ev('', t0, sender: 'Wallet', src: SourceKind.wallet, id: 'wa', fields: {'merchant': 'Caribou Coffee', 'amount': 'KWD 1.500'}));
    await ing.ingest(ev('', t0.add(const Duration(minutes: 1)), sender: 'Wallet', src: SourceKind.wallet, id: 'wb', fields: {'merchant': 'Caribou Coffee', 'amount': 'KWD 1.500'}));
    const m = 'Purchase of KWD 1.500 at CARIBOU COFFEE card ending 1234';
    final sms = await ing.ingest(ev(m, t0.add(const Duration(minutes: 2)), sender: 'NBK', id: 'sms'));
    final note = await ing.ingest(ev(m, t0.add(const Duration(minutes: 2, seconds: 30)), sender: 'NBK', src: SourceKind.notification, id: 'n'));
    expect(sms.outcome, IngestOutcome.possibleDuplicate);
    expect(note.outcome, IngestOutcome.possibleDuplicate);
    final wallets = (await s.allTransactions()).map((t) => t.accountId).toSet();
    final before = await snapshot(s, note.sourceEventId, [...wallets, a1.id, a2.id]);
    final cands = (await event(s, sms.sourceEventId)).matchCandidates!.split(',');
    await ing.confirmSameTransaction(sms.sourceEventId, cands.first);
    final after = await snapshot(s, note.sourceEventId, [...wallets, a1.id, a2.id]);
    // The held notification itself must be untouched (status, raw text, candidates).
    expect(after.split('|').take(5).join('|'), before.split('|').take(5).join('|'));
    expect((await event(s, note.sourceEventId)).status, kHeld);
    // Dismissing the other one must not touch the first's completed resolution either.
    expect(await ing.dismissHeld(note.sourceEventId), isTrue);
    expect((await event(s, sms.sourceEventId)).status, 'merged');
  });

  test('a genuine re-delivery on the same known account is still grouped and resolved together', () async {
    final s = await newTestStore(now: t0);
    await s.createAccount(name: 'NBK', kind: 'card', currency: 'KWD', institutionId: 'nbk', maskLast4: '1234');
    final ing = IngestionService(s);
    await ing.ingest(ev('Authorization of KWD 10.000 at STARBUCKS on card ending 1234 is pending', t0, sender: 'NBK', id: 'a'));
    await ing.ingest(ev('Authorization of KWD 12.000 at STARBUCKS on card ending 1234 is pending', t0, sender: 'NBK', id: 'b'));
    final h = await ing.ingest(ev(settle11, t0.add(const Duration(hours: 1)), sender: 'NBK', id: 'st'));
    final tw = await ing.ingest(ev(settle11, t0.add(const Duration(hours: 1, seconds: 20)), sender: 'NBK', src: SourceKind.notification, id: 'n'));
    expect(tw.outcome, IngestOutcome.possibleDuplicate);
    final c = (await event(s, h.sourceEventId)).matchCandidates!.split(',').first;
    await ing.confirmSameTransaction(h.sourceEventId, c);
    expect((await event(s, tw.sourceEventId)).status, 'merged');
    expect((await event(s, tw.sourceEventId)).transactionId, c);
  });

  group('settlement predicate requires an incoming posted purchase', () {
    test('Shortcut repeat of a pending authorization, confirmed Same, stays pending; the real settlement then posts 11.000 once', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      const auth = 'Authorization of KWD 10.000 at STARBUCKS on card ending 1234 is pending';
      final a = await ing.ingest(ev(auth, t0, sender: '+96550000000', src: SourceKind.shortcut, id: 'run-1'));
      expect((await s.transaction(a.transactionId!))!.status, TxStatuses.pending);
      final rep = await ing.ingest(ev(auth, t0.add(const Duration(minutes: 1)), sender: '+96550000000', src: SourceKind.shortcut, id: 'run-2'));
      expect(rep.outcome, IngestOutcome.possibleDuplicate);
      final r = await ing.confirmSameTransaction(rep.sourceEventId, a.transactionId!);
      expect(r.outcome, IngestOutcome.merged, reason: 'a repeated authorization is not a settlement');
      final tx = (await s.transaction(a.transactionId!))!;
      expect(tx.status, TxStatuses.pending);
      expect(tx.amountMinor, 10000);

      final st = await ing.ingest(ev('Purchase of KWD 11.000 at STARBUCKS on card ending 1234', t0.add(const Duration(hours: 2)), sender: '+96550000000', src: SourceKind.shortcut, id: 'run-3'));
      expect(st.outcome, IngestOutcome.settledPending);
      final txs = (await s.allTransactions()).where((t) => t.deletedAt == null).toList();
      expect(txs.length, 1);
      expect(txs.single.status, TxStatuses.posted);
      expect(txs.single.amountMinor, 11000);
      expect(totalsFor(txs, calendarMonth(t0)).spentIn('KWD'), 11000);
    });

    test('ingest path: a second pending authorization never settles the first', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      await ing.ingest(ev('Authorization of KWD 10.000 at STARBUCKS on card ending 1234 is pending', t0, sender: 'NBK', id: 'a'));
      final b = await ing.ingest(ev('Authorization of KWD 10.500 at STARBUCKS on card ending 1234 is pending', t0.add(const Duration(minutes: 30)), sender: 'NBK', id: 'b'));
      expect(b.outcome, IngestOutcome.posted);
      expect((await s.allTransactions()).where((t) => t.status == TxStatuses.pending).length, 2);
    });
  });
}
