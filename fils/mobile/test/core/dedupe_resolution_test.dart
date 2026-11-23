// Codex review round 2: every dedupe path uses the same rules; uncertain captures are
// held without ledger effect until the user resolves them; resolution is atomic and
// idempotent across retry, restart and sync.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/core/parsing/models.dart';
import 'package:fils/core/time/kuwait_time.dart';
import 'package:fils/data/db/database.dart';
import 'package:fils/data/ingestion.dart';
import 'package:fils/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_db.dart';

final t0 = DateTime.utc(2026, 11, 22, 11, 5);

RawEvent ev(String text, DateTime at, {String? sender, String? id, SourceKind src = SourceKind.sms, Map<String, String>? fields}) =>
    RawEvent(text: text, receivedAt: at, source: src, sender: sender, sourceId: id, fields: fields);

Future<int> spentNow(FinanceStore s) async => totalsFor(await s.allTransactions(), calendarMonth(t0)).spentIn('KWD');

/// Distinct transaction ids waiting in the sync outbox.
Future<Set<String>> outboxTx(FinanceStore s) async =>
    (await (s.db.select(s.db.outbox)..where((o) => o.entity.equals(Entities.transaction))).get()).map((o) => o.entityId).toSet();

/// Two Wallet purchases of KWD 1.500, then a bank message that matches both.
Future<String> ambiguousSetup(FinanceStore s) async {
  final ing = IngestionService(s);
  await ing.ingest(ev('', t0, src: SourceKind.wallet, id: 'wa', fields: {'merchant': 'Caribou Coffee', 'amount': 'KWD 1.500'}));
  await ing.ingest(ev('', t0.add(const Duration(minutes: 1)), src: SourceKind.wallet, id: 'wb', fields: {'merchant': 'Caribou Coffee', 'amount': 'KWD 1.500'}));
  expect(await spentNow(s), 3000);
  final r = await ing.ingest(ev('Purchase of KWD 1.500 at CARIBOU COFFEE card ending 1234', t0.add(const Duration(minutes: 2)), sender: 'NBK', id: 'sms-77'));
  expect(r.outcome, IngestOutcome.possibleDuplicate);
  expect(r.transactionId, isNull);
  expect(await spentNow(s), 3000, reason: 'held: no ledger effect');
  return r.sourceEventId;
}

Future<(FinanceStore, Future<FinanceStore> Function(), Future<void> Function())> fileStore() async {
  final dir = await Directory.systemTemp.createTemp('fils_res');
  final f = File('${dir.path}/r.db');
  var db = AppDatabase(NativeDatabase(f));
  final s = FinanceStore(db, clock: () => t0);
  await s.ensureSeeded();
  Future<FinanceStore> restart() async {
    await db.close();
    db = AppDatabase(NativeDatabase(f));
    return FinanceStore(db, clock: () => t0);
  }

  Future<void> done() async {
    await db.close();
    await dir.delete(recursive: true);
  }

  return (s, restart, done);
}

