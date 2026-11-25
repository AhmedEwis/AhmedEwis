import 'package:fils/core/domain/categories.dart';
import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/core/parsing/models.dart';
import 'package:fils/core/planner/goal_parser.dart';
import 'package:fils/core/planner/plan_engine.dart';
import 'package:fils/core/planner/plan_models.dart';
import 'package:fils/data/ingestion.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/planner_fixtures.dart';
import '../support/test_db.dart';

const headline = 'عايز أوفر 150 دينار الشهر ده، بس ما تقللش الجيم ولا مصاريف البيت.';
final known = {for (final c in systemCategories) c.id};

void expectSound(PlanProposal p) {
  for (final a in p.actions) {
    expect(p.facts.containsKey(a.baselineFactId), isTrue, reason: a.id);
    for (final w in a.whyFactIds) {
      expect(p.facts.containsKey(w), isTrue, reason: '${a.id} → $w');
    }
    expect(a.impactMinor, p.amount(a.baselineFactId) - a.limitMinor);
    expect(a.limitMinor, greaterThanOrEqualTo(p.facts[a.spentFactId]?.amountMinor ?? 0), reason: 'never below what is already spent');
    expect(a.limitMinor % limitStepMinor, 0);
    expect(p.intent.protectedCategories.contains(a.categoryId), isFalse, reason: 'protected category cut');
  }
  expect(p.actions.length, lessThanOrEqualTo(maxActions));
}

