/// Deterministic planning tools for "My Smart Plan". Every amount is computed here, in
/// integer minor units, on the current user's local data only. The language model never
/// calculates, and its output can't change any figure.
///
/// Rules reused from the ledger (via [totalsFor]): transfers and adjustments never count
/// as spending, refunds offset spending, declined/void rows don't count, pending
/// authorizations do (they're money committed), held captures have no transaction and
/// so never count, and currencies are never mixed.
library;

import '../../data/db/database.dart';
import '../domain/categories.dart';
import '../ledger/ledger.dart';
import '../time/kuwait_time.dart';
import 'plan_models.dart';

/// Inputs for the planner (a read-only snapshot).
class PlannerInput {
  final List<TxRow> txs;
  final Map<String, List<SplitRow>> splits;
  final List<RecurringRow> recurring;
  final List<BudgetRow> budgets;
  final List<AccountRow> accounts;
  final String baseCurrency;
  final int cycleStartDay;
  final DateTime now;
  const PlannerInput({
    required this.txs,
    this.splits = const {},
    this.recurring = const [],
    this.budgets = const [],
    this.accounts = const [],
    required this.baseCurrency,
    this.cycleStartDay = 1,
    required this.now,
  });
}

/// The largest share of a category's expected spending the planner will suggest cutting
/// in one cycle (percent). Categories not listed are fixed (rent, bills, health,
/// education, installments, fees, charity, family, cash): the plan never cuts them.
/// These are assumptions, shown to the user with every suggestion.
const reductionCapPercent = <String, int>{
  Cat.food: 30,
  Cat.shopping: 30,
  Cat.entertainment: 30,
  Cat.travel: 30,
  Cat.subscriptions: 50,
  Cat.personalCare: 25,
  Cat.fitness: 20,
  Cat.other: 20,
  Cat.groceries: 15,
  Cat.fuel: 15,
  Cat.transport: 15,
  Cat.telecom: 10,
};

/// Suggested limits move in steps of 0.500 KWD (500 fils) so they're easy to follow.
const limitStepMinor = 500;
const maxActions = 3;
const historyCycles = 3;

int _ceilDiv(int a, int b) => (a + b - 1) ~/ b;
int _roundDownStep(int v) => v <= 0 ? 0 : (v ~/ limitStepMinor) * limitStepMinor;
int _roundUpStep(int v) => v <= 0 ? 0 : _ceilDiv(v, limitStepMinor) * limitStepMinor;

String _catEn(String id) => systemCategories.where((c) => c.id == id).map((c) => c.en).firstOrNull ?? id;
String _catAr(String id) => systemCategories.where((c) => c.id == id).map((c) => c.ar).firstOrNull ?? id;

class _Facts {
  final String currency;
  final map = <String, Fact>{};
  _Facts(this.currency);
  String add(String id, String en, String ar, int amount, FactSource src, {String basisEn = '', String basisAr = '', String? cat}) {
    map[id] = Fact(id: id, labelEn: en, labelAr: ar, amountMinor: amount, currency: currency, source: src, basisEn: basisEn, basisAr: basisAr, categoryId: cat);
    return id;
  }
}

