import 'package:fils/core/domain/categories.dart';
import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/core/planner/plan_engine.dart';
import 'package:fils/data/db/database.dart';
import 'package:fils/data/store.dart';

/// "Now" for planner tests: 10 Nov 2026 (cycle starts on the 1st).
final planNow = DateTime.utc(2026, 11, 10, 9);

Future<PlannerInput> plannerInputFrom(FinanceStore s, {DateTime? now}) async => PlannerInput(
      txs: await s.allTransactions(),
      splits: await s.allSplits(),
      recurring: await s.recurring(),
      budgets: await (s.db.select(s.db.budgets)..where((b) => b.deletedAt.isNull())).get(),
      accounts: await s.accounts(),
      baseCurrency: 'KWD',
      cycleStartDay: await s.cycleStartDay(),
      now: now ?? planNow,
    );

/// SYNTHETIC history: three complete cycles (Aug, Sep, Oct 2026) plus 10 days of Nov.
/// Per cycle: salary [salaries], food 180, groceries 120, shopping 90 (Oct: 90 − 20
/// refund), entertainment 60, rent 350, bills 40, and a 200 transfer to someone else
/// (never spending). November so far: food 40, groceries 30.
Future<AccountRow> seedHistory(FinanceStore s, {List<int> salaries = const [1000000, 1000000, 1000000], bool fitness = false}) async {
  final a = await s.createAccount(name: 'NBK Current', kind: 'bank', currency: 'KWD', institutionId: 'nbk', maskLast4: '4410');
  final months = [8, 9, 10];
  for (var i = 0; i < 3; i++) {
    final m = months[i];
    DateTime d(int day) => DateTime.utc(2026, m, day, 10);
    Future<TxRow> ex(int amt, String cat, int day, {String? merchant}) =>
        s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: amt, currency: 'KWD', occurredAt: d(day), source: 'sms', categoryId: cat, merchant: merchant);
    await s.addTransaction(accountId: a.id, kind: TxKinds.income, amountMinor: salaries[i], currency: 'KWD', occurredAt: d(1), source: 'sms', categoryId: Cat.salary);
    await ex(100000, Cat.food, 5, merchant: 'Talabat');
    await ex(80000, Cat.food, 18, merchant: 'Starbucks');
    await ex(120000, Cat.groceries, 7, merchant: 'Lulu');
    final shop = await ex(90000, Cat.shopping, 12, merchant: 'Zara');
    if (m == 10) await s.recordRefund(shop.id, 20000, at: d(20));
    await ex(60000, Cat.entertainment, 14);
    await ex(350000, Cat.housing, 2);
    await ex(40000, Cat.bills, 9);
    if (fitness) await ex(25000, Cat.fitness, 3);
    // Transfer to another person: category transfers, never counted as spending.
    await s.addTransaction(accountId: a.id, kind: TxKinds.transfer, amountMinor: 200000, currency: 'KWD', occurredAt: d(15), source: 'sms');
  }
  await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 40000, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 4, 10), source: 'sms', categoryId: Cat.food);
  await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 30000, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 6, 10), source: 'sms', categoryId: Cat.groceries);
  return a;
}
