import 'dart:convert';

import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/data/household/household_sharing.dart';
import 'package:fils/data/import_export.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_db.dart';

void main() {
  test('export contains user data; wipe removes everything (incl. shared copies, outbox, consents) and reseeds categories', () async {
    final s = await newTestStore();
    final a = await s.createAccount(name: 'NBK', kind: 'bank', currency: 'KWD');
    final t = await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 5250, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 20), source: 'manual', merchant: 'Talabat', categoryId: 'food');
    await HouseholdSharing(s).shareTransaction(t.id, const HouseholdInfo('33333333-3333-4333-8333-333333333333', 'H', 'owner'), includeNote: false);
    final out = await exportAll(s);
    final j = jsonDecode(out['json']!) as Map<String, dynamic>;
    expect((j['transactions'] as List).length, 1);
    expect(out['csv'], contains('Talabat'));
    await s.wipeAll();
    expect(await s.allTransactions(includeDeleted: true), isEmpty);
    expect(await s.accounts(), isEmpty);
    expect(await s.db.select(s.db.sharedRecords).get(), isEmpty);
    expect(await s.db.select(s.db.outbox).get(), isEmpty);
    expect(await s.db.select(s.db.auditEvents).get(), isEmpty);
    expect(await s.db.select(s.db.localConsents).get(), isEmpty);
    expect((await s.categories()).where((c) => c.isSystem), isNotEmpty);
  });
}
