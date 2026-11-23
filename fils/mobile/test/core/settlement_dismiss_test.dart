// Codex review round 3: ambiguous pending settlement, and conditional dismissal.
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
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
RawEvent ev(String text, DateTime at, {String? id, SourceKind src = SourceKind.sms}) =>
    RawEvent(text: text, receivedAt: at, source: src, sender: 'NBK', sourceId: id);

const auth10 = 'Authorization of KWD 10.000 at STARBUCKS on card ending 1234 is pending';
const auth12 = 'Authorization of KWD 12.000 at STARBUCKS on card ending 1234 is pending';
const settle11 = 'Purchase of KWD 11.000 at STARBUCKS on card ending 1234';

Future<SourceEventRow> event(FinanceStore s, String id) => (s.db.select(s.db.sourceEvents)..where((x) => x.id.equals(id))).getSingle();

/// Pending 10.000 and 12.000 (same merchant and account), then a settlement of 11.000.
Future<({String a10, String a12, String held})> twoAuthsAndSettlement(FinanceStore s) async {
  final ing = IngestionService(s);
  final a = await ing.ingest(ev(auth10, t0, id: 'p10'));
  final b = await ing.ingest(ev(auth12, t0.add(const Duration(minutes: 1)), id: 'p12'));
  final r = await ing.ingest(ev(settle11, t0.add(const Duration(hours: 1)), id: 'st'));
  expect(r.outcome, IngestOutcome.possibleDuplicate, reason: 'both authorizations pass ±20%: hold, never pick the first');
  return (a10: a.transactionId!, a12: b.transactionId!, held: r.sourceEventId);
}

Future<String> status(FinanceStore s, String txId) async => (await s.transaction(txId))!.status;

