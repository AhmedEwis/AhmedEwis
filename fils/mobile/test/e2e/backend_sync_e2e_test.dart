// End-to-end: real FastAPI backend + Postgres ↔ the app's ApiClient and SyncEngine.
// Skipped unless FILS_E2E_API is set, e.g.
//   FILS_E2E_API=http://127.0.0.1:8099 flutter test test/e2e
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/data/api/api_client.dart';
import 'package:fils/data/db/database.dart';
import 'package:fils/data/store.dart';
import 'package:fils/data/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_db.dart';

class MemoryTokenStore extends TokenStore {
  final _m = <String, String>{};
  Map<String, dynamic>? _user;
  @override
  Future<String?> access() async => _m['a'];
  @override
  Future<String?> refresh() async => _m['r'];
  @override
  Future<DateTime?> accessExpiry() async => DateTime.tryParse(_m['e'] ?? '');
  @override
  Future<Map<String, dynamic>?> user() async => _user;
  @override
  Future<void> save(Map<String, dynamic> auth) async {
    _m['a'] = auth['access_token'] as String;
    _m['r'] = auth['refresh_token'] as String;
    _m['e'] = auth['access_expires_at'] as String;
    _user = (auth['user'] as Map?)?.cast<String, dynamic>();
  }

  @override
  Future<void> saveUser(Map<String, dynamic> u) async => _user = u;
  @override
  Future<void> clear() async => _m.clear();
  @override
  Future<String> deviceId() async => _m.putIfAbsent('d', () => 'e2e-${DateTime.now().microsecondsSinceEpoch}');
}