/// Builds a savings plan. [limitOverrides] are user-edited limits (category → minor);
/// they're clamped to what's possible and kept as actions.
PlanProposal buildPlan(
  PlannerInput input,
  PlanIntent intent, {
  required String proposalId,
  Map<String, int> limitOverrides = const {},
}) {
  final cur = intent.currency ?? input.baseCurrency;
  final f = _Facts(input.baseCurrency);
  final questions = <PlanQuestion>[];
  final limitations = <PlanLimitation>{};
  final cycle = CycleCalculator(startDay: input.cycleStartDay);
  final period = cycle.cycleFor(input.now);
  var periodEnd = period.end;
  for (var i = 1; i < (intent.deadline == DeadlineKind.months ? intent.months : 1); i++) {
    periodEnd = cycle.cycleFor(periodEnd).end;
  }

  PlanProposal result(PlanStatus status, {List<PlanAction> actions = const [], List<PlanAlternative> alts = const [], int covered = 0, Map<String, String?> ids = const {}}) =>
      PlanProposal(
        id: proposalId,
        intent: intent,
        status: status,
        questions: questions,
        facts: Map.unmodifiable(f.map),
        actions: actions,
        alternatives: alts,
        limitations: limitations.toList(),
        currency: input.baseCurrency,
        periodStart: period.start,
        periodEnd: periodEnd,
        targetFactId: ids['target'],
        incomeFactId: ids['income'],
        baselineSpendFactId: ids['baseline_spend'],
        baselineSavingsFactId: ids['baseline_savings'],
        projectedSavingsFactId: ids['projected'],
        gapFactId: ids['gap'],
        coveredCycles: covered,
      );

  // ---- Inputs that must exist before anything can be proposed honestly.
  if (cur != input.baseCurrency) {
    questions.add(PlanQuestion.currencyUnsupported);
    return result(PlanStatus.needsInput);
  }
  if (intent.targetMinor == null || intent.targetMinor! <= 0) questions.add(PlanQuestion.target);
  if (intent.deadline == null) questions.add(PlanQuestion.deadline);

  // ---- Observed history: complete cycles Fils actually covered.
  final effective = input.txs.where(isEffective).toList();
  final firstActivity = effective.isEmpty ? null : effective.map((t) => t.occurredAt).reduce((a, b) => a.isBefore(b) ? a : b);
  final covered = <Period>[];
  var p = cycle.cycleFor(period.start.subtract(const Duration(microseconds: 1)));
  for (var i = 0; i < historyCycles; i++) {
    final hasData = effective.any((t) => t.currency == input.baseCurrency && p.contains(t.occurredAt));
    // A cycle counts only if capture had started by then (a few days' grace) and it has
    // activity: an empty, uncovered cycle is missing data, not zero spending.
    if (hasData && firstActivity != null && !firstActivity.isAfter(p.start.add(const Duration(days: 3)))) covered.add(p);
    p = cycle.cycleFor(p.start.subtract(const Duration(microseconds: 1)));
  }
  final totalsByCycle = [for (final c in covered) totalsFor(input.txs, c, splitsByTx: input.splits)];
  final current = totalsFor(input.txs, period, splitsByTx: input.splits);
  final spentNow = current.byCategory[input.baseCurrency] ?? const <String, int>{};

  // Other currencies are reported, never converted or mixed in.
  final otherCur = <String, int>{};
  for (final t in [current, ...totalsByCycle]) {
    t.spent.forEach((c, v) {
      if (c != input.baseCurrency && v > 0) otherCur[c] = (otherCur[c] ?? 0) + v;
    });
  }
  if (otherCur.isNotEmpty) {
    limitations.add(PlanLimitation.otherCurrencies);
    otherCur.forEach((c, v) => f.map['other_currency:$c'] = Fact(
        id: 'other_currency:$c', labelEn: 'Spending in $c (not included)', labelAr: 'مصروف بعملة $c (غير مشمول)', amountMinor: v, currency: c,
        source: FactSource.observed, basisEn: 'Kept separate: no currency conversion is assumed', basisAr: 'منفصل: لا نفترض أي تحويل عملة'));
  }
  if (effective.any((t) => t.status == TxStatuses.pending && period.contains(t.occurredAt))) limitations.add(PlanLimitation.pendingIncluded);
  final activeAccounts = input.accounts.where((a) => !a.archived && a.currency == input.baseCurrency && a.kind != 'cash');
  final windowStart = covered.isEmpty ? period.start : covered.last.start;
  if (activeAccounts.any((a) => !effective.any((t) => t.accountId == a.id && !t.occurredAt.isBefore(windowStart)))) {
    limitations.add(PlanLimitation.accountsWithoutActivity);
  }

  final n = covered.length;
  final basisEn = n == 0 ? '' : 'Average of $n complete pay cycle${n == 1 ? '' : 's'} captured in Fils';
  final basisAr = n == 0 ? '' : 'متوسط $n ${n == 1 ? 'دورة راتب كاملة' : 'دورات راتب كاملة'} مسجلة في فلس';
  if (n == 0) {
    limitations.add(PlanLimitation.noHistory);
  } else if (n < historyCycles) {
    limitations.add(PlanLimitation.shortHistory);
  }

  // ---- Commitments: active recurring payments in this currency, plus stated ones.
  final commit = <String, int>{};
  for (final r in input.recurring) {
    if (r.status != 'active' || r.currency != input.baseCurrency || r.kind == 'salary') continue;
    final c = r.categoryId ?? Cat.other;
    commit[c] = (commit[c] ?? 0) + r.amountMinor;
  }
  for (final s in intent.commitments) {
    commit[s.categoryId] = (commit[s.categoryId] ?? 0) + s.amountMinor;
  }
  commit.forEach((c, v) => f.add('commit:$c', 'Fixed commitments: ${_catEn(c)}', 'التزامات ثابتة: ${_catAr(c)}', v, FactSource.confirmed,
      basisEn: 'Recurring payments you confirmed', basisAr: 'دفعات متكررة أكدتها', cat: c));

  // ---- Income for the period.
  String? incomeId;
  if (intent.incomeMinor != null) {
    incomeId = f.add('income', 'Expected income', 'الدخل المتوقع', intent.incomeMinor!, FactSource.confirmed, basisEn: 'You told Fils', basisAr: 'أنت أخبرت فلس');
  } else if (n > 0) {
    final incomes = [
      for (var i = 0; i < n; i++)
        input.txs
            .where((t) => isEffective(t) && t.kind == TxKinds.income && t.currency == input.baseCurrency && covered[i].contains(t.occurredAt) && (t.categoryId == Cat.salary || t.categoryId == Cat.otherIncome))
            .fold<int>(0, (a, t) => a + t.amountMinor)
    ];
    if (incomes.any((v) => v == 0)) {
      // A covered cycle with no income isn't proof of zero income: ask.
      questions.add(PlanQuestion.income);
    } else {
      final lo = incomes.reduce((a, b) => a < b ? a : b), hi = incomes.reduce((a, b) => a > b ? a : b);
      if (n > 1 && (hi - lo) * 5 > hi) {
        limitations.add(PlanLimitation.irregularIncome);
        incomeId = f.add('income', 'Expected income (lowest recent cycle)', 'الدخل المتوقع (أقل دورة حديثة)', lo, FactSource.assumption,
            basisEn: 'Your income varied across $n cycles; the lowest is used to stay safe', basisAr: 'دخلك تغيّر عبر $n دورات؛ نستخدم الأقل للأمان');
      } else {
        incomeId = f.add('income', 'Expected income', 'الدخل المتوقع', (incomes.reduce((a, b) => a + b) + n ~/ 2) ~/ n, FactSource.observed,
            basisEn: 'Average salary and other income over $n complete pay cycle${n == 1 ? '' : 's'} captured in Fils', basisAr: 'متوسط الراتب والدخل في $n ${n == 1 ? 'دورة راتب كاملة' : 'دورات راتب كاملة'} مسجلة في فلس');
      }
    }
  } else {
    questions.add(PlanQuestion.income);
  }

  // ---- Expected spending per category for the plan cycle.
  final expected = <String, int>{};
  if (n > 0) {
    final cats = <String>{for (final t in totalsByCycle) ...(t.byCategory[input.baseCurrency]?.keys ?? const <String>[]), ...spentNow.keys, ...commit.keys};
    for (final c in cats) {
      final sum = totalsByCycle.fold<int>(0, (a, t) => a + (t.byCategory[input.baseCurrency]?[c] ?? 0));
      final avg = (sum + n ~/ 2) ~/ n;
      if (avg > 0) f.add('avg:$c', 'Usual spending: ${_catEn(c)}', 'المعتاد: ${_catAr(c)}', avg, FactSource.observed, basisEn: basisEn, basisAr: basisAr, cat: c);
      final spent = spentNow[c] ?? 0;
      f.add('spent:$c', 'Spent so far this cycle: ${_catEn(c)}', 'المصروف حتى الآن هذه الدورة: ${_catAr(c)}', spent, FactSource.observed,
          basisEn: 'Captured since ${_d(period.start)}', basisAr: 'مسجل منذ ${_d(period.start)}', cat: c);
      final e = [avg, spent, commit[c] ?? 0].reduce((a, b) => a > b ? a : b);
      if (e <= 0) continue;
      expected[c] = e;
      f.add('base:$c', 'Expected this cycle: ${_catEn(c)}', 'المتوقع هذه الدورة: ${_catAr(c)}', e, FactSource.observed,
          basisEn: 'The higher of your usual spending, what you already spent, and fixed commitments',
          basisAr: 'الأعلى بين المعتاد، والمصروف فعلاً، والالتزامات الثابتة', cat: c);
    }
  } else if (intent.typicalSpendingMinor != null) {
    final spentTotal = current.spentIn(input.baseCurrency);
    final e = intent.typicalSpendingMinor! > spentTotal ? intent.typicalSpendingMinor! : spentTotal;
    f.add('typical', 'Usual monthly spending', 'المصروف الشهري المعتاد', intent.typicalSpendingMinor!, FactSource.confirmed, basisEn: 'You told Fils', basisAr: 'أنت أخبرت فلس');
    f.add('spent:*', 'Spent so far this cycle', 'المصروف حتى الآن هذه الدورة', spentTotal, FactSource.observed, basisEn: 'Captured since ${_d(period.start)}', basisAr: 'مسجل منذ ${_d(period.start)}');
    expected['*'] = e;
    f.add('base:*', 'Expected this cycle (all spending)', 'المتوقع هذه الدورة (كل المصروف)', e, FactSource.confirmed,
        basisEn: 'Your usual monthly spending, or what you already spent if higher', basisAr: 'مصروفك الشهري المعتاد، أو المصروف فعلاً إن كان أعلى');
  } else {
    questions.add(PlanQuestion.typicalSpending);
  }

  for (final c in intent.protectedCategories) {
    if ((expected[c] ?? 0) == 0) limitations.add(PlanLimitation.protectedWithoutSpending);
  }

  if (questions.isNotEmpty) return result(PlanStatus.needsInput, covered: n, ids: {'income': incomeId});

  // ---- Targets and the gap.
  final months = intent.deadline == DeadlineKind.months ? intent.months : 1;
  final targetId = f.add('target', 'Your savings goal', 'هدف التوفير', intent.targetMinor!, FactSource.confirmed, basisEn: 'You told Fils', basisAr: 'أنت أخبرت فلس');
  final perCycle = _ceilDiv(intent.targetMinor!, months);
  final perCycleId = months == 1
      ? targetId
      : f.add('target_per_cycle', 'Goal per pay cycle', 'الهدف لكل دورة راتب', perCycle, FactSource.confirmed,
          basisEn: 'Your goal spread evenly over $months cycles', basisAr: 'هدفك موزع بالتساوي على $months دورات');
  final income = f.map['income']!.amountMinor;
  final baselineSpend = expected.values.fold<int>(0, (a, b) => a + b);
  final baseSpendId = f.add('baseline_spend', 'Expected spending this cycle', 'المصروف المتوقع هذه الدورة', baselineSpend, FactSource.observed,
      basisEn: 'Sum of expected spending per category', basisAr: 'مجموع المتوقع لكل فئة');
  final baselineSavings = income - baselineSpend;
  final baseSaveId = f.add('baseline_savings', 'Savings if nothing changes', 'التوفير إذا لم يتغير شيء', baselineSavings, FactSource.observed,
      basisEn: 'Expected income minus expected spending', basisAr: 'الدخل المتوقع ناقص المصروف المتوقع');
  final gap = perCycle - baselineSavings;
  final ids = <String, String?>{'target': perCycleId, 'income': incomeId, 'baseline_spend': baseSpendId, 'baseline_savings': baseSaveId};

  if (gap <= 0 && limitOverrides.isEmpty) {
    ids['projected'] = f.add('projected_savings', 'Projected savings', 'التوفير المتوقع', baselineSavings, FactSource.observed,
        basisEn: 'No change needed', basisAr: 'لا حاجة لأي تغيير');
    return result(PlanStatus.onTrack, covered: n, ids: ids);
  }
  ids['gap'] = f.add('gap', 'Still needed', 'المتبقي لتحقيق الهدف', gap > 0 ? gap : 0, FactSource.observed,
      basisEn: 'Goal minus savings if nothing changes', basisAr: 'الهدف ناقص التوفير إذا لم يتغير شيء');

  // ---- Reduction capacity per category.
  final budgetsByCat = <String, BudgetRow>{};
  for (final b in input.budgets) {
    if (b.deletedAt == null && b.currency == input.baseCurrency && b.period == 'cycle') budgetsByCat[b.categoryId ?? '*'] = b;
  }
  int hardFloor(String c) {
    final spent = c == '*' ? current.spentIn(input.baseCurrency) : (spentNow[c] ?? 0);
    final cm = c == '*' ? commit.values.fold<int>(0, (a, b) => a + b) : (commit[c] ?? 0);
    return spent > cm ? spent : cm;
  }

  /// Lowest limit the plan may suggest: never below what's spent or committed, never a
  /// cut beyond the category's cap, and always on the 0.500 step.
  int? minLimit(String c, {bool ignoreProtection = false}) {
    if (!ignoreProtection && intent.protectedCategories.contains(c)) return null;
    final e = expected[c] ?? 0;
    final pct = c == '*' ? 15 : (reductionCapPercent[c] ?? 0);
    if (pct == 0 || e == 0) return null;
    final capFloor = e - (e * pct) ~/ 100;
    final lo = _roundUpStep(hardFloor(c) > capFloor ? hardFloor(c) : capFloor);
    return lo < e ? lo : null;
  }

  int capacity(String c, {bool ignoreProtection = false}) {
    final lo = minLimit(c, ignoreProtection: ignoreProtection);
    return lo == null ? 0 : (expected[c]! - lo);
  }

  PlanAction action(String c, int limit, {bool adjusted = false}) {
    final e = expected[c]!;
    final pct = c == '*' ? 15 : (reductionCapPercent[c] ?? 0);
    final capId = f.add('cap:$c', 'Largest suggested cut: ${c == '*' ? 'all spending' : _catEn(c)}', 'أقصى تخفيض مقترح: ${c == '*' ? 'كل المصروف' : _catAr(c)}',
        _roundDownStep((e * pct) ~/ 100), FactSource.assumption,
        basisEn: '$pct% of expected spending — a pace most people can keep for a cycle (editable)', basisAr: '$pct٪ من المتوقع — وتيرة يمكن الالتزام بها لدورة (قابلة للتعديل)', cat: c == '*' ? null : c);
    final b = budgetsByCat[c];
    return PlanAction(
      id: 'cut:$c',
      categoryId: c,
      baselineFactId: 'base:$c',
      spentFactId: 'spent:$c',
      limitMinor: limit,
      impactMinor: e - limit,
      currentBudgetId: b?.id,
      currentBudgetMinor: b?.amountMinor,
      whyFactIds: [if (f.map.containsKey('avg:$c')) 'avg:$c', 'spent:$c', if (commit.containsKey(c)) 'commit:$c', capId],
      userAdjusted: adjusted,
    );
  }

  final actions = <PlanAction>[];
  var remaining = gap;
  // User-edited limits first, clamped between what's already committed/spent and expected.
  limitOverrides.forEach((c, v) {
    if (!expected.containsKey(c) || intent.protectedCategories.contains(c)) return;
    final lo = _roundUpStep(hardFloor(c));
    final hi = expected[c]!;
    final step = _roundDownStep(v);
    final limit = step < lo ? lo : (step > hi ? hi : step);
    if (limit >= hi) return;
    actions.add(action(c, limit, adjusted: true));
    remaining -= hi - limit;
  });
  final candidates = expected.keys.where((c) => !limitOverrides.containsKey(c)).map((c) => MapEntry(c, capacity(c))).where((e) => e.value > 0).toList()
    ..sort((a, b) => b.value != a.value ? b.value.compareTo(a.value) : a.key.compareTo(b.key));
  for (final cand in candidates) {
    if (remaining <= 0 || actions.length >= maxActions) break;
    final e = expected[cand.key]!;
    final lo = e - cand.value;
    final want = _roundDownStep(e - remaining);
    final limit = want > lo ? want : lo;
    actions.add(action(cand.key, limit));
    remaining -= e - limit;
  }

  final impact = actions.fold<int>(0, (a, x) => a + x.impactMinor);
  final projected = baselineSavings + impact;
  ids['projected'] = f.add('projected_savings', 'Projected savings with this plan', 'التوفير المتوقع مع هذه الخطة', projected, FactSource.observed,
      basisEn: 'Savings if nothing changes, plus the suggested cuts', basisAr: 'التوفير بدون تغيير، مضافاً إليه التخفيضات المقترحة');
  if (projected >= perCycle) return result(PlanStatus.feasible, actions: actions, covered: n, ids: ids);

  // ---- Not reachable: computed alternatives only.
  final alts = <PlanAlternative>[];
  final top = candidates.take(maxActions).fold<int>(0, (a, e) => a + e.value);
  final perCycleBest = baselineSavings + top;
  if (perCycleBest > 0) {
    alts.add(PlanAlternative(AlternativeKind.lowerTarget, amountMinor: _roundDownStep(perCycleBest) * months));
    final need = _ceilDiv(intent.targetMinor!, _roundDownStep(perCycleBest) > 0 ? _roundDownStep(perCycleBest) : perCycleBest);
    if (need > months && need <= 36) alts.add(PlanAlternative(AlternativeKind.extendDeadline, months: need));
  }
  final relax = intent.protectedCategories.map((c) => MapEntry(c, capacity(c, ignoreProtection: true))).where((e) => e.value > 0).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final r in relax.take(2)) {
    alts.add(PlanAlternative(AlternativeKind.relaxProtected, amountMinor: r.value, categoryId: r.key));
  }
  return result(PlanStatus.infeasible, actions: actions, alts: alts, covered: n, ids: ids);
}

