// Two real users against the live backend: explicit sharing, privacy, viewer limits,
// revocation and removal. Skipped unless FILS_E2E_API is set.
import 'dart:convert';
import 'dart:io';

import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/core/time/kuwait_time.dart';
import 'package:fils/data/api/api_client.dart';
import 'package:fils/data/household/household_sharing.dart';
import 'package:fils/data/store.dart';
import 'package:fils/data/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_db.dart';
import 'backend_sync_e2e_test.dart' show MemoryTokenStore;

Future<(ApiClient, FinanceStore, SyncEngine, String)> user(String base) async {
  final api = ApiClient(baseUrl: base, tokens: MemoryTokenStore());
  final auth = await api.demoSession();
  await api.recordConsent('cloud_sync', true, '2026-11-22');
  final store = await newTestStore();
  final engine = SyncEngine(store, ApiSyncTransport(api));
  final uid = (auth['user'] as Map)['id'] as String;
  await engine.bindOwner(uid);
  await store.setSetting(SyncKeys.enabled, 'true');
  return (api, store, engine, uid);
}

List<HouseholdInfo> infos(List<dynamic> raw) =>
    [for (final h in raw.cast<Map>()) HouseholdInfo(h['id'] as String, h['name'] as String, h['my_role'] as String)];

void main() {
  final base = Platform.environment['FILS_E2E_API'];
  test('household: only explicitly shared data is visible; viewer read-only; revoke and removal', () async {
    final (apiA, a, ea, _) = await user(base!);
    final (apiB, b, eb, uidB) = await user(base);

    // A has private data.
    final acct = await a.createAccount(name: 'A secret account', kind: 'bank', currency: 'KWD', maskLast4: '9911', openingBalanceMinor: 500000);
    final privateTx = await a.addTransaction(accountId: acct.id, kind: TxKinds.expense, amountMinor: 77000, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 20), source: 'sms', merchant: 'Private clinic', categoryId: 'health', note: 'private note');
    final sharedTx = await a.addTransaction(accountId: acct.id, kind: TxKinds.expense, amountMinor: 32500, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 21), source: 'sms', merchant: 'Lulu Hypermarket', merchantRaw: 'LULU HYPER 4411 SALMIYA', categoryId: 'groceries', note: 'do not share me');

    // A creates a household and invites B as a viewer.
    final hh = await apiA.createHousehold('Home');
    final inv = await apiA.invite(hh['id'] as String, 'viewer');
    await apiB.joinHousehold(inv['code'] as String);
    final sharingA = HouseholdSharing(a);
    final sharingB = HouseholdSharing(b);
    await sharingA.updateMemberships(infos(await apiA.households()));
    await sharingB.updateMemberships(infos(await apiB.households()));
    final hA = (await sharingA.cachedHouseholds()).single;
    final hB = (await sharingB.cachedHouseholds()).single;
    expect(hA.myRole, 'owner');
    expect(hB.myRole, 'viewer');

    final totalsBefore = totalsFor(await a.allTransactions(), calendarMonth(DateTime.utc(2026, 11, 22)));
    final share = await sharingA.shareTransaction(sharedTx.id, hA, includeNote: false, displayName: 'A');
    // Idempotent
    expect((await sharingA.shareTransaction(sharedTx.id, hA, includeNote: false)).id, share.id);
    // Personal totals unchanged by sharing.
    final totalsAfter = totalsFor(await a.allTransactions(), calendarMonth(DateTime.utc(2026, 11, 22)));
    expect(totalsAfter.spentIn('KWD'), totalsBefore.spentIn('KWD'));

    final ra = await ea.sync();
    expect(ra.error, isNull);
    expect(ra.rejected, 0, reason: (await a.db.select(a.db.outbox).get()).map((o) => o.lastError).join('\n'));

    // B pulls: sees only the shared copy, with no private fields, and nothing in B's ledger.
    final rb = await eb.sync();
    expect(rb.error, isNull);
    final rows = await b.db.select(b.db.sharedRecords).get();
    final txRows = rows.where((r) => r.entity == 'transaction').toList();
    expect(txRows.length, 1);
    final p = jsonDecode(txRows.single.payloadJson) as Map<String, dynamic>;
    expect(p['amount_minor'], 32500);
    expect(p['merchant'], 'Lulu Hypermarket');
    expect(p['note'], isNull);
    final dump = rows.map((r) => r.payloadJson).join();
    for (final secret in ['A secret account', '9911', 'Private clinic', 'private note', 'do not share me', 'LULU HYPER 4411', acct.id, privateTx.id, sharedTx.id]) {
      expect(dump.contains(secret), isFalse, reason: 'leaked "$secret"');
    }
    expect(await b.allTransactions(), isEmpty, reason: 'shared copies must never enter the personal ledger');
    expect(await b.accounts(), isEmpty);

    // Viewer cannot share.
    final bAcct = await b.createAccount(name: 'B', kind: 'bank', currency: 'KWD');
    final bTx = await b.addTransaction(accountId: bAcct.id, kind: TxKinds.expense, amountMinor: 1000, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 21), source: 'manual');
    expect(() => sharingB.shareTransaction(bTx.id, hB, includeNote: false), throwsStateError);

    // Revoke → B's copy disappears.
    await sharingA.revoke(share.id);
    expect((await ea.sync()).error, isNull);
    expect((await eb.sync()).error, isNull);
    final afterRevoke = await (b.db.select(b.db.sharedRecords)..where((r) => r.entity.equals('transaction'))).get();
    expect(afterRevoke.single.deletedAt, isNotNull);

    // Share again (new copy), then remove B from the household → B purges local copies and
    // the server stops returning them.
    await sharingA.shareTransaction(sharedTx.id, hA, includeNote: true, displayName: 'A');
    expect((await ea.sync()).error, isNull);
    await apiA.removeMember(hh['id'] as String, uidB);
    final purged = await sharingB.updateMemberships(infos(await apiB.households()));
    expect(purged, greaterThan(0));
    expect((await eb.sync()).error, isNull);
    expect(await b.db.select(b.db.sharedRecords).get(), isEmpty);
  }, skip: base == null ? 'set FILS_E2E_API' : null, timeout: const Timeout(Duration(minutes: 2)));
}