void main() {
  final base = Platform.environment['FILS_E2E_API'];
  final skip = base == null ? 'set FILS_E2E_API to run against a live backend' : null;

  test('sign-in (demo), consent gating, sync A→B, conflict, tombstone, provider-not-configured states', () async {
    final tokens = MemoryTokenStore();
    final api = ApiClient(baseUrl: base, tokens: tokens);
    final auth = await api.demoSession();
    expect(auth['access_token'], isNotNull);

    // Sync is refused before consent.
    await expectLater(api.pull(null), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'consent_required')));
    await api.recordConsent('cloud_sync', true, '2026-11-22');

    // Device A with every entity type.
    final a = await newTestStore();
    final ea = SyncEngine(a, ApiSyncTransport(api));
    final userId = (auth['user'] as Map)['id'] as String;
    expect(await ea.bindOwner(userId), isTrue);
    await a.setSetting(SyncKeys.enabled, 'true');
    await a.setSetting(SettingKeys.cycleStartDay, '25');
    final acct = await a.createAccount(name: 'NBK Current', kind: 'bank', currency: 'KWD', institutionId: 'nbk', maskLast4: '4410', openingBalanceMinor: 1000000, color: 0xFF0A3D7A);
    final card = await a.createAccount(name: 'KFH Visa', kind: 'card', currency: 'KWD', isLiability: true, maskLast4: '1234');
    final cat = await a.createCategory(nameEn: 'Diwaniya', nameAr: 'ديوانية', icon: '☕', color: 0xFF0B7A8F);
    final tx = await a.addTransaction(accountId: card.id, kind: TxKinds.expense, amountMinor: 5250, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 20, 10), source: 'sms', merchant: 'Talabat', merchantRaw: 'TALABAT', categoryId: 'food', parserId: 'kw-generic', parserVersion: '1.0.0', confidence: 0.9);
    await a.replaceSplits(tx.id, [(categoryId: 'food', amountMinor: 5000, note: null), (categoryId: cat.id, amountMinor: 250, note: 'tip')]);
    await a.addTransaction(accountId: acct.id, counterAccountId: card.id, kind: TxKinds.transfer, amountMinor: 5250, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 21), source: 'manual');
    await a.saveBudget(categoryId: 'food', amountMinor: 150000, currency: 'KWD');
    final goal = await a.saveGoal(name: 'Car', emoji: '🚗', targetMinor: 8500000, currency: 'KWD', targetDate: DateTime.utc(2028, 1, 1), plannedMonthlyMinor: 250000);
    await a.addContribution(goal.id, 100000);
    await a.saveRecurring(RecurringsCompanion.insert(id: newId(), name: 'Rent', kind: 'rent', amountMinor: 450000, currency: 'KWD', cadence: 'monthly', anchorDate: DateTime.utc(2026, 11, 27), nextDueDate: DateTime.utc(2026, 11, 27), status: 'active', updatedAt: DateTime.utc(2026, 11, 22)));
    await a.saveAsset(name: 'Gold', kind: 'gold', valueMinor: 2180000, currency: 'KWD');
    await a.upsertMerchantAlias(pattern: 'TALABAT', merchant: 'Talabat', categoryId: 'food');
    await a.reconcile(acct.id, 990000);
    await ea.enqueueAll();
    final r1 = await ea.sync();
    expect(r1.error, isNull, reason: '$r1');
    expect(r1.rejected, 0, reason: 'server rejected payloads: ${(await a.db.select(a.db.outbox).get()).map((o) => o.lastError).toList()}');
    expect(r1.pushed, greaterThanOrEqualTo(10));
    expect(await ea.pendingCount(), 0);

    // Device B pulls everything.
    final b = await newTestStore();
    final eb = SyncEngine(b, ApiSyncTransport(api));
    expect(await eb.bindOwner(userId), isTrue);
    await b.setSetting(SyncKeys.enabled, 'true');
    final r2 = await eb.sync();
    expect(r2.error, isNull, reason: '$r2');
    final bt = await b.transaction(tx.id);
    expect(bt, isNotNull);
    expect(bt!.amountMinor, 5250);
    expect((await b.splitsFor(tx.id)).map((s) => s.amountMinor).toSet(), {5000, 250});
    expect((await b.db.select(b.db.goalContributions).get()).single.amountMinor, 100000);
    expect(await b.getSetting(SettingKeys.cycleStartDay), '25');
    final bAcct = await b.account(acct.id);
    expect(bAcct!.color, 0xFF0A3D7A);
    // Balances agree across devices.
    expect(calculatedBalance(bAcct, await b.transactionsForAccount(acct.id)), calculatedBalance((await a.account(acct.id))!, await a.transactionsForAccount(acct.id)));

    // Conflict: both edit the same transaction.
    await a.updateTransaction(tx.id, const TransactionsCompanion(note: Value('edited on A')));
    await b.updateTransaction(tx.id, const TransactionsCompanion(note: Value('edited on B')));
    expect((await ea.sync()).error, isNull);
    final rb = await eb.sync();
    expect(rb.conflicts, greaterThan(0));
    expect((await b.transaction(tx.id))!.note, 'edited on B');
    final c = (await eb.conflicts()).first;
    await eb.resolveConflict(c, keepMine: true);
    final rb2 = await eb.sync();
    expect(rb2.error, isNull);
    expect((await ea.sync()).error, isNull);
    expect((await a.transaction(tx.id))!.note, 'edited on B');

    // Tombstone propagates and can't be resurrected.
    await a.deleteTransaction(tx.id);
    expect((await ea.sync()).error, isNull);
    expect((await eb.sync()).error, isNull);
    expect((await b.transaction(tx.id))!.deletedAt, isNotNull);

    // Voice/AI are consent-gated, then report an explicit "not configured" state.
    await expectLater(api.voiceToken(), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'consent_required')));
    await api.recordConsent('cloud_voice', true, '2026-11-22');
    await api.recordConsent('cloud_ai', true, '2026-11-22');
    await expectLater(api.voiceToken(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 503)));
    final ex = await api.extract('Purchase of KWD 5.250 at TALABAT');
    expect(ex['status'], 'disabled');

    await api.logout();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