void main() {
  group('ambiguous pending settlement', () {
    test('held: both authorizations stay pending, totals unchanged, both offered as candidates', () async {
      final s = await newTestStore(now: t0);
      final before = totalsFor(await s.allTransactions(), calendarMonth(t0)).spentIn('KWD');
      final x = await twoAuthsAndSettlement(s);
      expect(await status(s, x.a10), TxStatuses.pending);
      expect(await status(s, x.a12), TxStatuses.pending);
      expect((await s.transaction(x.a10))!.amountMinor, 10000);
      expect(totalsFor(await s.allTransactions(), calendarMonth(t0)).spentIn('KWD'), before + 22000);
      expect((await event(s, x.held)).matchCandidates!.split(',').toSet(), {x.a10, x.a12});
    });

    test('Same transaction settles exactly the chosen authorization, atomically; retry, other choice, restart, crash change nothing', () async {
      final dir = await Directory.systemTemp.createTemp('fils_settle');
      final f = File('${dir.path}/s.db');
      var db = AppDatabase(NativeDatabase(f));
      var s = FinanceStore(db, clock: () => t0);
      await s.ensureSeeded();
      final x = await twoAuthsAndSettlement(s);
      // Crash inside the resolution: nothing settled.
      await expectLater(IngestionService(s, faultInjector: (_) => throw StateError('killed')).confirmSameTransaction(x.held, x.a12), throwsStateError);
      expect(await status(s, x.a12), TxStatuses.pending);
      expect((await event(s, x.held)).status, kHeld);

      final r = await IngestionService(s).confirmSameTransaction(x.held, x.a12);
      expect(r.outcome, IngestOutcome.settledPending);
      expect(await status(s, x.a12), TxStatuses.posted);
      expect((await s.transaction(x.a12))!.amountMinor, 11000);
      expect(await status(s, x.a10), TxStatuses.pending);
      // A late tap for the other authorization, or Separate, is a no-op.
      expect((await IngestionService(s).confirmSameTransaction(x.held, x.a10)).message, 'already resolved');
      expect((await IngestionService(s).confirmSeparate(x.held)).message, 'already resolved');
      await db.close();
      db = AppDatabase(NativeDatabase(f));
      s = FinanceStore(db, clock: () => t0);
      expect((await IngestionService(s).confirmSameTransaction(x.held, x.a10)).message, 'already resolved');
      expect(await status(s, x.a10), TxStatuses.pending);
      expect((await s.allTransactions()).length, 2);
      await db.close();
      await dir.delete(recursive: true);
    });

    test('a candidate outside the suggested set is refused', () async {
      final s = await newTestStore(now: t0);
      final x = await twoAuthsAndSettlement(s);
      final other = await IngestionService(s).ingest(ev('Purchase of KWD 3.000 at TALABAT card ending 1234', t0, id: 'o'));
      await expectLater(IngestionService(s).confirmSameTransaction(x.held, other.transactionId!), throwsStateError);
      expect((await event(s, x.held)).status, kHeld);
    });

    test('cross-source re-delivery AFTER resolution merges into the settled one and never settles the other', () async {
      final s = await newTestStore(now: t0);
      final x = await twoAuthsAndSettlement(s);
      await IngestionService(s).confirmSameTransaction(x.held, x.a10);
      final r = await IngestionService(s).ingest(ev(settle11, t0.add(const Duration(hours: 1, seconds: 20)), id: 'n1', src: SourceKind.notification));
      expect(r.outcome, IngestOutcome.merged);
      expect(r.transactionId, x.a10);
      expect(await status(s, x.a12), TxStatuses.pending);
      expect((await s.transaction(x.a12))!.amountMinor, 12000);
      expect((await s.allTransactions()).length, 2);
    });

    test('cross-source re-delivery WHILE held is held with it and resolved together (one settlement)', () async {
      final s = await newTestStore(now: t0);
      final x = await twoAuthsAndSettlement(s);
      final r = await IngestionService(s).ingest(ev(settle11, t0.add(const Duration(hours: 1, seconds: 20)), id: 'n1', src: SourceKind.notification));
      expect(r.outcome, IngestOutcome.possibleDuplicate);
      expect(await status(s, x.a10), TxStatuses.pending);
      expect(await status(s, x.a12), TxStatuses.pending);
      await IngestionService(s).confirmSameTransaction(x.held, x.a10);
      final twin = await event(s, r.sourceEventId);
      expect(twin.status, 'merged');
      expect(twin.transactionId, x.a10);
      expect(await status(s, x.a12), TxStatuses.pending);
      // The twin can no longer be resolved separately.
      expect((await IngestionService(s).confirmSameTransaction(r.sourceEventId, x.a12)).message, 'already resolved');
      expect(await status(s, x.a12), TxStatuses.pending);
    });

    test('Separate purchase posts 11.000 once and leaves both authorizations pending', () async {
      final s = await newTestStore(now: t0);
      final x = await twoAuthsAndSettlement(s);
      final r = await IngestionService(s).confirmSeparate(x.held);
      expect(r.outcome, IngestOutcome.posted);
      expect((await s.transaction(r.transactionId!))!.amountMinor, 11000);
      expect(await status(s, x.a10), TxStatuses.pending);
      expect(await status(s, x.a12), TxStatuses.pending);
      await IngestionService(s).confirmSeparate(x.held);
      expect((await s.allTransactions()).length, 3);
    });

    test('exactly one qualifying authorization still settles directly', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      final a = await ing.ingest(ev(auth10, t0, id: 'p10'));
      await ing.ingest(ev('Authorization of KWD 20.000 at STARBUCKS on card ending 1234 is pending', t0, id: 'p20'));
      final r = await ing.ingest(ev(settle11, t0.add(const Duration(hours: 1)), id: 'st'));
      expect(r.outcome, IngestOutcome.settledPending);
      expect(r.transactionId, a.transactionId);
    });
  });

  group('conditional, atomic dismissal', () {
    Future<(FinanceStore, String)> held() async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      const m = 'Purchase of KWD 1.500 at CARIBOU COFFEE card ending 1234';
      final first = await ing.ingest(ev(m, t0, src: SourceKind.paste));
      expect(first.outcome, IngestOutcome.posted);
      final h = await ing.ingest(ev(m, t0.add(const Duration(seconds: 30)), src: SourceKind.paste));
      expect(h.outcome, IngestOutcome.possibleDuplicate);
      return (s, h.sourceEventId);
    }

    test('Separate then Dismiss: Dismiss is refused, the resolution stands', () async {
      final (s, id) = await held();
      final r = await IngestionService(s).confirmSeparate(id);
      expect(await IngestionService(s).dismissHeld(id), isFalse);
      final e = await event(s, id);
      expect(e.status, 'posted');
      expect(e.transactionId, r.transactionId);
      expect((await s.allTransactions()).length, 2);
    });

    test('Same then Dismiss: Dismiss is refused, the link stands', () async {
      final (s, id) = await held();
      final cand = (await event(s, id)).matchCandidates!;
      await IngestionService(s).confirmSameTransaction(id, cand);
      expect(await IngestionService(s).dismissHeld(id), isFalse);
      final e = await event(s, id);
      expect(e.status, 'merged');
      expect(e.transactionId, cand);
    });

    test('Dismiss then Separate / Same: both are no-ops; nothing posted', () async {
      final (s, id) = await held();
      final cand = (await event(s, id)).matchCandidates!;
      expect(await IngestionService(s).dismissHeld(id), isTrue);
      expect((await IngestionService(s).confirmSeparate(id)).outcome, IngestOutcome.ignored);
      expect((await IngestionService(s).confirmSameTransaction(id, cand)).outcome, IngestOutcome.ignored);
      expect(await IngestionService(s).dismissHeld(id), isFalse);
      final e = await event(s, id);
      expect(e.status, 'ignored');
      expect(e.transactionId, isNull);
      expect((await s.allTransactions()).length, 1);
    });

    test('Dismiss also resolves a held re-delivery of the same message', () async {
      final s = await newTestStore(now: t0);
      final x = await twoAuthsAndSettlement(s);
      final r = await IngestionService(s).ingest(ev(settle11, t0.add(const Duration(hours: 1, seconds: 20)), id: 'n1', src: SourceKind.notification));
      expect(await IngestionService(s).dismissHeld(x.held), isTrue);
      expect((await event(s, r.sourceEventId)).status, 'ignored');
      expect(await status(s, x.a10), TxStatuses.pending);
      expect(await status(s, x.a12), TxStatuses.pending);
    });

    test('competing connections: Dismiss vs Separate and Dismiss vs Same, both orders, 2 × 12 races; never both, never torn', () async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final dir = await Directory.systemTemp.createTemp('fils_race');
      final f = File('${dir.path}/race.db');
      void setup(dynamic db) {
        db.execute('PRAGMA journal_mode = WAL');
        db.execute('PRAGMA busy_timeout = 5000');
      }

      final dbA = AppDatabase(NativeDatabase.createInBackground(f, setup: setup));
      final a = FinanceStore(dbA, clock: () => t0);
      await a.ensureSeeded();
      final dbB = AppDatabase(NativeDatabase.createInBackground(f, setup: setup));
      final b = FinanceStore(dbB, clock: () => t0);
      final ingA = IngestionService(a), ingB = IngestionService(b);
      var dismissedWins = 0, resolutionWins = 0;
      for (var i = 0; i < 24; i++) {
        final m = 'Purchase of KWD ${i + 1}.250 at CARIBOU COFFEE card ending 1234';
        await ingA.ingest(ev(m, t0.add(Duration(hours: i)), src: SourceKind.paste));
        final h = await ingA.ingest(ev(m, t0.add(Duration(hours: i, seconds: 30)), src: SourceKind.paste));
        final cand = (await event(a, h.sourceEventId)).matchCandidates!;
        final useSame = i.isEven;
        Future<Object> resolve(IngestionService ing) => useSame ? ing.confirmSameTransaction(h.sourceEventId, cand) : ing.confirmSeparate(h.sourceEventId);
        final results = i % 4 < 2
            ? await Future.wait<Object>([resolve(ingA), ingB.dismissHeld(h.sourceEventId)])
            : await Future.wait<Object>([ingA.dismissHeld(h.sourceEventId), resolve(ingB)]);
        final dismissed = results.whereType<bool>().single;
        final e = await event(a, h.sourceEventId);
        final linked = (await a.allTransactions(includeDeleted: true)).where((t) => t.sourceEventId == h.sourceEventId).toList();
        if (dismissed) {
          dismissedWins++;
          expect(e.status, 'ignored');
          expect(e.transactionId, isNull);
          expect(linked, isEmpty, reason: 'race $i: dismissed but a transaction was created');
        } else {
          resolutionWins++;
          expect(e.status, useSame ? 'merged' : 'posted', reason: 'race $i');
          expect(e.transactionId, isNotNull);
          expect(linked.length, useSame ? 0 : 1);
        }
      }
      expect(dismissedWins + resolutionWins, 24);
      // ignore: avoid_print
      print('races: dismiss won $dismissedWins, resolution won $resolutionWins');
      await dbA.close();
      await dbB.close();
      await dir.delete(recursive: true);
    });
  });
}
