import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../core/ledger/ledger.dart';
import '../../core/notifications/planner.dart';
import '../../core/time/kuwait_time.dart';
import '../store.dart';

/// Thin platform port so the reconciliation logic is testable without the plugin.
abstract class NotificationPort {
  Future<void> init();
  Future<bool> requestPermission();
  Future<void> schedule(PlannedNotification n);
  Future<void> showNow(PlannedNotification n);
  Future<void> cancel(int id);
}

class PluginNotificationPort implements NotificationPort {
  final _p = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  @override
  Future<void> init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    await _p.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // Permission is requested explicitly from Settings/onboarding, not at launch.
        iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
      ),
    );
    _ready = true;
  }

  @override
  Future<bool> requestPermission() async {
    await init();
    final android = _p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) return await android.requestNotificationsPermission() ?? false;
    final ios = _p.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) return await ios.requestPermissions(alert: true, badge: false, sound: true) ?? false;
    return false;
  }

  NotificationDetails _details(String channel) => NotificationDetails(
        android: AndroidNotificationDetails(
          channel,
          channel == 'bills' ? 'Bills & recurring' : 'Budget alerts',
          channelDescription: channel == 'bills' ? 'Reminders before bills and recurring payments' : 'Alerts when a budget threshold is crossed',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: const DarwinNotificationDetails(),
      );

  @override
  Future<void> schedule(PlannedNotification n) async {
    await init();
    // Inexact scheduling: needs no SCHEDULE_EXACT_ALARM permission, and a reminder a few
    // minutes late is acceptable.
    await _p.zonedSchedule(
      id: n.id,
      title: n.title,
      body: n.body,
      scheduledDate: tz.TZDateTime.from(n.at!, tz.UTC),
      notificationDetails: _details(n.channel),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  @override
  Future<void> showNow(PlannedNotification n) async {
    await init();
    await _p.show(id: n.id, title: n.title, body: n.body, notificationDetails: _details(n.channel));
  }

  @override
  Future<void> cancel(int id) async {
    await init();
    await _p.cancel(id: id);
  }
}

class NotificationKeys {
  static const scheduledIds = 'notif_scheduled_ids';
  static const delivered = 'notif_delivered_keys';
  static const billsEnabled = 'notif_bills';
  static const budgetsEnabled = 'notif_budgets';
  static const permission = 'notif_permission';
}

/// Reconciles desired notifications with what is scheduled: schedules new or changed
/// ones (same id replaces), cancels ones that are no longer planned (deleted, paused, paid
/// or changed date), and shows budget alerts once.
class NotificationScheduler {
  final FinanceStore store;
  final NotificationPort port;
  NotificationScheduler(this.store, this.port);

  Future<Set<String>> _delivered() async => ((jsonDecode(await store.getSetting(NotificationKeys.delivered) ?? '[]') as List).cast<String>()).toSet();

  Future<NotificationPlan> reschedule({required bool arabic, required MoneyFmt money}) async {
    if (await store.getSetting(NotificationKeys.permission) != 'granted') {
      // Without permission, cancel anything left over and do nothing else.
      final prev = ((jsonDecode(await store.getSetting(NotificationKeys.scheduledIds) ?? '[]') as List).cast<int>()).toSet();
      for (final id in prev) {
        await port.cancel(id);
      }
      await store.setSetting(NotificationKeys.scheduledIds, '[]');
      return const NotificationPlan([], []);
    }
    final now = store.now;
    final recurring = await store.recurring();
    final budgets = await (store.db.select(store.db.budgets)..where((b) => b.deletedAt.isNull())).get();
    final txs = await store.allTransactions();
    final splits = await store.allSplits();
    final cycle = CycleCalculator(startDay: await store.cycleStartDay());
    final cats = {for (final c in await store.categories()) c.id: c};
    final statuses = <BudgetStatus>[];
    for (final b in budgets) {
      final period = b.period == 'monthly' ? calendarMonth(now) : cycle.cycleFor(now);
      if (b.period == 'weekly') continue; // weekly alerts would be noisy; shown in-app only
      final used = budgetUsage(txs, period, b.currency, b.categoryId, splitsByTx: splits);
      final label = b.categoryId == null ? (arabic ? 'الإجمالي' : 'Overall') : (arabic ? cats[b.categoryId]?.nameAr : cats[b.categoryId]?.nameEn) ?? b.categoryId!;
      statuses.add(BudgetStatus(b, used, b.amountMinor, period.start, label));
    }
    final delivered = await _delivered();
    final plan = planNotifications(
      recurring: recurring,
      budgets: statuses,
      deliveredKeys: delivered,
      now: now,
      arabic: arabic,
      money: money,
      billsEnabled: await store.getSetting(NotificationKeys.billsEnabled) != 'false',
      budgetsEnabled: await store.getSetting(NotificationKeys.budgetsEnabled) != 'false',
    );
    final prev = ((jsonDecode(await store.getSetting(NotificationKeys.scheduledIds) ?? '[]') as List).cast<int>()).toSet();
    for (final id in idsToCancel(prev, plan)) {
      await port.cancel(id);
    }
    for (final n in plan.scheduled) {
      await port.schedule(n);
    }
    for (final n in plan.immediate) {
      await port.showNow(n);
      delivered.add(n.key);
    }
    // Keep the delivered set bounded (only the last 200 alert keys matter).
    final trimmed = delivered.toList();
    if (trimmed.length > 200) trimmed.removeRange(0, trimmed.length - 200);
    await store.setSetting(NotificationKeys.delivered, jsonEncode(trimmed));
    await store.setSetting(NotificationKeys.scheduledIds, jsonEncode(plan.scheduled.map((p) => p.id).toList()));
    return plan;
  }

  Future<bool> requestPermission() async {
    final ok = await port.requestPermission();
    await store.setSetting(NotificationKeys.permission, ok ? 'granted' : 'denied');
    return ok;
  }
}
