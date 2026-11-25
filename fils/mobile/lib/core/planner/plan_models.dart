/// "My Smart Plan" (خطتي الذكية) data model.
///
/// Every monetary value lives in a [Fact], computed by deterministic code in integer
/// minor units (fils for KWD). Language understanding (local parser or cloud AI)
/// produces only a [PlanIntent]; explanations may only *reference* facts by id.
library;

import 'dart:convert';

/// Where a number comes from. Shown to the user next to every figure.
enum FactSource {
  /// Computed from transactions captured in Fils.
  observed,

  /// Stated by the user (typed, said, or confirmed in the planner).
  confirmed,

  /// A rule the planner applied (e.g. "at most 30 % less on dining out"). Editable.
  assumption,
}

class Fact {
  final String id;
  final String labelEn;
  final String labelAr;
  final int amountMinor;
  final String currency;
  final FactSource source;

  /// How it was computed, e.g. "average of 3 complete cycles (Aug–Oct)".
  final String basisEn;
  final String basisAr;
  final String? categoryId;
  const Fact({
    required this.id,
    required this.labelEn,
    required this.labelAr,
    required this.amountMinor,
    required this.currency,
    required this.source,
    this.basisEn = '',
    this.basisAr = '',
    this.categoryId,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'label_en': labelEn,
        'label_ar': labelAr,
        'amount_minor': amountMinor,
        'currency': currency,
        'source': source.name,
        'basis_en': basisEn,
        'basis_ar': basisAr,
        if (categoryId != null) 'category_id': categoryId,
      };

  factory Fact.fromJson(Map<String, Object?> j) => Fact(
        id: j['id'] as String,
        labelEn: j['label_en'] as String? ?? '',
        labelAr: j['label_ar'] as String? ?? '',
        amountMinor: j['amount_minor'] as int,
        currency: j['currency'] as String,
        source: FactSource.values.byName(j['source'] as String),
        basisEn: j['basis_en'] as String? ?? '',
        basisAr: j['basis_ar'] as String? ?? '',
        categoryId: j['category_id'] as String?,
      );
}

enum DeadlineKind { thisCycle, months }

/// A commitment the user stated ("عندي قسط 120"). Fixed: never reduced by the plan.
class StatedCommitment {
  final String categoryId;
  final int amountMinor;
  const StatedCommitment(this.categoryId, this.amountMinor);
  Map<String, Object?> toJson() => {'category_id': categoryId, 'amount_minor': amountMinor};
  factory StatedCommitment.fromJson(Map<String, Object?> j) => StatedCommitment(j['category_id'] as String, j['amount_minor'] as int);
  @override
  bool operator ==(Object other) => other is StatedCommitment && other.categoryId == categoryId && other.amountMinor == amountMinor;
  @override
  int get hashCode => Object.hash(categoryId, amountMinor);
}

/// What the user wants. Produced by the local parser or by validated cloud AI output.
class PlanIntent {
  final int? targetMinor;
  final String? currency;
  final DeadlineKind? deadline;
  final int months; // for DeadlineKind.months (≥ 1)
  final Set<String> protectedCategories;

  /// Phrases mapped to several categories, shown as an editable assumption
  /// (e.g. "مصاريف البيت" → housing, bills, groceries).
  final Map<String, List<String>> groupedPhrases;
  final int? incomeMinor; // user-stated expected income for the period
  /// User-stated usual monthly spending (total), used only when Fils has no complete
  /// cycle of history: missing history is never treated as zero spending.
  final int? typicalSpendingMinor;
  final List<StatedCommitment> commitments;

  /// Words the user used for things that have no category (e.g. nothing matched).
  final List<String> unmatchedProtected;
  final String understoodBy; // 'local' | 'ai'
  const PlanIntent({
    this.targetMinor,
    this.currency,
    this.deadline,
    this.months = 1,
    this.protectedCategories = const {},
    this.groupedPhrases = const {},
    this.incomeMinor,
    this.typicalSpendingMinor,
    this.commitments = const [],
    this.unmatchedProtected = const [],
    this.understoodBy = 'local',
  });

