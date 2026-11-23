// Regression tests for the Codex review findings on ingestion (issues 1–4).
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

RawEvent ev(String text, DateTime at, {String? sender, String? id, SourceKind src = SourceKind.sms, Map<String, String>? fields}) =>
    RawEvent(text: text, receivedAt: at, source: src, sender: sender, sourceId: id, fields: fields);

Future<List<TxRow>> live(FinanceStore s) async => (await s.allTransactions()).where((t) => t.deletedAt == null).toList();

int spent(List<TxRow> txs, DateTime at) => totalsFor(txs, calendarMonth(at)).spentIn('KWD');

void main() {
  final t0 = DateTime.utc(2026, 11, 22, 11, 5);

  // ------------------------------------------------------------------ Issue 1
  group('1. atomic ingestion / replay safety', () {
    test('failure after the financial insert but before source-event completion leaves no partial state; replay posts once', () async {
      final s = await newTestStore(now: t0);
      final crashing = IngestionService(s, faultInjector: (stage) {
        if (stage == 'after_financial_write') throw StateError('simulated crash');
      });
      final e = ev('Purchase of KWD 5.250 at TALABAT card ending 1234', t0, id: 'run-1', src: SourceKind.shortcut);
      await expectLater(crashing.ingest(e), throwsStateError);
      expect(await live(s), isEmpty, reason: 'financial write must roll back with the failed event');
      expect(await s.db.select(s.db.sourceEvents).get(), isEmpty, reason: 'no half-claimed event');
      // Restart + replay of the same platform event.
      final r = await IngestionService(s).ingest(e);
      expect(r.outcome, IngestOutcome.posted);
      final r2 = await IngestionService(s).ingest(e);
      expect(r2.outcome, IngestOutcome.duplicate);
      expect((await live(s)).length, 1);
      expect(spent(await live(s), t0), 5250);
    });

    test('unique constraint on (source, platform_id) exists', () async {
      final s = await newTestStore(now: t0);
      final idx = await s.db.customSelect("SELECT sql FROM sqlite_master WHERE type='index' AND name='idx_src_platform'").getSingleOrNull();
      expect(idx?.data['sql'] as String?, contains('UNIQUE'));
    });

    test('concurrent ingestion of the same event through two database connections → one financial effect', () async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final dir = await Directory.systemTemp.createTemp('fils_conc');
      final f = File('${dir.path}/c.db');
      void setup(dynamic db) {
        db.execute('PRAGMA journal_mode = WAL');
        db.execute('PRAGMA busy_timeout = 5000');
      }

      final dbA = AppDatabase(NativeDatabase.createInBackground(f, setup: setup));
      final a = FinanceStore(dbA, clock: () => t0);
      await a.ensureSeeded();
      final dbB = AppDatabase(NativeDatabase.createInBackground(f, setup: setup));
      final b = FinanceStore(dbB, clock: () => t0);
      final e = ev('Purchase of KWD 7.500 at LULU HYPERMARKET card ending 1234', t0, id: 'inbox-42', src: SourceKind.shortcut);
      final results = await Future.wait([IngestionService(a).ingest(e), IngestionService(b).ingest(e)]);
      final outcomes = results.map((r) => r.outcome).toList()..sort((x, y) => x.index.compareTo(y.index));
      expect(outcomes, [IngestOutcome.posted, IngestOutcome.duplicate]);
      expect((await live(a)).length, 1);
      expect((await a.db.select(a.db.sourceEvents).get()).length, 1);
      // Many distinct events concurrently: none lost, none doubled.
      final es = [for (var i = 0; i < 20; i++) ev('Purchase of KWD ${i + 1}.000 at CARIBOU COFFEE card ending 1234', t0.add(Duration(hours: i)), id: 'n$i', src: SourceKind.shortcut)];
      await Future.wait([for (final x in es) IngestionService(a).ingest(x), for (final x in es) IngestionService(b).ingest(x)]);
      expect((await live(a)).length, 21);
      await dbA.close();
      await dbB.close();
      await dir.delete(recursive: true);
    });

    test('events without a platform id are never silently dropped (defined handling)', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      final m = 'Purchase of KWD 1.500 at CARIBOU COFFEE card ending 1234';
      await ing.ingest(ev(m, t0, src: SourceKind.paste));
      final r = await ing.ingest(ev(m, t0.add(const Duration(seconds: 30)), src: SourceKind.paste));
      expect(r.outcome, IngestOutcome.possibleDuplicate);
      expect((await live(s)).length, 1, reason: 'held: no second financial effect');
      final held = await (s.db.select(s.db.sourceEvents)..where((x) => x.id.equals(r.sourceEventId))).getSingle();
      expect(held.status, kHeld);
      expect(held.rawText, m, reason: 'kept so the user can resolve it');
    });
  });

  // ------------------------------------------------------------------ Issue 2
  group('2. declined / pending / posted matching', () {
    test('declined then successful purchase (cross-source) → successful purchase is posted', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      await ing.ingest(ev('Transaction of KWD 30.000 at AMAZON.COM declined due to insufficient funds. Card XXXX1234', t0, sender: 'NBK'));
      final r = await ing.ingest(ev('', t0.add(const Duration(minutes: 2)), src: SourceKind.wallet, id: 'w1', fields: {'merchant': 'Amazon', 'amount': 'KWD 30.000', 'card': 'Visa 1234'}));
      expect(r.outcome, isNot(IngestOutcome.merged));
      final txs = await live(s);
      expect(txs.where((t) => t.status == TxStatuses.declined).length, 1);
      expect(txs.where((t) => t.status == TxStatuses.posted).length, 1);
      expect(spent(txs, t0), 30000);
    });

    test('declined then successful purchase (same source) → posted', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      await ing.ingest(ev('Transaction of KWD 30.000 at AMAZON.COM declined due to insufficient funds. Card XXXX1234', t0, sender: 'NBK'));
      await ing.ingest(ev('Purchase of KWD 30.000 at AMAZON.COM with card ending 1234', t0.add(const Duration(minutes: 3)), sender: 'NBK'));
      expect(spent(await live(s), t0), 30000);
    });

    test('pending (SMS) then settlement arriving via another source still settles the pending row', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      await ing.ingest(ev('Authorization of KWD 12.000 at STARBUCKS on card ending 1234 is pending', t0, sender: 'NBK'));
      final r = await ing.ingest(ev('Purchase of KWD 12.000 at STARBUCKS on card ending 1234', t0.add(const Duration(minutes: 1)), src: SourceKind.notification, id: 'n1', sender: 'NBK'));
      expect(r.outcome, IngestOutcome.settledPending);
      final txs = await live(s);
      expect(txs.single.status, TxStatuses.posted);
      expect(spent(txs, t0), 12000);
    });

    test('reversed/voided authorization then a new purchase → new purchase posted', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      await ing.ingest(ev('Authorization of KWD 12.000 at OOREDOO KUWAIT on card ending 1234 is pending', t0));
      await ing.ingest(ev('Reversal of KWD 12.000 at OOREDOO KUWAIT on card ending 1234', t0.add(const Duration(minutes: 2))));
      final r = await ing.ingest(ev('', t0.add(const Duration(minutes: 4)), src: SourceKind.wallet, id: 'w2', fields: {'merchant': 'Ooredoo', 'amount': 'KWD 12.000', 'card': 'Visa 1234'}));
      expect(r.outcome, IngestOutcome.posted);
      final txs = await live(s);
      expect(txs.where((t) => t.status == TxStatuses.voided).length, 1);
      expect(spent(txs, t0), 12000);
    });
  });

  // ------------------------------------------------------------------ Issue 3
  group('3. account routing and Wallet dedupe', () {
    test('identical amount/merchant on two different known accounts stay separate', () async {
      final s = await newTestStore(now: t0);
      await s.createAccount(name: 'NBK', kind: 'card', currency: 'KWD', institutionId: 'nbk', maskLast4: '1111');
      await s.createAccount(name: 'KFH', kind: 'card', currency: 'KWD', institutionId: 'kfh', maskLast4: '2222');
      final ing = IngestionService(s);
      await ing.ingest(ev('Purchase of KWD 4.000 at TALABAT card ending 1111', t0, sender: 'NBK'));
      await ing.ingest(ev('', t0.add(const Duration(minutes: 1)), src: SourceKind.wallet, id: 'w', fields: {'merchant': 'Talabat', 'amount': 'KWD 4.000', 'card': 'KFH Visa 2222'}));
      final txs = await live(s);
      expect(txs.length, 2);
      expect(txs.map((t) => t.accountId).toSet().length, 2);
    });

    test('Wallet first (unassigned), bank message second → one transaction moved to the bank account', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      await ing.ingest(ev('', t0, src: SourceKind.wallet, id: 'w1', fields: {'merchant': 'Talabat', 'amount': 'KWD 5.250'}));
      final before = (await live(s)).single;
      final unassigned = (await s.account(before.accountId))!;
      expect(unassigned.institutionId, '_unassigned');
      final r = await ing.ingest(ev('Purchase of KWD 5.250 at TALABAT card ending 1234', t0.add(const Duration(minutes: 1)), sender: 'NBK'));
      expect(r.outcome, IngestOutcome.merged);
      final txs = await live(s);
      expect(txs.length, 1);
      final acct = (await s.account(txs.single.accountId))!;
      expect(acct.maskLast4, '1234');
      expect(acct.institutionId, 'nbk');
      // Ledger effects moved with it.
      expect(calculatedBalance(unassigned, await s.transactionsForAccount(unassigned.id)), 0);
      expect(calculatedBalance(acct, await s.transactionsForAccount(acct.id)), -5250);
    });

    test('bank message first, Wallet second → one transaction on the bank account, no Unassigned account created', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      await ing.ingest(ev('Purchase of KWD 5.250 at TALABAT card ending 1234', t0, sender: 'NBK'));
      final r = await ing.ingest(ev('', t0.add(const Duration(minutes: 1)), src: SourceKind.wallet, id: 'w1', fields: {'merchant': 'Talabat', 'amount': 'KWD 5.250'}));
      expect(r.outcome, IngestOutcome.merged);
      expect((await live(s)).length, 1);
      expect((await s.accounts()).where((a) => a.institutionId == '_unassigned'), isEmpty);
    });

    test('two genuine repeated purchases (Wallet + SMS each) stay two transactions', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      await ing.ingest(ev('', t0, src: SourceKind.wallet, id: 'wa', fields: {'merchant': 'Caribou Coffee', 'amount': 'KWD 1.500', 'card': 'NBK 1234'}));
      await ing.ingest(ev('Purchase of KWD 1.500 at CARIBOU COFFEE card ending 1234 on 22/11/2026 14:05', t0.add(const Duration(seconds: 30)), sender: 'NBK'));
      await ing.ingest(ev('', t0.add(const Duration(minutes: 3)), src: SourceKind.wallet, id: 'wb', fields: {'merchant': 'Caribou Coffee', 'amount': 'KWD 1.500', 'card': 'NBK 1234'}));
      await ing.ingest(ev('Purchase of KWD 1.500 at CARIBOU COFFEE card ending 1234 on 22/11/2026 14:08', t0.add(const Duration(minutes: 3, seconds: 30)), sender: 'NBK'));
      final txs = await live(s);
      expect(txs.length, 2);
      expect(spent(txs, t0), 3000);
    });

    test('ambiguous match (two candidates) is held without ledger effect until resolved', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      await ing.ingest(ev('', t0, src: SourceKind.wallet, id: 'wa', fields: {'merchant': 'Caribou Coffee', 'amount': 'KWD 1.500'}));
      await ing.ingest(ev('', t0.add(const Duration(minutes: 1)), src: SourceKind.wallet, id: 'wb', fields: {'merchant': 'Caribou Coffee', 'amount': 'KWD 1.500'}));
      expect(spent(await live(s), t0), 3000);
      final r = await ing.ingest(ev('Purchase of KWD 1.500 at CARIBOU COFFEE card ending 1234', t0.add(const Duration(minutes: 2)), sender: 'NBK'));
      expect(r.outcome, IngestOutcome.possibleDuplicate);
      expect(r.transactionId, isNull);
      expect(spent(await live(s), t0), 3000);
      final held = await (s.db.select(s.db.sourceEvents)..where((x) => x.id.equals(r.sourceEventId))).getSingle();
      expect(held.matchCandidates!.split(',').length, 2);
    });
  });

  // ------------------------------------------------------------------ Issue 4
  group('4. internal transfer false matches', () {
    test('unrelated incoming KWD 20 and outgoing KWD 20 on different accounts remain separate', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      await ing.ingest(ev('You have received a transfer of KD 20.000 to your account XXXX9012 from SARA M.', t0, sender: 'KFH'));
      await ing.ingest(ev('Transfer of KWD 20.000 from your account XXXX5678 to account XXXX3333 was successful', t0.add(const Duration(minutes: 5)), sender: 'NBK'));
      final txs = await live(s);
      expect(txs.length, 2);
      expect(txs.where((t) => t.kind == TxKinds.transfer), isEmpty);
      expect(totalsFor(txs, calendarMonth(t0)).incomeIn('KWD'), 20000);
    });

    test('outgoing that references the receiving owned account (evidence) is linked as one internal transfer', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      await ing.ingest(ev('Transfer of KWD 100.000 from your account XXXX5678 to account XXXX9012 was successful', t0, sender: 'NBK'));
      await ing.ingest(ev('You have received a transfer of KD 100.000 to your account XXXX9012', t0.add(const Duration(minutes: 2)), sender: 'KFH'));
      final txs = await live(s);
      expect(txs.length, 1);
      expect(txs.single.kind, TxKinds.transfer);
    });

    test('same amount without evidence is flagged for the user to confirm, not auto-linked', () async {
      final s = await newTestStore(now: t0);
      final ing = IngestionService(s);
      await ing.ingest(ev('Transfer of KWD 50.000 from your account XXXX5678 was successful', t0, sender: 'NBK'));
      await ing.ingest(ev('You have received a transfer of KD 50.000 to your account XXXX9012', t0.add(const Duration(minutes: 2)), sender: 'KFH'));
      final txs = await live(s);
      expect(txs.length, 2);
      expect(txs.where((t) => t.kind == TxKinds.transfer), isEmpty);
      expect(txs.where((t) => t.needsReview).length, 1, reason: 'possible internal transfer → user confirms via "Link as transfer"');
    });
  });
}