String _d(DateTime t) {
  final w = ReportingZone.kuwait.toWall(t);
  return '${w.day.toString().padLeft(2, '0')}/${w.month.toString().padLeft(2, '0')}/${w.year}';
}

/// Progress of an applied plan in its cycle: actual spending vs each limit. Read-only.
class PlanProgress {
  final Map<String, int> spentByCategory; // action category → spent so far
  final Map<String, int> limitByCategory;
  final int incomeSoFar;
  final double cycleElapsed; // 0..1
  final List<String> overPace; // categories ahead of the plan's pace
  const PlanProgress(this.spentByCategory, this.limitByCategory, this.incomeSoFar, this.cycleElapsed, this.overPace);
  bool get needsUpdate => overPace.isNotEmpty;
}

PlanProgress planProgress(PlanProposal plan, PlannerInput input) {
  final period = Period(plan.periodStart, CycleCalculator(startDay: input.cycleStartDay).cycleFor(plan.periodStart).end);
  final t = totalsFor(input.txs, period, splitsByTx: input.splits);
  final spent = <String, int>{};
  final limits = <String, int>{};
  final over = <String>[];
  final total = period.end.difference(period.start).inSeconds;
  final elapsed = input.now.isBefore(period.start) ? 0.0 : (input.now.difference(period.start).inSeconds / total).clamp(0.0, 1.0);
  for (final a in plan.actions) {
    final s = a.categoryId == '*' ? t.spentIn(plan.currency) : (t.byCategory[plan.currency]?[a.categoryId] ?? 0);
    spent[a.categoryId] = s;
    limits[a.categoryId] = a.limitMinor;
    // Over pace: already past the limit, or spending faster than the cycle elapses
    // (with a 10 % allowance, and not in the first 20 % of the cycle).
    if (s > a.limitMinor || (elapsed >= 0.2 && s * 100 > (a.limitMinor * elapsed * 110).round())) over.add(a.categoryId);
  }
  return PlanProgress(spent, limits, t.incomeIn(plan.currency), elapsed, over);
}

/// Why a fresh plan differs from the accepted one: one entry per changed category.
class PlanChange {
  final String categoryId;
  final int? oldLimit;
  final int? newLimit;
  final int? spentNow;
  const PlanChange(this.categoryId, this.oldLimit, this.newLimit, this.spentNow);
}

List<PlanChange> diffPlans(PlanProposal accepted, PlanProposal fresh) {
  final old = {for (final a in accepted.actions) a.categoryId: a.limitMinor};
  final neu = {for (final a in fresh.actions) a.categoryId: a.limitMinor};
  final out = <PlanChange>[];
  for (final c in {...old.keys, ...neu.keys}) {
    if (old[c] == neu[c]) continue;
    out.add(PlanChange(c, old[c], neu[c], fresh.facts['spent:$c']?.amountMinor));
  }
  out.sort((a, b) => a.categoryId.compareTo(b.categoryId));
  return out;
}
