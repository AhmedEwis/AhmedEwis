/// Deterministic, typed assistant tools. Every number in an assistant answer comes from
/// these functions, never from the language model. Tools operate on an in-memory
/// snapshot of the current user's local data only (per-user authorization: there is no
/// way to address another user's data from the device).
library;

import '../../data/db/database.dart';
import '../analytics/recurrence.dart';
import '../ledger/ledger.dart';
import '../parsing/merchant_directory.dart';
import '../time/kuwait_time.dart';

class FinanceSnapshot {
  final List<TxRow> txs;
  final List<AccountRow> accounts;
  final Map<String, int> balances;
  final List<RecurringRow> recurring;
  final List<GoalRow> goals;
  final List<GoalContributionRow> contributions;
  final Map<String, CategoryRow> categories;
  final Map<String, List<SplitRow>> splits;
  final String baseCurrency;
  final int cycleStartDay;
  final DateTime now;
  const FinanceSnapshot({
    required this.txs,
    required this.accounts,
    required this.balances,
    required this.recurring,
    required this.goals,
    required this.contributions,
    required this.categories,
    required this.splits,
    required this.baseCurrency,
    required this.cycleStartDay,
    required this.now,
  });

  CycleCalculator get cycle => CycleCalculator(startDay: cycleStartDay);
}

/// JSON-schema tool definitions sent to the LLM (names + parameters only; no data).
const assistantToolSchemas = <Map<String, Object>>[
  {
    'name': 'spending_summary',
    'description': 'Total spending (expenses minus refunds, excluding transfers) and top categories for a period, optionally for one category or merchant.',
    'parameters': {
      'type': 'object',
      'properties': {
        'period': {'type': 'string', 'enum': ['this_cycle', 'last_cycle', 'this_month', 'last_month', 'today', 'this_week', 'last_7_days', 'last_30_days', 'this_year']},
        'category_id': {'type': 'string', 'description': 'Optional category id such as food, groceries, fuel'},
        'merchant': {'type': 'string', 'description': 'Optional merchant name such as Talabat'},
      },
      'required': ['period'],
    },
  },
  {
    'name': 'left_until_payday',
    'description': 'Spendable balance minus confirmed recurring payments due before the next salary day, with days remaining.',
    'parameters': {'type': 'object', 'properties': {}},
  },
  {
    'name': 'recurring_list',
    'description': 'Confirmed recurring commitments (subscriptions, rent, installments, bills) and detected suggestions.',
    'parameters': {'type': 'object', 'properties': {}},
  },
  {
    'name': 'compare_periods',
    'description': 'Compare spending between the current and the previous period, by category, to explain changes.',
    'parameters': {
      'type': 'object',
      'properties': {'period': {'type': 'string', 'enum': ['cycle', 'month']}},
      'required': ['period'],
    },
  },
  {
    'name': 'goal_projection',
    'description': 'Months needed to reach a savings goal at a given monthly saving amount (no investment returns assumed).',
    'parameters': {
      'type': 'object',
      'properties': {
        'goal_name': {'type': 'string'},
        'monthly_amount_minor': {'type': 'integer', 'description': 'Monthly saving in minor units (fils for KWD)'},
      },
    },
  },
  {
    'name': 'account_balances',
    'description': 'Calculated balances of the user accounts (not live bank balances) and last bank-reported balances.',
    'parameters': {'type': 'object', 'properties': {}},
  },
];

class ToolResult {
  final String tool;
  final Map<String, Object?> data; // what the LLM is allowed to see
  const ToolResult(this.tool, this.data);
}

Period resolvePeriod(String key, FinanceSnapshot s) {
  final z = ReportingZone.kuwait;
  final now = s.now;
  final today = z.startOfDay(now);
  switch (key) {
    case 'last_cycle':
      return s.cycle.previous(s.cycle.cycleFor(now));
    case 'this_month':
      return calendarMonth(now);
    case 'last_month':
      return calendarMonth(calendarMonth(now).start.subtract(const Duration(seconds: 1)));
    case 'today':
      return Period(today, today.add(const Duration(days: 1)));
    case 'this_week':
      // Week starts Sunday in Kuwait.
      final wd = z.toWall(now).weekday % 7; // Sunday → 0
      final start = today.subtract(Duration(days: wd));
      return Period(start, start.add(const Duration(days: 7)));
    case 'last_7_days':
      return Period(today.subtract(const Duration(days: 6)), today.add(const Duration(days: 1)));
    case 'last_30_days':
      return Period(today.subtract(const Duration(days: 29)), today.add(const Duration(days: 1)));
    case 'this_year':
      final w = z.toWall(now);
      return Period(z.fromWall(w.year, 1, 1), z.fromWall(w.year + 1, 1, 1));
    default:
      return s.cycle.cycleFor(now);
  }
}

