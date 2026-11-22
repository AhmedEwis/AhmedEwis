import 'package:drift/drift.dart' show Value;
import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/data/db/database.dart';
import 'package:fils/data/store.dart';
import 'package:fils/data/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_db.dart';

/// In-memory server with the contract's semantics: versions, conflicts, tombstones.
class FakeServer {
  final records = <String, Map<String, dynamic>>{}; // entity:id → envelope
  final log = <Map<String, dynamic>>[]; // change feed
  final seenKeys = <String, Map<String, dynamic>>{};
  bool failNext = false;

  Map<String, dynamic> push(List<Map<String, dynamic>> ops, String key) {
    if (failNext) {
      failNext = false;
      throw Exception('network down');
    }
    if (seenKeys.containsKey(key)) return seenKeys[key]!;
    final results = <Map<String, dynamic>>[];
    for (final op in ops) {
      final k = '${op['entity']}:${op['id']}';
      final cur = records[k];
      final curV = (cur?['version'] as int?) ?? 0;
      if (cur != null && cur['deleted'] == true && op['deleted'] != true) {
        results.add({'id': op['id'], 'entity': op['entity'], 'status': 'rejected', 'error': {'code': 'tombstoned'}});
        continue;
      }
      if (op['base_version'] != curV) {
        results.add({'id': op['id'], 'entity': op['entity'], 'status': 'conflict', 'server_version': curV, 'server_record': cur});
        continue;
      }
      final rec = {...op, 'version': curV + 1};
      records[k] = rec;
      log.add(rec);
      results.add({'id': op['id'], 'entity': op['entity'], 'status': 'applied', 'server_version': curV + 1});
    }
    final res = {'results': results, 'cursor': null};
    seenKeys[key] = res;
    return res;
  }

  Map<String, dynamic> pull(String? cursor) {
    final from = int.tryParse(cursor ?? '0') ?? 0;
    return {'records': log.sublist(from), 'cursor': '${log.length}', 'has_more': false};
  }
}

class FakeTransport implements SyncTransport {
  final FakeServer s;
  FakeTransport(this.s);
  @override
  Future<Map<String, dynamic>> push(List<Map<String, dynamic>> ops, String key) async => s.push(ops, key);
  @override
  Future<Map<String, dynamic>> pull(String? cursor) async => s.pull(cursor);
}

Future<(FinanceStore, SyncEngine)> device(FakeServer server) async {
  final st = await newTestStore();
  final e = SyncEngine(st, FakeTransport(server));
  await st.setSetting(SyncKeys.enabled, 'true');
  return (st, e);
}

void main() {
  test('device A changes reach device B; tombstone not resurrected', () async {
    final server = FakeServer();
    final (a, ea) = await device(server);
    final (b, eb) = await device(server);
    final acct = await a.createAccount(name: 'NBK', kind: 'bank', currency: 'KWD', openingBalanceMinor: 1000);
    final tx = await a.addTransaction(accountId: acct.id, kind: TxKinds.expense, amountMinor: 5250, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 20), source: 'manual', merchant: 'Talabat', categoryId: 'food');
    await a.replaceSplits(tx.id, [(categoryId: 'food', amountMinor: 5000, note: null), (categoryId: 'fees', amountMinor: 250, note: null)]);
    final r1 = await ea.sync();
    expect(r1.error, isNull);
    expect(await ea.pendingCount(), 0);
    final r2 = await eb.sync();
    expect(r2.pulled, greaterThanOrEqualTo(2));
    final bt = await b.transaction(tx.id);
    expect(bt!.amountMinor, 5250);
    expect((await b.splitsFor(tx.id)).length, 2);

    await b.deleteTransaction(tx.id);
    await eb.sync();
    await ea.sync();
    expect((await a.transaction(tx.id))!.deletedAt, isNotNull);

    // A stale device trying to "un-delete" is rejected by the server and stays deleted.
    await a.db.into(a.db.outbox).insert(OutboxCompanion.insert(entity: 'transaction', entityId: tx.id, createdAt: DateTime.utc(2026)));
    await (a.db.update(a.db.transactions)..where((t) => t.id.equals(tx.id))).write(const TransactionsCompanion(deletedAt: Value(null)));
    final r = await ea.sync();
    expect(r.rejected + r.conflicts, greaterThan(0));
    expect(server.records['transaction:${tx.id}']!['deleted'], isTrue);
  });

  test('concurrent edits become a conflict, never a silent overwrite', () async {
    final server = FakeServer();
    final (a, ea) = await device(server);
    final (b, eb) = await device(server);
    final acct = await a.createAccount(name: 'NBK', kind: 'bank', currency: 'KWD');
    final tx = await a.addTransaction(accountId: acct.id, kind: TxKinds.expense, amountMinor: 1000, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 20), source: 'manual');
    await ea.sync();
    await eb.sync();
    await a.updateTransaction(tx.id, const TransactionsCompanion(amountMinor: Value(2000)));
    await b.updateTransaction(tx.id, const TransactionsCompanion(amountMinor: Value(3000)));
    await ea.sync();
    final rb = await eb.sync();
    expect(rb.conflicts, greaterThan(0));
    expect((await b.transaction(tx.id))!.amountMinor, 3000, reason: 'local edit kept until resolved');
    final conflicts = await eb.conflicts();
    expect(conflicts, isNotEmpty);
    await eb.resolveConflict(conflicts.first, keepMine: false);
    expect((await b.transaction(tx.id))!.amountMinor, 2000);
  });

  test('network failure leaves outbox intact; retry is idempotent', () async {
    final server = FakeServer();
    final (a, ea) = await device(server);
    await a.createAccount(name: 'Cash', kind: 'cash', currency: 'KWD');
    server.failNext = true;
    final r = await ea.sync();
    expect(r.error, isNotNull);
    expect(await ea.pendingCount(), greaterThan(0));
    final r2 = await ea.sync();
    expect(r2.error, isNull);
    expect(await ea.pendingCount(), 0);
    expect(server.records.length, greaterThanOrEqualTo(1));
  });

  test('sync is off without consent; owner binding prevents mixing users', () async {
    final server = FakeServer();
    final st = await newTestStore();
    final e = SyncEngine(st, FakeTransport(server));
    await st.createAccount(name: 'Bank', kind: 'bank', currency: 'KWD');
    expect((await e.sync()).error, 'sync_off');
    expect(server.records, isEmpty);
    expect(await e.bindOwner('user-1'), isTrue);
    expect(await e.bindOwner('user-2'), isFalse);
  });
}
