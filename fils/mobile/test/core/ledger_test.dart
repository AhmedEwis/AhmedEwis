import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/core/time/kuwait_time.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_db.dart';

void main() {
  final cycle = const CycleCalculator(startDay: 1).cycleFor(DateTime.utc(2026, 11, 22));
  final t = DateTime.utc(2026, 11, 10, 10);

  test('I2 internal transfer nets to zero and is not spending/income', () async {
    final s = await newTestStore();
    final a = await s.createAccount(name: 'NBK', kind: 'bank', currency: 'KWD', openingBalanceMinor: 500000, openingBalanceDate: DateTime.utc(2026, 1, 1));
    final b = await s.createAccount(name: 'KFH', kind: 'bank', currency: 'KWD', openingBalanceMinor: 0, openingBalanceDate: DateTime.utc(2026, 1, 1));
    await s.addTransaction(accountId: a.id, counterAccountId: b.id, kind: TxKinds.transfer, amountMinor: 100000, currency: 'KWD', occurredAt: t, source: 'manual');
    final txs = await s.allTransactions();
    expect(calculatedBalance(a, txs) + calculatedBalance(b, txs), 500000);
    expect(calculatedBalance(b, txs), 100000);
    final tot = totalsFor(txs, cycle);
    expect(tot.spentIn('KWD'), 0);
    expect(tot.incomeIn('KWD'), 0);
  });

  test('I3 ATM is bank→cash transfer; fee is spending', () async {
    final s = await newTestStore();
    final bank = await s.createAccount(name: 'Bank', kind: 'bank', currency: 'KWD', openingBalanceMinor: 100000, openingBalanceDate: DateTime.utc(2026, 1, 1));
    final cash = await s.createAccount(name: 'Cash', kind: 'cash', currency: 'KWD', openingBalanceDate: DateTime.utc(2026, 1, 1));
    await s.addTransaction(accountId: bank.id, counterAccountId: cash.id, kind: TxKinds.transfer, amountMinor: 50000, currency: 'KWD', occurredAt: t, source: 'sms');
    await s.addTransaction(accountId: bank.id, kind: TxKinds.expense, amountMinor: 250, currency: 'KWD', occurredAt: t, source: 'sms', categoryId: 'fees');
    final txs = await s.allTransactions();
    expect(calculatedBalance(bank, txs), 100000 - 50000 - 250);
    expect(calculatedBalance(cash, txs), 50000);
    expect(totalsFor(txs, cycle).spentIn('KWD'), 250);
  });

  test('I4 card purchase is expense; repayment is not a second expense', () async {
    final s = await newTestStore();
    final bank = await s.createAccount(name: 'Bank', kind: 'bank', currency: 'KWD', openingBalanceMinor: 1000000, openingBalanceDate: DateTime.utc(2026, 1, 1));
    final card = await s.createAccount(name: 'Visa', kind: 'card', currency: 'KWD', isLiability: true, openingBalanceDate: DateTime.utc(2026, 1, 1));
    await s.addTransaction(accountId: card.id, kind: TxKinds.expense, amountMinor: 60000, currency: 'KWD', occurredAt: t, source: 'sms', categoryId: 'shopping');
    await s.addTransaction(accountId: bank.id, counterAccountId: card.id, kind: TxKinds.transfer, amountMinor: 60000, currency: 'KWD', occurredAt: t.add(const Duration(days: 5)), source: 'sms');
    final txs = await s.allTransactions();
    expect(totalsFor(txs, cycle).spentIn('KWD'), 60000);
    expect(calculatedBalance(card, txs), 0);
    expect(calculatedBalance(bank, txs), 1000000 - 60000);
  });

  test('I5 partial refunds reduce category spend, cannot exceed original', () async {
    final s = await newTestStore();
    final a = await s.createAccount(name: 'Bank', kind: 'bank', currency: 'KWD', openingBalanceDate: DateTime.utc(2026, 1, 1));
    final e = await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 20000, currency: 'KWD', occurredAt: t, source: 'manual', categoryId: 'shopping', merchant: 'X-cite');
    await s.recordRefund(e.id, 5000, at: t.add(const Duration(days: 1)));
    await s.recordRefund(e.id, 5000, at: t.add(const Duration(days: 2)));
    expect(() => s.recordRefund(e.id, 10001), throwsArgumentError);
    final tot = totalsFor(await s.allTransactions(), cycle);
    expect(tot.spentIn('KWD'), 10000);
    expect(tot.byCategory['KWD']!['shopping'], 10000);
    expect(tot.incomeIn('KWD'), 0);
  });

  test('I1 declined, void and deleted have no effect; delete is undoable', () async {
    final s = await newTestStore();
    final a = await s.createAccount(name: 'Bank', kind: 'bank', currency: 'KWD', openingBalanceMinor: 10000, openingBalanceDate: DateTime.utc(2026, 1, 1));
    await s.addTransaction(accountId: a.id, kind: TxKinds.expense, status: TxStatuses.declined, amountMinor: 3000, currency: 'KWD', occurredAt: t, source: 'sms');
    final x = await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 1000, currency: 'KWD', occurredAt: t, source: 'manual');
    await s.deleteTransaction(x.id);
    expect(calculatedBalance(a, await s.allTransactions(includeDeleted: true)), 10000);
    await s.restoreTransaction(x.id);
    expect(calculatedBalance(a, await s.allTransactions()), 9000);
  });

  test('I7 opening balance applied once; history before opening date ignored', () async {
    final s = await newTestStore();
    final a = await s.createAccount(name: 'Bank', kind: 'bank', currency: 'KWD', openingBalanceMinor: 75000, openingBalanceDate: DateTime.utc(2026, 11, 1));
    // An imported historical transaction before the opening date is already reflected.
    await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 5000, currency: 'KWD', occurredAt: DateTime.utc(2026, 10, 15), source: 'csv');
    await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 1000, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 3), source: 'csv');
    expect(calculatedBalance(a, await s.allTransactions()), 74000);
  });

  test('I8 currencies are never summed together', () async {
    final s = await newTestStore();
    final a = await s.createAccount(name: 'KWD', kind: 'bank', currency: 'KWD', openingBalanceDate: DateTime.utc(2026, 1, 1));
    final u = await s.createAccount(name: 'USD', kind: 'bank', currency: 'USD', openingBalanceDate: DateTime.utc(2026, 1, 1));
    await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 5250, currency: 'KWD', occurredAt: t, source: 'manual');
    await s.addTransaction(accountId: u.id, kind: TxKinds.expense, amountMinor: 2500, currency: 'USD', occurredAt: t, source: 'manual');
    final tot = totalsFor(await s.allTransactions(), cycle);
    expect(tot.spent, {'KWD': 5250, 'USD': 2500});
  });

  test('I9 reconciliation adjusts balance but not spending', () async {
    final s = await newTestStore();
    final a = await s.createAccount(name: 'Bank', kind: 'bank', currency: 'KWD', openingBalanceMinor: 10000, openingBalanceDate: DateTime.utc(2026, 1, 1));
    await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 2000, currency: 'KWD', occurredAt: t, source: 'manual');
    final adj = await s.reconcile(a.id, 7500);
    expect(adj!.kind, TxKinds.adjustDown);
    final txs = await s.allTransactions();
    expect(calculatedBalance(a, txs), 7500);
    expect(totalsFor(txs, cycle).spentIn('KWD'), 2000);
    expect(await s.reconcile(a.id, 7500), isNull);
  });

  test('splits must add up and drive category totals', () async {
    final s = await newTestStore();
    final a = await s.createAccount(name: 'Bank', kind: 'bank', currency: 'KWD', openingBalanceDate: DateTime.utc(2026, 1, 1));
    final x = await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 30000, currency: 'KWD', occurredAt: t, source: 'manual', categoryId: 'groceries');
    expect(() => s.replaceSplits(x.id, [(categoryId: 'groceries', amountMinor: 1, note: null)]), throwsArgumentError);
    await s.replaceSplits(x.id, [(categoryId: 'groceries', amountMinor: 20000, note: null), (categoryId: 'health', amountMinor: 10000, note: null)]);
    final tot = totalsFor(await s.allTransactions(), cycle, splitsByTx: await s.allSplits());
    expect(tot.byCategory['KWD'], {'groceries': 20000, 'health': 10000});
  });

  test('net worth skips assets linked to tracked accounts and subtracts liabilities', () async {
    final s = await newTestStore();
    final a = await s.createAccount(name: 'Bank', kind: 'bank', currency: 'KWD', openingBalanceMinor: 100000, openingBalanceDate: DateTime.utc(2026, 1, 1));
    await s.saveAsset(name: 'Same bank deposit', kind: 'deposit', valueMinor: 100000, currency: 'KWD', linkedAccountId: a.id);
    await s.saveAsset(name: 'Gold', kind: 'gold', valueMinor: 500000, currency: 'KWD');
    await s.saveAsset(name: 'Car loan', kind: 'loan', valueMinor: 200000, currency: 'KWD', isLiability: true);
    final nw = netWorth(accounts: await s.accounts(), balances: {a.id: 100000}, assets: await s.db.select(s.db.assets).get());
    expect(nw['KWD'], 100000 + 500000 - 200000);
  });
}
