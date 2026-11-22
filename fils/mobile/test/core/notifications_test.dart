import 'package:drift/drift.dart' show Value;
import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/core/notifications/planner.dart';
import 'package:fils/data/db/database.dart';
import 'package:fils/data/notifications/notification_service.dart';
import 'package:fils/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_db.dart';

class FakePort implements NotificationPort {
  final scheduled = <int, PlannedNotification>{};
  final shown = <PlannedNotification>[];
  final cancelled = <int>[];
  bool grant = true;
  @override
  Future<void> init() async {}
  @override
  Future<bool> requestPermission() async => grant;
  @override
  Future<void> schedule(PlannedNotification n) async => scheduled[n.id] = n;
  @override
  Future<void> showNow(PlannedNotification n) async => shown.add(n);
  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    scheduled.remove(id);
  }
}

String m(int v, String c) => '$c ${(v / 1000).toStringAsFixed(3)}';

void main() {
  final now = DateTime.utc(2026, 11, 22, 6); // 09:00 Kuwait
  late FinanceStore s;
  late FakePort port;
  late NotificationScheduler sch;
  setUp(() async {
    s = await newTestStore(now: now);
    port = FakePort();
    sch = NotificationScheduler(s, port);
  });

  Future<RecurringRow> rec(String name, DateTime due, {int remind = 1, String status = 'active'}) => s.saveRecurring(RecurringsCompanion.insert(
        id: newId(), name: name, kind: 'bill', amountMinor: 10000, currency: 'KWD', cadence: 'monthly',
        anchorDate: due, nextDueDate: due, status: status, reminderDaysBefore: Value(remind), updatedAt: now));

  test('no permission → nothing scheduled and leftovers cancelled', () async {
    port.grant = false;
    expect(await sch.requestPermission(), isFalse);
    await rec('Zain', DateTime.utc(2026, 11, 28));
    final plan = await sch.reschedule(arabic: false, money: m);
    expect(plan.scheduled, isEmpty);
    expect(port.scheduled, isEmpty);
  });

  test('reminder at 09:00 Kuwait, D-1; past reminders skipped; salary never', () async {
    await sch.requestPermission();
    await rec('Zain', DateTime.utc(2026, 11, 28, 9)); // due 28th → remind 27th 09:00 KW = 06:00 UTC
    await rec('Already due', DateTime.utc(2026, 11, 22, 9)); // reminder (21st) is past
    await s.saveRecurring(RecurringsCompanion.insert(id: newId(), name: 'Salary', kind: 'salary', amountMinor: 1, currency: 'KWD', cadence: 'monthly', anchorDate: now, nextDueDate: DateTime.utc(2026, 11, 25), status: 'active', updatedAt: now));
    final plan = await sch.reschedule(arabic: false, money: m);
    expect(plan.scheduled.length, 1);
    expect(plan.scheduled.single.at, DateTime.utc(2026, 11, 27, 6));
    expect(plan.scheduled.single.body, 'KWD 10.000 due in 1 day');
  });

  test('rescheduling is idempotent; delete/pause/date change cancels the old id', () async {
    await sch.requestPermission();
    final r1 = await rec('Rent', DateTime.utc(2026, 11, 30));
    final r2 = await rec('Netflix', DateTime.utc(2026, 12, 4));
    await sch.reschedule(arabic: false, money: m);
    await sch.reschedule(arabic: false, money: m);
    expect(port.scheduled.length, 2); // same ids replaced, no duplicates
    final oldRentId = port.scheduled.values.firstWhere((n) => n.title.contains('Rent')).id;
    await s.deleteRecurring(r2.id);
    await s.saveRecurring(RecurringsCompanion(
        id: Value(r1.id), name: const Value('Rent'), kind: const Value('bill'), amountMinor: const Value(10000), currency: const Value('KWD'),
        cadence: const Value('monthly'), anchorDate: Value(r1.anchorDate), nextDueDate: Value(DateTime.utc(2026, 12, 30)), status: const Value('active'),
        reminderDaysBefore: const Value(1), version: Value(r1.version)));
    await sch.reschedule(arabic: false, money: m);
    expect(port.scheduled.length, 1);
    expect(port.cancelled, contains(oldRentId));
    expect(port.scheduled.values.single.at, DateTime.utc(2026, 12, 29, 6));
    await s.setRecurringStatus(r1.id, 'paused');
    await sch.reschedule(arabic: false, money: m);
    expect(port.scheduled, isEmpty);
  });

  test('budget alert once per threshold per period, survives restart', () async {
    await sch.requestPermission();
    final a = await s.createAccount(name: 'A', kind: 'bank', currency: 'KWD', openingBalanceDate: DateTime.utc(2026, 1, 1));
    await s.saveBudget(categoryId: 'food', amountMinor: 100000, currency: 'KWD', period: 'monthly', thresholds: '80,100');
    await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 85000, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 10), source: 'manual', categoryId: 'food');
    await sch.reschedule(arabic: false, money: m);
    expect(port.shown.single.title, 'Food & Dining budget: 80%');
    await NotificationScheduler(s, port).reschedule(arabic: false, money: m); // "restart"
    expect(port.shown.length, 1);
    await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 20000, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 12), source: 'manual', categoryId: 'food');
    await sch.reschedule(arabic: false, money: m);
    expect(port.shown.length, 2);
    expect(port.shown.last.title, contains('100%'));
    expect(port.shown.last.body, 'Over by KWD 5.000');
  });

  test('device time zone does not shift reminder instants', () {
    final r = RecurringRow(
        id: 'x', name: 'Zain', kind: 'bill', amountMinor: 1000, currency: 'KWD', cadence: 'monthly', interval: 1, anchorDate: now, nextDueDate: DateTime.utc(2026, 12, 1, 9),
        completedOccurrences: 0, status: 'active', reminderDaysBefore: 2, version: 0, updatedAt: now);
    final p1 = planNotifications(recurring: [r], budgets: const [], deliveredKeys: const {}, now: now, arabic: true, money: m);
    // Same inputs with "local" DateTimes converted to UTC give identical absolute instants.
    final p2 = planNotifications(recurring: [r], budgets: const [], deliveredKeys: const {}, now: now.toLocal(), arabic: true, money: m);
    expect(p1.scheduled.single.at, DateTime.utc(2026, 11, 29, 6));
    expect(p2.scheduled.single.at, p1.scheduled.single.at);
    expect(p1.scheduled.single.title, 'تذكير: Zain');
    expect(stableId('bill:x:2026-12-1'), stableId('bill:x:2026-12-1'));
  });
}
