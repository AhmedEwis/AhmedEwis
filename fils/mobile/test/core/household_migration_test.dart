import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/core/time/kuwait_time.dart';
import 'package:fils/data/db/database.dart';
import 'package:fils/data/household/household_sharing.dart';
import 'package:fils/data/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

import '../support/test_db.dart';

void main() {
  group('household sharing (offline)', () {
    test('share copies only allowed fields, never touches ledger, idempotent, revocable', () async {
      final s = await newTestStore();
      final a = await s.createAccount(name: 'Private NBK', kind: 'bank', currency: 'KWD', maskLast4: '4410');
      final t = await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 32500, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 21), source: 'sms', merchant: 'Lulu Hypermarket', merchantRaw: 'LULU 4410', categoryId: 'groceries', note: 'secret');
      final before = totalsFor(await s.allTransactions(), calendarMonth(DateTime.utc(2026, 11, 22))).spentIn('KWD');
      final sharing = HouseholdSharing(s);
      const h = HouseholdInfo('11111111-1111-4111-8111-111111111111', 'Home', 'member');
      final sh = await sharing.shareTransaction(t.id, h, includeNote: false, displayName: 'Me');
      expect((await sharing.shareTransaction(t.id, h, includeNote: false)).id, sh.id);
      final p = jsonDecode(sh.payloadJson) as Map<String, dynamic>;
      expect(p.keys.toSet(), {'id', 'account_id', 'kind', 'status', 'amount_minor', 'currency', 'merchant', 'category_id', 'note', 'occurred_at', 'source', 'needs_review', 'splits'});
      expect(p['note'], isNull);
      expect(p['account_id'], isNot(a.id));
      expect(sh.payloadJson.contains('4410'), isFalse);
      expect(sh.payloadJson.contains('Private NBK'), isFalse);
      expect(totalsFor(await s.allTransactions(), calendarMonth(DateTime.utc(2026, 11, 22))).spentIn('KWD'), before);
      expect((await s.allTransactions()).length, 1);
      final outbox = await s.db.select(s.db.outbox).get();
      expect(outbox.map((o) => o.entity), containsAll([SharedEntities.account, SharedEntities.transaction]));
      await sharing.revoke(sh.id);
      expect((await (s.db.select(s.db.sharedRecords)..where((r) => r.id.equals(sh.id))).getSingle()).deletedAt, isNotNull);
    });

    test('viewers cannot share; transfers cannot be shared; memberships purge', () async {
      final s = await newTestStore();
      final a = await s.createAccount(name: 'A', kind: 'bank', currency: 'KWD');
      final b = await s.createAccount(name: 'B', kind: 'bank', currency: 'KWD');
      final e = await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 1000, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 1), source: 'manual');
      final tr = await s.addTransaction(accountId: a.id, counterAccountId: b.id, kind: TxKinds.transfer, amountMinor: 1000, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 1), source: 'manual');
      final sharing = HouseholdSharing(s);
      expect(() => sharing.shareTransaction(e.id, const HouseholdInfo('h', 'H', 'viewer'), includeNote: false), throwsStateError);
      const m = HouseholdInfo('22222222-2222-4222-8222-222222222222', 'H', 'member');
      expect(() => sharing.shareTransaction(tr.id, m, includeNote: false), throwsArgumentError);
      await sharing.shareTransaction(e.id, m, includeNote: false);
      await sharing.updateMemberships([m]);
      expect((await s.db.select(s.db.sharedRecords).get()).length, 2);
      final purged = await sharing.updateMemberships(const []);
      expect(purged, 2);
      expect(await s.db.select(s.db.sharedRecords).get(), isEmpty);
    });
  });

  test('schema migration v1 → v2 preserves data and adds shared_records', () async {
    final dir = await Directory.systemTemp.createTemp('fils_mig');
    final f = File('${dir.path}/m.db');
    var db = AppDatabase(NativeDatabase(f));
    final st = FinanceStore(db);
    await st.ensureSeeded();
    final acct = await st.createAccount(name: 'Kept', kind: 'bank', currency: 'KWD', openingBalanceMinor: 1234);
    await db.close();
    // Simulate a v1 database: drop the v2 table and set user_version = 1.
    final raw = s3.sqlite3.open(f.path)
      ..execute('DROP TABLE shared_records')
      ..execute('PRAGMA user_version = 1');
    raw.dispose();
    db = AppDatabase(NativeDatabase(f));
    final st2 = FinanceStore(db);
    expect((await st2.account(acct.id))!.openingBalanceMinor, 1234);
    expect(await db.select(db.sharedRecords).get(), isEmpty); // table exists again
    final v = await db.customSelect('PRAGMA user_version').getSingle();
    expect(v.data.values.first, 2);
    await db.close();
    await dir.delete(recursive: true);
  });
}