  PlanIntent copyWith({
    int? targetMinor,
    String? currency,
    DeadlineKind? deadline,
    int? months,
    Set<String>? protectedCategories,
    int? incomeMinor,
    bool clearIncome = false,
    int? typicalSpendingMinor,
    List<StatedCommitment>? commitments,
  }) =>
      PlanIntent(
        targetMinor: targetMinor ?? this.targetMinor,
        currency: currency ?? this.currency,
        deadline: deadline ?? this.deadline,
        months: months ?? this.months,
        protectedCategories: protectedCategories ?? this.protectedCategories,
        groupedPhrases: groupedPhrases,
        incomeMinor: clearIncome ? null : (incomeMinor ?? this.incomeMinor),
        typicalSpendingMinor: typicalSpendingMinor ?? this.typicalSpendingMinor,
        commitments: commitments ?? this.commitments,
        unmatchedProtected: unmatchedProtected,
        understoodBy: understoodBy,
      );

  Map<String, Object?> toJson() => {
        'target_minor': targetMinor,
        'currency': currency,
        'deadline': deadline?.name,
        'months': months,
        'protected': protectedCategories.toList()..sort(),
        'grouped': groupedPhrases,
        'income_minor': incomeMinor,
        'typical_spending_minor': typicalSpendingMinor,
        'commitments': [for (final c in commitments) c.toJson()],
        'unmatched': unmatchedProtected,
        'understood_by': understoodBy,
      };

  factory PlanIntent.fromJson(Map<String, Object?> j) => PlanIntent(
        targetMinor: j['target_minor'] as int?,
        currency: j['currency'] as String?,
        deadline: j['deadline'] == null ? null : DeadlineKind.values.byName(j['deadline'] as String),
        months: j['months'] as int? ?? 1,
        protectedCategories: {...((j['protected'] as List?) ?? const []).cast<String>()},
        groupedPhrases: ((j['grouped'] as Map?) ?? const {}).map((k, v) => MapEntry(k as String, (v as List).cast<String>())),
        incomeMinor: j['income_minor'] as int?,
        typicalSpendingMinor: j['typical_spending_minor'] as int?,
        commitments: [for (final c in (j['commitments'] as List?) ?? const []) StatedCommitment.fromJson((c as Map).cast())],
        unmatchedProtected: ((j['unmatched'] as List?) ?? const []).cast<String>(),
        understoodBy: j['understood_by'] as String? ?? 'local',
      );
}

/// A question the planner needs answered before it can propose anything honest.
enum PlanQuestion { target, deadline, income, typicalSpending, currencyUnsupported }

enum PlanStatus { needsInput, onTrack, feasible, infeasible }

/// One suggested change: lower a category's limit for the plan period.
class PlanAction {
  final String id; // 'cut:<category>'
  final String categoryId;
  final String baselineFactId; // expected spending in the period
  final String spentFactId; // already spent this period (the limit can't go below it)
  final int limitMinor; // proposed limit for the period
  final int impactMinor; // baseline − limit
  final String? currentBudgetId; // existing budget for that category, if any
  final int? currentBudgetMinor;
  final List<String> whyFactIds; // supporting facts ("Why this suggestion?")
  final bool userAdjusted;
  const PlanAction({
    required this.id,
    required this.categoryId,
    required this.baselineFactId,
    required this.spentFactId,
    required this.limitMinor,
    required this.impactMinor,
    this.currentBudgetId,
    this.currentBudgetMinor,
    this.whyFactIds = const [],
    this.userAdjusted = false,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'category_id': categoryId,
        'baseline_fact': baselineFactId,
        'spent_fact': spentFactId,
        'limit_minor': limitMinor,
        'impact_minor': impactMinor,
        'current_budget_id': currentBudgetId,
        'current_budget_minor': currentBudgetMinor,
        'why': whyFactIds,
        'user_adjusted': userAdjusted,
      };

  factory PlanAction.fromJson(Map<String, Object?> j) => PlanAction(
        id: j['id'] as String,
        categoryId: j['category_id'] as String,
        baselineFactId: j['baseline_fact'] as String,
        spentFactId: j['spent_fact'] as String,
        limitMinor: j['limit_minor'] as int,
        impactMinor: j['impact_minor'] as int,
        currentBudgetId: j['current_budget_id'] as String?,
        currentBudgetMinor: j['current_budget_minor'] as int?,
        whyFactIds: ((j['why'] as List?) ?? const []).cast<String>(),
        userAdjusted: j['user_adjusted'] as bool? ?? false,
      );
}

enum AlternativeKind { lowerTarget, extendDeadline, relaxProtected }

/// An honest alternative when the goal isn't reachable. Every amount is computed.
class PlanAlternative {
  final AlternativeKind kind;
  final int? amountMinor; // lowerTarget: max reachable; relaxProtected: extra savings
  final int? months; // extendDeadline
  final String? categoryId; // relaxProtected
  const PlanAlternative(this.kind, {this.amountMinor, this.months, this.categoryId});
  Map<String, Object?> toJson() => {'kind': kind.name, 'amount_minor': amountMinor, 'months': months, 'category_id': categoryId};
  factory PlanAlternative.fromJson(Map<String, Object?> j) => PlanAlternative(AlternativeKind.values.byName(j['kind'] as String),
      amountMinor: j['amount_minor'] as int?, months: j['months'] as int?, categoryId: j['category_id'] as String?);
}

/// A limitation the user must know about (never hidden, never treated as zero).
enum PlanLimitation { shortHistory, noHistory, irregularIncome, otherCurrencies, accountsWithoutActivity, protectedWithoutSpending, pendingIncluded }

class PlanProposal {
  final String id; // stable id: also the idempotency key for apply
  final PlanIntent intent;
  final PlanStatus status;
  final List<PlanQuestion> questions;
  final Map<String, Fact> facts;
  final List<PlanAction> actions;
  final List<PlanAlternative> alternatives;
  final List<PlanLimitation> limitations;
  final String currency;
  final DateTime periodStart;
  final DateTime periodEnd;

