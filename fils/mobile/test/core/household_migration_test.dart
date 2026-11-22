import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show OrderingTerm;
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
    expect(v.data.values.first, 3);
    await db.close();
    await dir.delete(recursive: true);
  });

  test('schema migration v2 → v3: duplicate platform ids are kept but renamed, then the unique index is enforced', () async {
    final dir = await Directory.systemTemp.createTemp('fils_mig3');
    final f = File('${dir.path}/m.db');
    var db = AppDatabase(NativeDatabase(f));
    final st = FinanceStore(db);
    await st.ensureSeeded();
    final acct = await st.createAccount(name: 'Kept', kind: 'bank', currency: 'KWD');
    final tx = await st.addTransaction(accountId: acct.id, kind: TxKinds.expense, amountMinor: 5250, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 1), source: 'shortcut');
    await db.close();
    // Simulate a v2 database written by a build without the index: two rows share
    // (shortcut, run-1), one of them referenced by a transaction.
    final raw = s3.sqlite3.open(f.path)
      ..execute('DROP INDEX idx_src_platform')
      ..execute('ALTER TABLE source_events DROP COLUMN counter_last4');
    for (final (id, txId) in [('e1', tx.id), ('e2', null)]) {
      raw.execute(
          "INSERT INTO source_events (id, source, platform_id, text_hash, received_at, status, transaction_id, created_at) VALUES (?, 'shortcut', 'run-1', 'h', 0, 'posted', ?, 0)",
          [id, txId]);
    }
    raw.execute('PRAGMA user_version = 2');
    raw.dispose();

    db = AppDatabase(NativeDatabase(f));
    final rows = await (db.select(db.sourceEvents)..orderBy([(r) => OrderingTerm(expression: r.id)])).get();
    expect(rows.length, 2, reason: 'no audit rows deleted');
    expect(rows[0].platformId, 'run-1');
    expect(rows[0].transactionId, tx.id);
    expect(rows[1].platformId, 'run-1#dup-e2');
    final idx = await db.customSelect("SELECT sql FROM sqlite_master WHERE name='idx_src_platform'").getSingle();
    expect(idx.data['sql'] as String, contains('UNIQUE'));
    await expectLater(
        db.customStatement("INSERT INTO source_events (id, source, platform_id, text_hash, received_at, status, created_at) VALUES ('e3', 'shortcut', 'run-1', 'h', 0, 'x', 0)"),
        throwsA(anything));
    expect((await FinanceStore(db).transaction(tx.id))!.amountMinor, 5250);
    expect((await db.customSelect('PRAGMA user_version').getSingle()).data.values.first, 3);
    await db.close();
    await dir.delete(recursive: true);
  });
}