Map<String, Object?> _periodJson(Period p) {
  final z = ReportingZone.kuwait;
  String d(DateTime t) {
    final w = z.toWall(t);
    return '${w.year}-${w.month.toString().padLeft(2, '0')}-${w.day.toString().padLeft(2, '0')}';
  }

  return {'start': d(p.start), 'end_exclusive': d(p.end)};
}

ToolResult runTool(String name, Map<String, Object?> args, FinanceSnapshot s) {
  switch (name) {
    case 'spending_summary':
      return spendingSummary(s, (args['period'] as String?) ?? 'this_cycle', categoryId: args['category_id'] as String?, merchant: args['merchant'] as String?);
    case 'left_until_payday':
      return leftUntilPayday(s);
    case 'recurring_list':
      return recurringList(s);
    case 'compare_periods':
      return comparePeriods(s, (args['period'] as String?) ?? 'cycle');
    case 'goal_projection':
      return goalProjection(s, goalName: args['goal_name'] as String?, monthlyMinor: (args['monthly_amount_minor'] as num?)?.toInt());
    case 'account_balances':
      return accountBalances(s);
    default:
      return ToolResult(name, {'error': 'unknown_tool'});
  }
}

ToolResult spendingSummary(FinanceSnapshot s, String periodKey, {String? categoryId, String? merchant}) {
  final p = resolvePeriod(periodKey, s);
  Iterable<TxRow> txs = s.txs;
  String? merchantName;
  if (merchant != null && merchant.trim().isNotEmpty) {
    final m = matchMerchant(merchant);
    merchantName = m?.name ?? merchant;
    final key = merchant.toLowerCase();
    txs = txs.where((t) {
      final mm = (t.merchant ?? '').toLowerCase();
      final raw = (t.merchantRaw ?? '').toLowerCase();
      return mm == merchantName!.toLowerCase() || mm.contains(key) || raw.contains(key);
    });
  }
  final totals = totalsFor(txs, p, splitsByTx: s.splits);
  final cur = s.baseCurrency;
  final byCat = (totals.byCategory[cur] ?? const {}).entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
  final spent = categoryId != null ? (totals.byCategory[cur]?[categoryId] ?? 0) : totals.spentIn(cur);
  final count = txs.where((t) => isEffective(t) && p.contains(t.occurredAt) && t.kind == TxKinds.expense && (categoryId == null || t.categoryId == categoryId)).length;
  return ToolResult('spending_summary', {
    'period': _periodJson(p),
    'period_key': periodKey,
    'currency': cur,
    'spent_minor': spent,
    'transaction_count': count,
    'category_id': categoryId,
    'merchant': merchantName,
    'accounts_included': 'all',
    'top_categories': [
      for (final e in byCat.take(8))
        {'category_id': e.key, 'name_en': s.categories[e.key]?.nameEn, 'name_ar': s.categories[e.key]?.nameAr, 'spent_minor': e.value, 'share': totals.spentIn(cur) == 0 ? 0 : (e.value / totals.spentIn(cur))},
    ],
    'other_currencies': {for (final e in totals.spent.entries) if (e.key != cur && e.value != 0) e.key: e.value},
    'excluded': 'transfers between own accounts, reconciliation adjustments, declined and voided transactions',
  });
}

ToolResult leftUntilPayday(FinanceSnapshot s) {
  final cur = s.baseCurrency;
  final cycle = s.cycle.cycleFor(s.now);
  final spendable = s.accounts
      .where((a) => !a.isLiability && !a.archived && a.currency == cur && (a.kind == 'bank' || a.kind == 'cash' || a.kind == 'wallet'))
      .fold<int>(0, (x, a) => x + (s.balances[a.id] ?? 0));
  final due = s.recurring.where((r) => r.status == 'active' && r.kind != 'salary' && r.currency == cur && r.nextDueDate.isBefore(cycle.end) && !r.nextDueDate.isBefore(s.now.subtract(const Duration(days: 1)))).toList();
  final dueTotal = due.fold<int>(0, (x, r) => x + r.amountMinor);
  final days = s.cycle.daysUntilNext(s.now);
  final available = spendable - dueTotal;
  return ToolResult('left_until_payday', {
    'currency': cur,
    'spendable_balance_minor': spendable,
    'confirmed_due_before_payday_minor': dueTotal,
    'due_items': [for (final r in due) {'name': r.name, 'amount_minor': r.amountMinor}],
    'available_minor': available,
    'days_until_payday': days,
    'per_day_minor': days > 0 ? available ~/ days : available,
    'next_payday': _periodJson(cycle)['end_exclusive'],
    'assumptions': 'Calculated balances from captured transactions (not live bank balances); bank, cash and e-wallet accounts in $cur; only confirmed recurring items are subtracted.',
  });
}

