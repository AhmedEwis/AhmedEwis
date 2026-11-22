/// Recurring-commitment detection and scheduling helpers.
///
/// Detection only *suggests*. Nothing is posted as a transaction, so a predicted
/// payment can never be double-counted against the real one when it arrives.
library;

import '../../data/db/database.dart';
import '../ledger/ledger.dart';

class RecurrenceSuggestion {
  final String merchant;
  final int typicalAmountMinor;
  final String currency;
  final String cadence; // monthly|weekly|yearly
  final DateTime lastDate;
  final DateTime nextDate;
  final int occurrences;
  final String? categoryId;
  final String? accountId;
  const RecurrenceSuggestion(this.merchant, this.typicalAmountMinor, this.currency, this.cadence, this.lastDate, this.nextDate, this.occurrences, this.categoryId, this.accountId);
}

DateTime addCadence(DateTime d, String cadence, int interval) {
  switch (cadence) {
    case 'weekly':
      return d.add(Duration(days: 7 * interval));
    case 'yearly':
      return DateTime.utc(d.year + interval, d.month, d.day.clamp(1, DateTime.utc(d.year + interval, d.month + 1, 0).day), d.hour, d.minute);
    default:
      final m = d.month + interval;
      final y = d.year + (m - 1) ~/ 12;
      final mm = (m - 1) % 12 + 1;
      final last = DateTime.utc(y, mm + 1, 0).day;
      return DateTime.utc(y, mm, d.day > last ? last : d.day, d.hour, d.minute);
  }
}

/// Find merchants charged at a regular interval with stable amounts.
/// Requires at least 3 occurrences, intervals within tolerance, and amounts within ±10%
/// of the median. Merchants already tracked (by pattern) are skipped.
List<RecurrenceSuggestion> detectRecurring(List<TxRow> txs, {Set<String> alreadyTracked = const {}, DateTime? now}) {
  final byMerchant = <String, List<TxRow>>{};
  for (final t in txs) {
    if (!isEffective(t) || t.kind != TxKinds.expense || t.status != TxStatuses.posted) continue;
    final m = (t.merchant ?? '').trim();
    if (m.isEmpty || alreadyTracked.contains(m.toLowerCase())) continue;
    byMerchant.putIfAbsent('$m|${t.currency}', () => []).add(t);
  }
  final out = <RecurrenceSuggestion>[];
  byMerchant.forEach((key, list) {
    if (list.length < 3) return;
    list.sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
    final gaps = <int>[];
    for (var i = 1; i < list.length; i++) {
      gaps.add(list[i].occurredAt.difference(list[i - 1].occurredAt).inDays);
    }
    gaps.sort();
    final medianGap = gaps[gaps.length ~/ 2];
    String? cadence;
    var tol = 0;
    if (medianGap >= 26 && medianGap <= 35) {
      cadence = 'monthly';
      tol = 6;
    } else if (medianGap >= 6 && medianGap <= 8) {
      cadence = 'weekly';
      tol = 2;
    } else if (medianGap >= 355 && medianGap <= 375) {
      cadence = 'yearly';
      tol = 12;
    }
    if (cadence == null) return;
    if (gaps.any((g) => (g - medianGap).abs() > tol)) return;
    final amounts = list.map((t) => t.amountMinor).toList()..sort();
    final median = amounts[amounts.length ~/ 2];
    if (amounts.any((a) => (a - median).abs() > median * 0.1)) return;
    final last = list.last;
    final cutoff = (now ?? DateTime.now().toUtc()).subtract(Duration(days: medianGap * 2));
    if (last.occurredAt.isBefore(cutoff)) return; // stopped recurring
    out.add(RecurrenceSuggestion(
      last.merchant!,
      median,
      last.currency,
      cadence,
      last.occurredAt,
      addCadence(last.occurredAt, cadence, 1),
      list.length,
      last.categoryId,
      last.accountId,
    ));
  });
  out.sort((a, b) => b.typicalAmountMinor.compareTo(a.typicalAmountMinor));
  return out;
}

/// Normalize a recurring amount to a monthly equivalent (for "per month" totals).
int monthlyEquivalent(RecurringRow r) => switch (r.cadence) {
      'weekly' => (r.amountMinor * 52 / 12 / r.interval).round(),
      'yearly' => (r.amountMinor / 12 / r.interval).round(),
      _ => (r.amountMinor / r.interval).round(),
    };

/// Goal projection with explicit assumptions: constant monthly contribution, no returns.
class GoalProjection {
  final int saved;
  final int remaining;
  final int? monthsAtPlannedPace;
  final int? neededPerMonthForDate;
  final int? monthsUntilTarget;
  const GoalProjection(this.saved, this.remaining, this.monthsAtPlannedPace, this.neededPerMonthForDate, this.monthsUntilTarget);
}

GoalProjection projectGoal(GoalRow g, List<GoalContributionRow> contributions, DateTime now) {
  final saved = contributions.where((c) => c.goalId == g.id).fold<int>(0, (s, c) => s + c.amountMinor);
  final remaining = (g.targetMinor - saved).clamp(0, 1 << 62);
  int? monthsAtPace;
  if (g.plannedMonthlyMinor != null && g.plannedMonthlyMinor! > 0) {
    monthsAtPace = remaining == 0 ? 0 : (remaining + g.plannedMonthlyMinor! - 1) ~/ g.plannedMonthlyMinor!;
  }
  int? needed;
  int? monthsLeft;
  if (g.targetDate != null) {
    monthsLeft = (g.targetDate!.year - now.year) * 12 + (g.targetDate!.month - now.month);
    if (g.targetDate!.day < now.day) monthsLeft -= 1;
    if (monthsLeft < 1) monthsLeft = 1;
    needed = remaining == 0 ? 0 : (remaining + monthsLeft - 1) ~/ monthsLeft;
  }
  return GoalProjection(saved, remaining, monthsAtPace, needed, monthsLeft);
}
