import 'dart:math';

import 'package:drift/drift.dart' show Value;

import '../../core/parsing/models.dart';
import '../db/database.dart';
import '../ingestion.dart';
import '../store.dart';

/// Clearly labeled SYNTHETIC demo data for review and store screenshots. Transactions go
/// through the real ingestion pipeline (synthetic messages → parser → ledger), so the demo
/// exercises the actual code paths. The UI shows a "Demo data" badge while it is active.
class DemoSeeder {
  final FinanceStore store;
  DemoSeeder(this.store);

  Future<void> seed({DateTime? now}) async {
    final n = now ?? DateTime.now().toUtc();
    final rnd = Random(7);
    await store.setSetting(SettingKeys.demoMode, 'true');
    await store.setSetting(SettingKeys.cycleStartDay, '25');
    await store.setSetting(SettingKeys.onboarded, 'true');
    final opening = n.subtract(const Duration(days: 100));
    final nbk = await store.createAccount(name: 'NBK Current', kind: 'bank', currency: 'KWD', institutionId: 'nbk', maskLast4: '4410', openingBalanceMinor: 2350000, openingBalanceDate: opening, color: 0xFF0A3D7A, isDefault: true);
    await store.createAccount(name: 'KFH Visa', kind: 'card', currency: 'KWD', institutionId: 'kfh', maskLast4: '1234', openingBalanceMinor: 0, openingBalanceDate: opening, isLiability: true, creditLimitMinor: 2000000, color: 0xFF0B7A3E);
    await store.createAccount(name: 'Boubyan Savings', kind: 'savings', currency: 'KWD', institutionId: 'boubyan', maskLast4: '7788', openingBalanceMinor: 5400000, openingBalanceDate: opening, color: 0xFFB0005A);
    await store.createAccount(name: 'Cash', kind: 'cash', currency: 'KWD', openingBalanceMinor: 45000, openingBalanceDate: opening);
    await store.setSetting(SettingKeys.defaultPayerAccount, nbk.id);

    final ing = IngestionService(store);
    final merchants = <(String, int, int)>[
      ('TALABAT', 3500, 9500),
      ('CARIBOU COFFEE', 1250, 2750),
      ('LULU HYPERMARKET', 8000, 32000),
      ('AL RAWDA CO-OP', 5000, 21000),
      ('KNPC STATION 57', 4000, 7000),
      ('STARBUCKS AVENUES', 1500, 3200),
      ('ZAIN KUWAIT', 10000, 10000),
      ('CAREEM', 1800, 4500),
      ('X-CITE', 15000, 89000),
      ('SHAKE SHACK', 3800, 6900),
    ];
    final days = 95;
    for (var d = days; d >= 0; d--) {
      final day = n.subtract(Duration(days: d));
      final count = rnd.nextInt(3);
      for (var i = 0; i < count; i++) {
        final m = merchants[rnd.nextInt(merchants.length)];
        final amt = m.$2 + rnd.nextInt(m.$3 - m.$2 + 1);
        final card = rnd.nextBool() ? '1234' : '4410';
        final sender = card == '1234' ? 'KFH' : 'NBK';
        final kd = '${amt ~/ 1000}.${(amt % 1000).toString().padLeft(3, '0')}';
        final at = DateTime.utc(day.year, day.month, day.day, 6 + rnd.nextInt(14), rnd.nextInt(60));
        await ing.ingest(RawEvent(
          text: 'Purchase of KWD $kd at ${m.$1} using card ending $card',
          sender: sender,
          receivedAt: at,
          source: SourceKind.sms,
          sourceId: 'demo-$d-$i',
        ));
      }
    }
    // Salaries on the 25th, rent, subscriptions, a refund, a card repayment, an ATM withdrawal.
    for (var k = 0; k < 4; k++) {
      final pay = DateTime.utc(n.year, n.month - k, 25, 5);
      if (pay.isAfter(n)) continue;
      await ing.ingest(RawEvent(text: 'Your account XXXX4410 has been credited with KWD 1,850.000 SALARY', sender: 'NBK', receivedAt: pay, source: SourceKind.sms, sourceId: 'demo-sal-$k'));
      final rentDay = pay.add(const Duration(days: 2));
      if (!rentDay.isAfter(n)) {
        await store.addTransaction(accountId: nbk.id, kind: 'expense', amountMinor: 450000, currency: 'KWD', occurredAt: rentDay, source: 'manual', merchant: 'Rent', categoryId: 'housing');
      }
      final netflix = DateTime.utc(n.year, n.month - k, 4, 9);
      if (!netflix.isAfter(n)) {
        await ing.ingest(RawEvent(text: 'Purchase of KWD 3.500 at NETFLIX.COM using card ending 1234', sender: 'KFH', receivedAt: netflix, source: SourceKind.sms, sourceId: 'demo-nf-$k'));
      }
    }
    await ing.ingest(RawEvent(text: 'Cash withdrawal of KWD 40.000 from ATM SALMIYA using card ending 4410', sender: 'NBK', receivedAt: n.subtract(const Duration(days: 6)), source: SourceKind.sms, sourceId: 'demo-atm'));
    await ing.ingest(RawEvent(text: 'Payment of KWD 250.000 received for your credit card ending 1234. Thank you.', sender: 'KFH', receivedAt: n.subtract(const Duration(days: 3)), source: SourceKind.sms, sourceId: 'demo-ccpay'));
    await ing.ingest(RawEvent(text: 'A purchase was made on your card ending 1234 at TALABAT', sender: 'KFH', receivedAt: n.subtract(const Duration(hours: 5)), source: SourceKind.sms, sourceId: 'demo-review'));

    await store.saveBudget(amountMinor: 900000, currency: 'KWD', period: 'cycle');
    await store.saveBudget(categoryId: 'food', amountMinor: 150000, currency: 'KWD', period: 'cycle');
    await store.saveBudget(categoryId: 'groceries', amountMinor: 200000, currency: 'KWD', period: 'cycle');
    final car = await store.saveGoal(name: 'New car', emoji: '🚗', targetMinor: 8500000, currency: 'KWD', targetDate: DateTime.utc(n.year + 2, n.month, 1), plannedMonthlyMinor: 250000);
    await store.addContribution(car.id, 2100000, note: 'Boubyan savings', date: n.subtract(const Duration(days: 60)));
    await store.addContribution(car.id, 250000, date: n.subtract(const Duration(days: 28)));
    final umrah = await store.saveGoal(name: 'Umrah', emoji: '🕋', targetMinor: 1200000, currency: 'KWD', plannedMonthlyMinor: 100000);
    await store.addContribution(umrah.id, 300000, date: n.subtract(const Duration(days: 20)));
    await store.saveRecurring(RecurringsCompanion.insert(
      id: newId(), name: 'Rent', kind: 'rent', amountMinor: 450000, currency: 'KWD', cadence: 'monthly',
      anchorDate: DateTime.utc(n.year, n.month, 27), nextDueDate: DateTime.utc(n.year, n.month, 27).isAfter(n) ? DateTime.utc(n.year, n.month, 27) : DateTime.utc(n.year, n.month + 1, 27),
      status: 'active', categoryId: const Value('housing'), accountId: Value(nbk.id), updatedAt: n,
    ));
    await store.saveRecurring(RecurringsCompanion.insert(
      id: newId(), name: 'iPhone 17 (Tabby)', kind: 'installment', amountMinor: 62500, currency: 'KWD', cadence: 'monthly',
      anchorDate: n.subtract(const Duration(days: 90)), nextDueDate: n.add(const Duration(days: 6)), totalOccurrences: const Value(6), completedOccurrences: const Value(3),
      status: 'active', categoryId: const Value('installments'), updatedAt: n,
    ));
    await store.saveAsset(name: 'Gold 21k (112 g)', kind: 'gold', valueMinor: 2180000, currency: 'KWD', valuationDate: n.subtract(const Duration(days: 10)));
    await store.saveAsset(name: 'Car', kind: 'vehicle', valueMinor: 4200000, currency: 'KWD', valuationDate: n.subtract(const Duration(days: 40)));
    await store.saveAsset(name: 'Car loan', kind: 'loan', isLiability: true, valueMinor: 1650000, currency: 'KWD', valuationDate: n.subtract(const Duration(days: 40)));
  }
}
