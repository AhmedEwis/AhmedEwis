/// Pure notification planning (no plugin calls), so it is fully testable.
///
/// - Recurring/bill reminders: one notification per active commitment, at 09:00 Asia/Kuwait
///   on (next due date − reminder days). Past reminder times are skipped, never fired
///   late in a burst.
/// - Budget alerts: when usage crosses a configured threshold in the current period, notify
///   once per budget, period and threshold. Delivered keys are remembered so restarts and
///   recomputation never repeat them.
/// - IDs are stable 31-bit hashes of a semantic key, so rescheduling replaces rather than
///   duplicates, and anything no longer planned is cancelled.
/// - Times are absolute instants computed in the reporting zone (Asia/Kuwait, UTC+3, no
///   DST), so changing the device time zone doesn't shift them. Plans are recomputed on
///   every app start/resume anyway.
library;

import '../../data/db/database.dart';
import '../time/kuwait_time.dart';

class PlannedNotification {
  final int id;
  final String key;
  final String title;
  final String body;
  final DateTime? at; // UTC; null = show now
  final String channel; // bills | budgets
  const PlannedNotification({required this.id, required this.key, required this.title, required this.body, required this.at, required this.channel});
  @override
  String toString() => 'PlannedNotification($key at=$at)';
}

int stableId(String key) {
  // FNV-1a 32-bit, masked to a positive 31-bit int (Android notification ids are int32).
  var h = 0x811c9dc5;
  for (final c in key.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h & 0x7FFFFFFF;
}

class BudgetStatus {
  final BudgetRow budget;
  final int usedMinor;
  final int limitMinor;
  final DateTime periodStart;
  final String label; // category or "Overall"
  const BudgetStatus(this.budget, this.usedMinor, this.limitMinor, this.periodStart, this.label);
}

typedef MoneyFmt = String Function(int minor, String currency);

class NotificationPlan {
  final List<PlannedNotification> scheduled; // future reminders
  final List<PlannedNotification> immediate; // budget alerts to show now
  const NotificationPlan(this.scheduled, this.immediate);
}

NotificationPlan planNotifications({
  required List<RecurringRow> recurring,
  required List<BudgetStatus> budgets,
  required Set<String> deliveredKeys,
  required DateTime now,
  required bool arabic,
  required MoneyFmt money,
  bool billsEnabled = true,
  bool budgetsEnabled = true,
  ReportingZone zone = ReportingZone.kuwait,
}) {
  final scheduled = <PlannedNotification>[];
  final immediate = <PlannedNotification>[];
  if (billsEnabled) {
    for (final r in recurring) {
      if (r.deletedAt != null || r.status != 'active' || r.kind == 'salary') continue;
      final due = zone.toWall(r.nextDueDate);
      final remindWall = DateTime.utc(due.year, due.month, due.day).subtract(Duration(days: r.reminderDaysBefore));
      final at = zone.fromWall(remindWall.year, remindWall.month, remindWall.day, 9);
      if (!at.isAfter(now)) continue; // never fire late
      final key = 'bill:${r.id}:${due.year}-${due.month}-${due.day}';
      final amount = money(r.amountMinor, r.currency);
      final when = r.reminderDaysBefore == 0
          ? (arabic ? 'اليوم' : 'today')
          : (arabic ? 'بعد ${r.reminderDaysBefore} يوم' : 'in ${r.reminderDaysBefore} day${r.reminderDaysBefore == 1 ? '' : 's'}');
      scheduled.add(PlannedNotification(
        id: stableId(key),
        key: key,
        title: arabic ? 'تذكير: ${r.name}' : 'Reminder: ${r.name}',
        body: arabic ? '$amount مستحق $when' : '$amount due $when',
        at: at,
        channel: 'bills',
      ));
    }
  }
  if (budgetsEnabled) {
    for (final b in budgets) {
      if (b.limitMinor <= 0) continue;
      final pct = b.usedMinor * 100 ~/ b.limitMinor;
      final thresholds = b.budget.alertThresholds.split(',').map(int.tryParse).whereType<int>().toList()..sort();
      final crossed = thresholds.where((t) => pct >= t).toList();
      if (crossed.isEmpty) continue;
      final top = crossed.last;
      final key = 'budget:${b.budget.id}:${b.periodStart.toIso8601String()}:$top';
      // Only the highest crossed threshold, and only once per period.
      final lowerAlready = crossed.any((t) => deliveredKeys.contains('budget:${b.budget.id}:${b.periodStart.toIso8601String()}:$t') && t >= top);
      if (deliveredKeys.contains(key) || lowerAlready) continue;
      final left = b.limitMinor - b.usedMinor;
      immediate.add(PlannedNotification(
        id: stableId(key),
        key: key,
        title: arabic ? 'ميزانية ${b.label}: $top%' : '${b.label} budget: $top%',
        body: left >= 0
            ? (arabic ? 'متبقي ${money(left, b.budget.currency)}' : '${money(left, b.budget.currency)} left')
            : (arabic ? 'تجاوزت بـ ${money(-left, b.budget.currency)}' : 'Over by ${money(-left, b.budget.currency)}'),
        at: null,
        channel: 'budgets',
      ));
    }
  }
  return NotificationPlan(scheduled, immediate);
}

/// What to cancel given the ids scheduled last time and the new plan.
Set<int> idsToCancel(Set<int> previouslyScheduled, NotificationPlan plan) =>
    previouslyScheduled.difference(plan.scheduled.map((p) => p.id).toSet());