void main() {
  group('ambiguous match: held, then resolved', () {
    test('link to an existing purchase keeps KWD 3.000 — idempotent across retry, restart, crash; nothing new to sync', () async {
      final (s0, restart, done) = await fileStore();
      final heldId = await ambiguousSetup(s0);
      final cands = (await (s0.db.select(s0.db.sourceEvents)..where((x) => x.id.equals(heldId))).getSingle()).matchCandidates!.split(',');
      final syncBefore = await outboxTx(s0);
      expect(syncBefore.length, 2);

      // Crash mid-resolution: nothing changes, still held.
      final crashing = IngestionService(s0, faultInjector: (st) => throw StateError('killed'));
      await expectLater(crashing.confirmSameTransaction(heldId, cands.first), throwsStateError);
      expect((await (s0.db.select(s0.db.sourceEvents)..where((x) => x.id.equals(heldId))).getSingle()).status, kHeld);

      final r = await IngestionService(s0).confirmSameTransaction(heldId, cands.first);
      expect(r.outcome, IngestOutcome.merged);
      expect(await spentNow(s0), 3000);
      // Retry (double tap) and a contradictory late tap are no-ops.
      expect((await IngestionService(s0).confirmSameTransaction(heldId, cands.first)).message, 'already resolved');
      expect((await IngestionService(s0).confirmSeparate(heldId)).message, 'already resolved');
      // Restart.
      final s1 = await restart();
      expect((await IngestionService(s1).confirmSeparate(heldId)).message, 'already resolved');
      expect(await spentNow(s1), 3000);
      expect((await s1.allTransactions()).length, 2);
      // Sync: no new transaction to upload; only the two existing ids (one updated).
      expect(await outboxTx(s1), syncBefore);
      // Replay of the original bank message (inbox not acked before a crash) is a duplicate.
      final again = await IngestionService(s1).ingest(ev('Purchase of KWD 1.500 at CARIBOU COFFEE card ending 1234', t0.add(const Duration(minutes: 2)), sender: 'NBK', id: 'sms-77'));
      expect(again.outcome, IngestOutcome.duplicate);
      expect(await spentNow(s1), 3000);
      await done();
    });

    test('confirm as separate purchase gives KWD 4.500 exactly once — across retry, restart, crash; one new transaction to sync', () async {
      final (s0, restart, done) = await fileStore();
      final heldId = await ambiguousSetup(s0);
      final syncBefore = await outboxTx(s0);

      final crashing = IngestionService(s0, faultInjector: (st) => throw StateError('killed'));
      await expectLater(crashing.confirmSeparate(heldId), throwsStateError);
      expect(await spentNow(s0), 3000, reason: 'crash rolled the new transaction back');
      expect(await outboxTx(s0), syncBefore);

      final r = await IngestionService(s0).confirmSeparate(heldId);
      expect(r.outcome, IngestOutcome.posted);
      expect(await spentNow(s0), 4500);
      expect((await IngestionService(s0).confirmSeparate(heldId)).message, 'already resolved');
      final s1 = await restart();
      expect((await IngestionService(s1).confirmSeparate(heldId)).transactionId, r.transactionId);
      expect(await spentNow(s1), 4500);
      final txs = await s1.allTransactions();
      expect(txs.length, 3);
      final created = txs.singleWhere((t) => t.id == r.transactionId);
      expect(created.needsReview, isFalse, reason: 'a confirmed purchase counts normally');
      expect(created.sourceEventId, heldId);
      expect(await outboxTx(s1), {...syncBefore, r.transactionId!});
      final again = await IngestionService(s1).ingest(ev('Purchase of KWD 1.500 at CARIBOU COFFEE card ending 1234', t0.add(const Duration(minutes: 2)), sender: 'NBK', id: 'sms-77'));
      expect(again.outcome, IngestOutcome.duplicate);
      expect(await spentNow(s1), 4500);
      await done();
    });

    test('a purchase flagged only for category review still counts (needsReview is not excluded wholesale)', () async {
      final s = await newTestStore(now: t0);
      final a = await s.createAccount(name: 'A', kind: 'bank', currency: 'KWD');
      await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 2000, currency: 'KWD', occurredAt: t0, source: 'sms', needsReview: true);
      expect(await spentNow(s), 2000);
    });
  });

  group('identical text: identity and account checks on every path', () {
    const text = 'Purchase of KWD 3.000 at STARBUCKS card ending 1234';

    test('SMS from NBK and notification from KFH (both own a card •1234) stay separate', () async {
      final s = await newTestStore(now: t0);
      await s.createAccount(name: 'NBK', kind: 'card', currency: 'KWD', institutionId: 'nbk', maskLast4: '1234');
      await s.createAccount(name: 'KFH', kind: 'card', currency: 'KWD', institutionId: 'kfh', maskLast4: '1234');
      final ing = IngestionService(s);
      await ing.ingest(ev(text, t0, sender: 'NBK'));
      final r = await ing.ingest(ev(text, t0.add(const Duration(seconds: 20)), sender: 'KFH', src: SourceKind.notification, id: 'n1'));
      expect(r.outcome, IngestOutcome.posted);
      final txs = await s.allTransactions();
      expect(txs.length, 2);
      expect(txs.map((t) => t.accountId).toSet().length, 2);
      expect(await spentNow(s), 6000);
    });

    test('no card digits: NBK SMS and KFH notification route to each bank and stay separate', () async {
      final s = await newTestStore(now: t0);
      await s.createAccount(name: 'NBK', kind: 'bank', currency: 'KWD', institutionId: 'nbk');
      await s.createAccount(name: 'KFH', kind: 'bank', currency: 'KWD', institutionId: 'kfh');
      final ing = IngestionService(s);
      const t = 'Purchase of KWD 3.000 at STARBUCKS';
      await ing.ingest(ev(t, t0, sender: 'NBK'));
      await ing.ingest(ev(t, t0.add(const Duration(seconds: 20)), sender: 'KFH', src: SourceKind.notification, id: 'n1'));
      expect((await s.allTransactions()).map((x) => x.accountId).toSet().length, 2);
    });

    test('same-source identical text from different senders is not held as a repeat', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      await ing.ingest(ev(text, t0, sender: 'NBK', src: SourceKind.paste));
      final r = await ing.ingest(ev(text, t0.add(const Duration(seconds: 20)), sender: 'KFH', src: SourceKind.paste));
      expect(r.outcome, IngestOutcome.posted);
      expect((await s.allTransactions()).length, 2);
    });

    test('Shortcut: identical text from two different senders is two purchases; same sender is held', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      await ing.ingest(ev(text, t0, sender: '+96511111111', src: SourceKind.shortcut, id: 'r1'));
      final other = await ing.ingest(ev(text, t0.add(const Duration(minutes: 1)), sender: '+96522222222', src: SourceKind.shortcut, id: 'r2'));
      expect(other.outcome, IngestOutcome.posted);
      final repeat = await ing.ingest(ev(text, t0.add(const Duration(minutes: 2)), sender: '+96511111111', src: SourceKind.shortcut, id: 'r3'));
      expect(repeat.outcome, IngestOutcome.possibleDuplicate);
      expect((await s.allTransactions()).length, 2);
    });

    test('identical text via another source does not merge into a deleted or voided record', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      final a = await ing.ingest(ev(text, t0, sender: 'NBK'));
      await s.deleteTransaction(a.transactionId!);
      final b = await ing.ingest(ev(text, t0.add(const Duration(seconds: 20)), sender: 'NBK', src: SourceKind.notification, id: 'n1'));
      expect(b.outcome, IngestOutcome.posted);
      expect(b.transactionId, isNot(a.transactionId));

      final s2 = await newTestStore(now: t0);
      final ing2 = IngestionService(s2);
      await ing2.ingest(ev('Authorization of KWD 3.000 at STARBUCKS on card ending 1234 is pending', t0, sender: 'NBK'));
      await ing2.ingest(ev('Reversal of KWD 3.000 at STARBUCKS on card ending 1234', t0.add(const Duration(minutes: 1)), sender: 'NBK'));
      // A purchase arriving later never merges into the voided authorization.
      final p = await ing2.ingest(ev('', t0.add(const Duration(minutes: 3)), src: SourceKind.wallet, id: 'w9', fields: {'merchant': 'Starbucks', 'amount': 'KWD 3.000', 'card': 'Visa 1234'}));
      expect(p.outcome, IngestOutcome.posted);
      expect(totalsFor(await s2.allTransactions(), calendarMonth(t0)).spentIn('KWD'), 3000);
    });

    test('the same reversal text via a second channel is the same event (no bogus refund)', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      await ing.ingest(ev('Authorization of KWD 3.000 at STARBUCKS on card ending 1234 is pending', t0, sender: 'NBK'));
      const rev = 'Reversal of KWD 3.000 at STARBUCKS on card ending 1234';
      await ing.ingest(ev(rev, t0.add(const Duration(minutes: 1)), sender: 'NBK'));
      final c = await ing.ingest(ev(rev, t0.add(const Duration(minutes: 1, seconds: 10)), sender: 'NBK', src: SourceKind.notification, id: 'n2'));
      expect(c.outcome, IngestOutcome.merged);
      final txs = await s.allTransactions();
      expect(txs.length, 1);
      expect(txs.single.status, TxStatuses.voided);
      expect(totalsFor(txs, calendarMonth(t0)).spentIn('KWD'), 0);
      expect(txs.where((t) => t.kind == TxKinds.refund), isEmpty);
    });

    test('identical text via another source with exactly one compatible record merges (unchanged behavior)', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      await ing.ingest(ev(text, t0, sender: 'NBK'));
      final b = await ing.ingest(ev(text, t0.add(const Duration(seconds: 20)), sender: 'NBK', src: SourceKind.notification, id: 'n1'));
      expect(b.outcome, IngestOutcome.merged);
      expect(await spentNow(s), 3000);
    });
  });
}