ToolResult recurringList(FinanceSnapshot s) {
  final active = s.recurring.where((r) => r.status == 'active').toList();
  final tracked = s.recurring.map((r) => (r.merchantPattern ?? r.name).toLowerCase()).toSet();
  final suggestions = detectRecurring(s.txs, alreadyTracked: tracked, now: s.now);
  final perMonth = active.where((r) => r.currency == s.baseCurrency && r.kind != 'salary').fold<int>(0, (x, r) => x + monthlyEquivalent(r));
  return ToolResult('recurring_list', {
    'currency': s.baseCurrency,
    'monthly_total_minor': perMonth,
    'active': [
      for (final r in active) {'name': r.name, 'kind': r.kind, 'amount_minor': r.amountMinor, 'currency': r.currency, 'cadence': r.cadence, 'next_due': _periodJson(Period(r.nextDueDate, r.nextDueDate))['start']},
    ],
    'suggested_unconfirmed': [
      for (final g in suggestions.take(5)) {'merchant': g.merchant, 'typical_amount_minor': g.typicalAmountMinor, 'cadence': g.cadence, 'occurrences': g.occurrences},
    ],
  });
}

ToolResult comparePeriods(FinanceSnapshot s, String kind) {
  final cur = s.baseCurrency;
  final p1 = kind == 'month' ? calendarMonth(s.now) : s.cycle.cycleFor(s.now);
  final p0 = kind == 'month' ? calendarMonth(p1.start.subtract(const Duration(seconds: 1))) : s.cycle.previous(p1);
  final now = totalsFor(s.txs, p1, splitsByTx: s.splits);
  final prev = totalsFor(s.txs, p0, splitsByTx: s.splits);
  // Compare like-for-like: the same number of elapsed days in the previous period.
  final elapsed = s.now.difference(p1.start);
  final prevSameSpan = totalsFor(s.txs, Period(p0.start, p0.start.add(elapsed)), splitsByTx: s.splits);
  final cats = <String>{...?now.byCategory[cur]?.keys, ...?prev.byCategory[cur]?.keys};
  final deltas = [
    for (final c in cats)
      {
        'category_id': c,
        'name_en': s.categories[c]?.nameEn,
        'name_ar': s.categories[c]?.nameAr,
        'current_minor': now.byCategory[cur]?[c] ?? 0,
        'previous_same_span_minor': prevSameSpan.byCategory[cur]?[c] ?? 0,
        'delta_minor': (now.byCategory[cur]?[c] ?? 0) - (prevSameSpan.byCategory[cur]?[c] ?? 0),
      }
  ]..sort((a, b) => (b['delta_minor'] as int).compareTo(a['delta_minor'] as int));
  return ToolResult('compare_periods', {
    'currency': cur,
    'current_period': _periodJson(p1),
    'previous_period': _periodJson(p0),
    'elapsed_days': elapsed.inDays,
    'current_spent_minor': now.spentIn(cur),
    'previous_same_span_spent_minor': prevSameSpan.spentIn(cur),
    'previous_full_spent_minor': prev.spentIn(cur),
    'category_changes': deltas.take(6).toList(),
  });
}

ToolResult goalProjection(FinanceSnapshot s, {String? goalName, int? monthlyMinor}) {
  GoalRow? g;
  if (goalName != null) {
    final k = goalName.toLowerCase();
    g = s.goals.where((x) => x.name.toLowerCase().contains(k)).firstOrNull;
  }
  g ??= s.goals.isEmpty ? null : s.goals.first;
  if (g == null) return const ToolResult('goal_projection', {'error': 'no_goals'});
  final pr = projectGoal(g, s.contributions, s.now);
  final monthly = monthlyMinor ?? g.plannedMonthlyMinor;
  int? months;
  if (monthly != null && monthly > 0) months = pr.remaining == 0 ? 0 : (pr.remaining + monthly - 1) ~/ monthly;
  final reach = months == null ? null : DateTime.utc(s.now.year, s.now.month + months, 1);
  return ToolResult('goal_projection', {
    'goal': g.name,
    'currency': g.currency,
    'target_minor': g.targetMinor,
    'saved_minor': pr.saved,
    'remaining_minor': pr.remaining,
    'monthly_minor': monthly,
    'months_needed': months,
    'estimated_month': reach == null ? null : '${reach.year}-${reach.month.toString().padLeft(2, '0')}',
    'needed_per_month_for_target_date_minor': pr.neededPerMonthForDate,
    'assumptions': 'Constant monthly saving, no investment returns, no withdrawals.',
  });
}

ToolResult accountBalances(FinanceSnapshot s) => ToolResult('account_balances', {
      'note': 'Calculated balances from captured transactions; not live bank balances.',
      'accounts': [
        for (final a in s.accounts.where((a) => !a.archived))
          {
            'name': a.name,
            'kind': a.kind,
            'currency': a.currency,
            'calculated_balance_minor': s.balances[a.id] ?? 0,
            'bank_reported_balance_minor': a.reportedBalanceMinor,
            'bank_reported_at': a.reportedBalanceAt?.toIso8601String(),
          }
      ],
    });