void main() {
  group('understanding (local parser)', () {
    test('Egyptian Arabic headline: target, this cycle, gym + household protected (grouped, shown as assumption)', () {
      final i = parseGoal(headline, baseCurrency: 'KWD');
      expect(i.targetMinor, 150000);
      expect(i.currency, 'KWD');
      expect(i.deadline, DeadlineKind.thisCycle);
      expect(i.protectedCategories, {Cat.fitness, Cat.housing, Cat.bills, Cat.groceries});
      expect(i.groupedPhrases.keys, contains('مصاريف البيت'));
      expect(i.understoodBy, 'local');
    });

    test('Kuwaiti Arabic with Arabic-Indic digits and د.ك', () {
      final i = parseGoal('ابي اوفر ١٥٠ د.ك هالشهر بس لا تقرب النادي ولا المطاعم', baseCurrency: 'KWD');
      expect(i.targetMinor, 150000);
      expect(i.deadline, DeadlineKind.thisCycle);
      expect(i.protectedCategories, containsAll([Cat.fitness, Cat.food]));
    });

    test('English', () {
      final i = parseGoal("I want to save 150 KD this month but don't cut the gym or household expenses", baseCurrency: 'KWD');
      expect(i.targetMinor, 150000);
      expect(i.deadline, DeadlineKind.thisCycle);
      expect(i.protectedCategories, containsAll([Cat.fitness, Cat.housing, Cat.bills, Cat.groceries]));
    });

    test('Arabic number words, income and a stated commitment', () {
      final i = parseGoal('عايز احوش مية وخمسين دينار، راتبي 900 وعندي قسط 120', baseCurrency: 'KWD');
      expect(i.targetMinor, 150000);
      expect(i.incomeMinor, 900000);
      expect(i.commitments, [const StatedCommitment(Cat.installments, 120000)]);
      expect(i.deadline, isNull, reason: 'no deadline said → planner asks');
    });

    test('multi-month deadline', () {
      final i = parseGoal('save 600 KWD in 3 months', baseCurrency: 'KWD');
      expect(i.targetMinor, 600000);
      expect(i.deadline, DeadlineKind.months);
      expect(i.months, 3);
      expect(parseGoal('اوفر 600 دينار خلال ٣ شهور', baseCurrency: 'KWD').months, 3);
    });

    test('word boundaries: "نت" (internet) does not fire inside "كانت"', () {
      final i = parseGoal('اوفر 100 دينار الشهر ده بس ما تقللش اللي كانت ضروريه', baseCurrency: 'KWD');
      expect(i.protectedCategories, isNot(contains(Cat.telecom)));
    });

    test('no amount → no invented target', () {
      final i = parseGoal('عايز أوفر الشهر ده', baseCurrency: 'KWD');
      expect(i.targetMinor, isNull);
    });
  });

  group('cloud AI intent validation (the model cannot invent amounts)', () {
    test('valid: amounts carry evidence from the user text', () {
      final i = validateAiIntent({
        'target_minor': 150000, 'target_evidence': '150 دينار', 'currency': 'KWD', 'deadline': 'this_cycle',
        'protected_categories': [Cat.fitness, Cat.housing],
      }, headline, knownCategories: known);
      expect(i, isNotNull);
      expect(i!.targetMinor, 150000);
      expect(i.understoodBy, 'ai');
    });

    test('fabricated amount (1500 claimed, user said 150) is rejected', () {
      expect(validateAiIntent({'target_minor': 1500000, 'target_evidence': '150 دينار', 'deadline': 'this_cycle'}, headline, knownCategories: known), isNull);
      expect(validateAiIntent({'target_minor': 1500000, 'target_evidence': '1500 دينار', 'deadline': 'this_cycle'}, headline, knownCategories: known), isNull);
    });

    test('amount without evidence, unknown category, bad deadline or months → rejected', () {
      expect(validateAiIntent({'target_minor': 150000}, headline, knownCategories: known), isNull);
      expect(validateAiIntent({'target_minor': 150000, 'target_evidence': '150', 'protected_categories': ['delete_all']}, headline, knownCategories: known), isNull);
      expect(validateAiIntent({'target_minor': 150000, 'target_evidence': '150', 'deadline': 'tomorrow'}, headline, knownCategories: known), isNull);
      expect(validateAiIntent({'target_minor': 150000, 'target_evidence': '150', 'deadline': 'months', 'months': 999}, headline, knownCategories: known), isNull);
      expect(validateAiIntent({'income_minor': 900000, 'income_evidence': 'راتبي 900'}, headline, knownCategories: known), isNull);
    });
  });

  group('deterministic plan', () {
    test('headline goal: feasible, cuts only unprotected categories, every figure from facts', () async {
      final s = await newTestStore(now: planNow);
      await seedHistory(s, fitness: true);
      final p = buildPlan(await plannerInputFrom(s), parseGoal(headline, baseCurrency: 'KWD'), proposalId: 'p1');
      expect(p.status, PlanStatus.feasible);
      expect(p.coveredCycles, 3);
      expect(p.amount(p.incomeFactId), 1000000);
      expect(p.facts['income']!.source, FactSource.observed);
      // Shopping average includes the October refund: (90 + 90 + 70) / 3.
      expect(p.amount('avg:shopping'), 83333);
      // Transfers to others are never spending.
      expect(p.facts.keys.where((k) => k.contains('transfers')), isEmpty);
      final expectedSum = p.facts.values.where((f) => f.id.startsWith('base:')).fold<int>(0, (a, f) => a + f.amountMinor);
      expect(p.amount(p.baselineSpendFactId), expectedSum);
      expect(p.amount(p.baselineSavingsFactId), 1000000 - expectedSum);
      expect(p.amount(p.projectedSavingsFactId), greaterThanOrEqualTo(150000));
      expect(p.amount(p.projectedSavingsFactId), p.amount(p.baselineSavingsFactId) + p.totalImpactMinor);
      expect(p.actions.map((a) => a.categoryId).toSet().intersection({Cat.fitness, Cat.housing, Cat.bills, Cat.groceries}), isEmpty);
      expectSound(p);
    });

    test('pending authorizations count (and are disclosed); held captures and declined rows never do', () async {
      final s = await newTestStore(now: planNow);
      final a = await seedHistory(s);
      final before = buildPlan(await plannerInputFrom(s), parseGoal(headline, baseCurrency: 'KWD'), proposalId: 'p');
      await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 7000, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 8), source: 'sms', categoryId: Cat.food, status: TxStatuses.pending);
      await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 99000, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 8), source: 'sms', categoryId: Cat.food, status: TxStatuses.declined);
      // A held possible duplicate: same paste twice within 3 minutes.
      final ing = IngestionService(s);
      const m = 'Purchase of KWD 12.000 at STARBUCKS card ending 4410';
      await ing.ingest(RawEvent(text: m, receivedAt: DateTime.utc(2026, 11, 9, 8), source: SourceKind.paste));
      final held = await ing.ingest(RawEvent(text: m, receivedAt: DateTime.utc(2026, 11, 9, 8, 1), source: SourceKind.paste));
      expect(held.outcome, IngestOutcome.possibleDuplicate);
      final after = buildPlan(await plannerInputFrom(s), parseGoal(headline, baseCurrency: 'KWD'), proposalId: 'p');
      // Food spent: 40 + 7 (pending) + 12 (the first capture only). Declined and held don't count.
      expect(after.amount('spent:food') - before.amount('spent:food'), 7000 + 12000);
      expect(after.limitations, contains(PlanLimitation.pendingIncluded));
    });

    test('no history: asks for income and usual spending, never assumes zero', () async {
      final s = await newTestStore(now: planNow);
      final p = buildPlan(await plannerInputFrom(s), parseGoal(headline, baseCurrency: 'KWD'), proposalId: 'p');
      expect(p.status, PlanStatus.needsInput);
      expect(p.questions, containsAll([PlanQuestion.income, PlanQuestion.typicalSpending]));
      expect(p.limitations, contains(PlanLimitation.noHistory));
      expect(p.actions, isEmpty);
      // With the user's own figures it plans on overall spending only.
      final i = parseGoal(headline, baseCurrency: 'KWD').copyWith(incomeMinor: 900000, typicalSpendingMinor: 800000);
      final q = buildPlan(await plannerInputFrom(s), i, proposalId: 'p');
      expect(q.status, PlanStatus.feasible);
      expect(q.actions.single.categoryId, '*');
      expect(q.facts['typical']!.source, FactSource.confirmed);
      expect(q.facts['income']!.source, FactSource.confirmed);
      expectSound(q);
    });

    test('impossible goal: infeasible, alternatives are computed, no invented savings', () async {
      final s = await newTestStore(now: planNow);
      await seedHistory(s);
      final i = parseGoal('عايز أوفر 2000 دينار الشهر ده', baseCurrency: 'KWD');
      final p = buildPlan(await plannerInputFrom(s), i, proposalId: 'p');
      expect(p.status, PlanStatus.infeasible);
      expect(p.amount(p.projectedSavingsFactId), lessThan(2000000));
      for (final a in p.actions) {
        final cap = reductionCapPercent[a.categoryId]!;
        expect(a.impactMinor, lessThanOrEqualTo(p.amount(a.baselineFactId) * cap ~/ 100));
      }
      final lower = p.alternatives.firstWhere((x) => x.kind == AlternativeKind.lowerTarget);
      expect(lower.amountMinor, lessThanOrEqualTo(p.amount(p.projectedSavingsFactId)));
      final ext = p.alternatives.firstWhere((x) => x.kind == AlternativeKind.extendDeadline);
      expect(ext.months! * lower.amountMinor!, greaterThanOrEqualTo(2000000));
      expectSound(p);
    });

    test('protecting everything cuttable: infeasible, with "relax protection" alternatives only from real capacity', () async {
      final s = await newTestStore(now: planNow);
      await seedHistory(s);
      final i = parseGoal('اوفر 250 دينار الشهر ده بس ما تقللش المطاعم ولا التسوق ولا الترفيه ولا البقاله', baseCurrency: 'KWD');
      final p = buildPlan(await plannerInputFrom(s), i, proposalId: 'p');
      expect(p.status, PlanStatus.infeasible);
      expect(p.actions, isEmpty);
      final relax = p.alternatives.where((x) => x.kind == AlternativeKind.relaxProtected).toList();
      expect(relax.map((r) => r.categoryId), contains(Cat.food));
      expect(relax.first.amountMinor, lessThanOrEqualTo(p.amount('base:food') * 30 ~/ 100));
    });

    test('irregular income → lowest recent cycle, labelled as an assumption', () async {
      final s = await newTestStore(now: planNow);
      await seedHistory(s, salaries: [1200000, 700000, 1100000]);
      final p = buildPlan(await plannerInputFrom(s), parseGoal(headline, baseCurrency: 'KWD'), proposalId: 'p');
      expect(p.limitations, contains(PlanLimitation.irregularIncome));
      expect(p.facts['income']!.amountMinor, 700000);
      expect(p.facts['income']!.source, FactSource.assumption);
    });

    test('a covered cycle with no income: asks instead of assuming zero', () async {
      final s = await newTestStore(now: planNow);
      await seedHistory(s, salaries: [1000000, 0, 1000000].map((v) => v == 0 ? 1 : v).toList());
      // Remove the September salary entirely.
      final sep = (await s.allTransactions()).firstWhere((t) => t.kind == TxKinds.income && t.occurredAt.month == 9);
      await s.deleteTransaction(sep.id);
      final p = buildPlan(await plannerInputFrom(s), parseGoal(headline, baseCurrency: 'KWD'), proposalId: 'p');
      expect(p.questions, contains(PlanQuestion.income));
    });

    test('other currencies are reported separately, never mixed or converted; non-base goals are refused', () async {
      final s = await newTestStore(now: planNow);
      final a = await seedHistory(s);
      final usd = await s.createAccount(name: 'USD card', kind: 'card', currency: 'USD');
      await s.addTransaction(accountId: usd.id, kind: TxKinds.expense, amountMinor: 300000, currency: 'USD', occurredAt: DateTime.utc(2026, 10, 5), source: 'sms', categoryId: Cat.shopping);
      final p = buildPlan(await plannerInputFrom(s), parseGoal(headline, baseCurrency: 'KWD'), proposalId: 'p');
      expect(p.limitations, contains(PlanLimitation.otherCurrencies));
      expect(p.facts['other_currency:USD']!.amountMinor, 300000);
      expect(p.amount('avg:shopping'), 83333, reason: 'USD spending not mixed into KWD');
      final q = buildPlan(await plannerInputFrom(s), parseGoal('save 150 USD this month', baseCurrency: 'KWD'), proposalId: 'p');
      expect(q.questions, [PlanQuestion.currencyUnsupported]);
      expect(a.currency, 'KWD');
    });

    test('user edits a limit: clamped to what is already spent, and the plan recalculates', () async {
      final s = await newTestStore(now: planNow);
      await seedHistory(s);
      final input = await plannerInputFrom(s);
      final intent = parseGoal('اوفر 200 دينار الشهر ده', baseCurrency: 'KWD');
      final p = buildPlan(input, intent, proposalId: 'p');
      final q = buildPlan(input, intent, proposalId: 'p', limitOverrides: {Cat.food: 1000});
      final food = q.actions.firstWhere((a) => a.categoryId == Cat.food);
      expect(food.limitMinor, 40000, reason: '40 KWD already spent on food this cycle');
      expect(food.userAdjusted, isTrue);
      expect(q.amount(q.projectedSavingsFactId), q.amount(q.baselineSavingsFactId) + q.totalImpactMinor);
      expect(q.amount(q.projectedSavingsFactId), isNot(p.amount(p.projectedSavingsFactId)));
      expectSound(q);
    });

    test('a goal over 3 months plans one third per cycle', () async {
      final s = await newTestStore(now: planNow);
      await seedHistory(s);
      final p = buildPlan(await plannerInputFrom(s), parseGoal('save 600 KWD in 3 months', baseCurrency: 'KWD'), proposalId: 'p');
      expect(p.amount(p.targetFactId), 200000);
      expect(p.facts['target']!.amountMinor, 600000);
    });

    test('protected category with no spending is disclosed (e.g. gym paid from another category)', () async {
      final s = await newTestStore(now: planNow);
      await seedHistory(s);
      final p = buildPlan(await plannerInputFrom(s), parseGoal(headline, baseCurrency: 'KWD'), proposalId: 'p');
      expect(p.limitations, contains(PlanLimitation.protectedWithoutSpending));
    });

    test('progress and adaptation: over-pace categories trigger an update offer; the diff explains changes', () async {
      final s = await newTestStore(now: planNow);
      final a = await seedHistory(s);
      final intent = parseGoal('اوفر 200 دينار الشهر ده', baseCurrency: 'KWD');
      final accepted = buildPlan(await plannerInputFrom(s), intent, proposalId: 'p');
      final food = accepted.actions.firstWhere((x) => x.categoryId == Cat.food);
      await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: food.limitMinor, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 9), source: 'sms', categoryId: Cat.food);
      final input = await plannerInputFrom(s);
      final prog = planProgress(accepted, input);
      expect(prog.overPace, contains(Cat.food));
      expect(prog.needsUpdate, isTrue);
      final fresh = buildPlan(input, intent, proposalId: 'p2');
      final diff = diffPlans(accepted, fresh);
      expect(diff, isNotEmpty);
      expect(diff.any((d) => d.categoryId == Cat.food), isTrue);
    });
  });
}