  /// Fact ids for the summary figures.
  final String? targetFactId;
  final String? incomeFactId;
  final String? baselineSpendFactId;
  final String? baselineSavingsFactId;
  final String? projectedSavingsFactId;
  final String? gapFactId;
  final int coveredCycles;
  const PlanProposal({
    required this.id,
    required this.intent,
    required this.status,
    required this.questions,
    required this.facts,
    required this.actions,
    required this.alternatives,
    required this.limitations,
    required this.currency,
    required this.periodStart,
    required this.periodEnd,
    this.targetFactId,
    this.incomeFactId,
    this.baselineSpendFactId,
    this.baselineSavingsFactId,
    this.projectedSavingsFactId,
    this.gapFactId,
    this.coveredCycles = 0,
  });

  int amount(String? factId) => factId == null ? 0 : (facts[factId]?.amountMinor ?? 0);
  int get totalImpactMinor => actions.fold(0, (a, x) => a + x.impactMinor);

  Map<String, Object?> toJson() => {
        'id': id,
        'intent': intent.toJson(),
        'status': status.name,
        'questions': [for (final q in questions) q.name],
        'facts': [for (final f in facts.values) f.toJson()],
        'actions': [for (final a in actions) a.toJson()],
        'alternatives': [for (final a in alternatives) a.toJson()],
        'limitations': [for (final l in limitations) l.name],
        'currency': currency,
        'period_start': periodStart.toIso8601String(),
        'period_end': periodEnd.toIso8601String(),
        'target_fact': targetFactId,
        'income_fact': incomeFactId,
        'baseline_spend_fact': baselineSpendFactId,
        'baseline_savings_fact': baselineSavingsFactId,
        'projected_savings_fact': projectedSavingsFactId,
        'gap_fact': gapFactId,
        'covered_cycles': coveredCycles,
      };

  String encode() => jsonEncode(toJson());

  factory PlanProposal.fromJson(Map<String, Object?> j) => PlanProposal(
        id: j['id'] as String,
        intent: PlanIntent.fromJson((j['intent'] as Map).cast()),
        status: PlanStatus.values.byName(j['status'] as String),
        questions: [for (final q in (j['questions'] as List?) ?? const []) PlanQuestion.values.byName(q as String)],
        facts: {for (final f in (j['facts'] as List?) ?? const []) (f as Map)['id'] as String: Fact.fromJson(f.cast())},
        actions: [for (final a in (j['actions'] as List?) ?? const []) PlanAction.fromJson((a as Map).cast())],
        alternatives: [for (final a in (j['alternatives'] as List?) ?? const []) PlanAlternative.fromJson((a as Map).cast())],
        limitations: [for (final l in (j['limitations'] as List?) ?? const []) PlanLimitation.values.byName(l as String)],
        currency: j['currency'] as String,
        periodStart: DateTime.parse(j['period_start'] as String),
        periodEnd: DateTime.parse(j['period_end'] as String),
        targetFactId: j['target_fact'] as String?,
        incomeFactId: j['income_fact'] as String?,
        baselineSpendFactId: j['baseline_spend_fact'] as String?,
        baselineSavingsFactId: j['baseline_savings_fact'] as String?,
        projectedSavingsFactId: j['projected_savings_fact'] as String?,
        gapFactId: j['gap_fact'] as String?,
        coveredCycles: j['covered_cycles'] as int? ?? 0,
      );

  static PlanProposal decode(String s) => PlanProposal.fromJson((jsonDecode(s) as Map).cast());
}
