// Held possible duplicates and their resolutions, synced through the live backend:
// held captures never reach the server; "separate" uploads exactly one transaction;
// "same" uploads none; retried resolutions change nothing on either device.
import 'dart:io';

import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/core/parsing/models.dart';
import 'package:fils/core/time/kuwait_time.dart';
import 'package:fils/data/api/api_client.dart';
import 'package:fils/data/db/database.dart' show TxRow;
import 'package:fils/data/ingestion.dart';
import 'package:fils/data/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_db.dart';
import 'backend_sync_e2e_test.dart' show MemoryTokenStore;

void main() {
  final base = Platform.environment['FILS_E2E_API'];
  final t0 = DateTime.utc(2026, 11, 22, 11, 5);
  int spent(List<TxRow> txs) => totalsFor(txs, calendarMonth(t0)).spentIn('KWD');

  Future<String> ambiguous(IngestionService ing, DateTime at, String tag) async {
    await ing.ingest(RawEvent(text: '', receivedAt: at, source: SourceKind.wallet, sourceId: '$tag-a', fields: {'merchant': 'Caribou Coffee', 'amount': 'KWD 1.500'}));
    await ing.ingest(RawEvent(text: '', receivedAt: at.add(const Duration(minutes: 1)), source: SourceKind.wallet, sourceId: '$tag-b', fields: {'merchant': 'Caribou Coffee', 'amount': 'KWD 1.500'}));
    final r = await ing.ingest(RawEvent(text: 'Purchase of KWD 1.500 at CARIBOU COFFEE card ending 1234', receivedAt: at.add(const Duration(minutes: 2)), source: SourceKind.sms, sender: 'NBK', sourceId: '$tag-sms'));
    expect(r.outcome, IngestOutcome.possibleDuplicate);
    return r.sourceEventId;
  }

  test('both resolutions sync once; retries are no-ops', () async {
    final api = ApiClient(baseUrl: base, tokens: MemoryTokenStore());
    final auth = await api.demoSession();
    await api.recordConsent('cloud_sync', true, '2026-11-22');
    final userId = (auth['user'] as Map)['id'] as String;

    final a = await newTestStore(now: t0);
    final ea = SyncEngine(a, ApiSyncTransport(api));
    expect(await ea.bindOwner(userId), isTrue);
    await a.setSetting(SyncKeys.enabled, 'true');
    final ing = IngestionService(a);
    await ea.enqueueAll();
    final heldSeparate = await ambiguous(ing, t0, 's');
    final heldSame = await ambiguous(ing, t0.add(const Duration(hours: 1)), 'm');
    expect(spent(await a.allTransactions()), 6000);

    // Sync while held: the server gets the 4 Wallet purchases only.
    expect((await ea.sync()).error, isNull);
    final b = await newTestStore(now: t0);
    final eb = SyncEngine(b, ApiSyncTransport(api));
    expect(await eb.bindOwner(userId), isTrue);
    await b.setSetting(SyncKeys.enabled, 'true');
    expect((await eb.sync()).error, isNull);
    expect(spent(await b.allTransactions()), 6000);
    expect((await b.allTransactions()).length, 4);

    // Resolve on device A.
    await ing.confirmSeparate(heldSeparate);
    final cands = (await (a.db.select(a.db.sourceEvents)..where((x) => x.id.equals(heldSame))).getSingle()).matchCandidates!.split(',');
    await ing.confirmSameTransaction(heldSame, cands.first);
    expect(spent(await a.allTransactions()), 7500);
    expect((await ea.sync()).error, isNull);
    expect((await eb.sync()).error, isNull);
    expect(spent(await b.allTransactions()), 7500);
    expect((await b.allTransactions()).length, 5);

    // Retries (double tap, or after a restart) change nothing, locally or remotely.
    await ing.confirmSeparate(heldSeparate);
    await ing.confirmSeparate(heldSame);
    await ing.confirmSameTransaction(heldSeparate, cands.first);
    expect((await ea.sync()).error, isNull);
    expect((await eb.sync()).error, isNull);
    expect(spent(await a.allTransactions()), 7500);
    expect(spent(await b.allTransactions()), 7500);
    expect((await b.allTransactions()).length, 5);
  }, skip: base == null ? 'set FILS_E2E_API to run against a live backend' : null);
}
