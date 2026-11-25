import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fils/core/domain/categories.dart';
import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/core/planner/goal_parser.dart';
import 'package:fils/core/planner/plan_engine.dart';
import 'package:fils/core/planner/plan_models.dart';
import 'package:fils/core/time/kuwait_time.dart';
import 'package:fils/data/db/database.dart';
import 'package:fils/data/planner/plan_service.dart';
import 'package:fils/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/planner_fixtures.dart';
import '../support/test_db.dart';

const goal = 'اوفر 200 دينار الشهر ده بس ما تقللش الجيم ولا مصاريف البيت';

Future<PlanProposal> proposal(FinanceStore s, {String id = 'plan-1'}) async =>
    buildPlan(await plannerInputFrom(s), parseGoal(goal, baseCurrency: 'KWD'), proposalId: id);

/// Everything the plan feature could possibly write to.
Future<String> fingerprint(FinanceStore s) async {
  final db = s.db;
  final parts = <String>[];
  for (final t in ['budgets', 'goals', 'transactions', 'outbox', 'audit_events', 'settings', 'smart_plans', 'smart_plan_changes']) {
    final rows = await db.customSelect('SELECT * FROM $t').get();
    parts.add('$t:${rows.map((r) => jsonEncode(r.data.map((k, v) => MapEntry(k, '$v')))).join('|')}');
  }
  return parts.join('\n');
}

Future<List<BudgetRow>> liveBudgets(FinanceStore s) => (s.db.select(s.db.budgets)..where((b) => b.deletedAt.isNull())).get();
int spent(List<TxRow> txs) => totalsFor(txs, calendarMonth(planNow)).spentIn('KWD');

void main() {
  test('preview makes no writes at all', () async {
    final s = await newTestStore(now: planNow);
    await seedHistory(s);
    final p = await proposal(s);
    expect(p.status, PlanStatus.feasible);
    final before = await fingerprint(s);
    final changes = await PlanService(s).preview(p, selected: {for (final a in p.actions) a.id}, createGoal: true);
    expect(changes.where((c) => c.entity == 'budget').length, p.actions.length);
    expect(changes.where((c) => c.entity == 'goal').length, 1);
    expect(await fingerprint(s), before);
  });

  test('apply changes only the selected budgets (+ goal); transactions untouched; double confirm is a no-op', () async {
    final s = await newTestStore(now: planNow);
    await seedHistory(s);
    // An existing food budget with custom settings that must survive.
    await s.saveBudget(categoryId: Cat.food, amountMinor: 250000, currency: 'KWD', rollover: true, thresholds: '50,90');
    final p = await proposal(s);
    final txBefore = jsonEncode((await s.allTransactions(includeDeleted: true)).map((t) => [t.id, t.amountMinor, t.status, t.accountId, t.deletedAt?.toIso8601String()]).toList());
    final svc = PlanService(s);
    final pick = {p.actions.first.id};
    final r = await svc.apply(p, selected: pick, createGoal: true);
    expect(r.outcome, ApplyOutcome.applied);
    final budgets = await liveBudgets(s);
    final a = p.actions.first;
    final b = budgets.singleWhere((x) => x.categoryId == a.categoryId);
    expect(b.amountMinor, a.limitMinor);
    if (a.categoryId == Cat.food) {
      expect(b.rollover, isTrue);
      expect(b.alertThresholds, '50,90');
    }
    // Unselected actions changed nothing.
    for (final other in p.actions.skip(1)) {
      expect(budgets.where((x) => x.categoryId == other.categoryId && x.amountMinor == other.limitMinor), isEmpty);
    }
    expect((await s.db.select(s.db.goals).get()).length, 1);
    expect(jsonEncode((await s.allTransactions(includeDeleted: true)).map((t) => [t.id, t.amountMinor, t.status, t.accountId, t.deletedAt?.toIso8601String()]).toList()), txBefore);
    final fp = await fingerprint(s);
    expect((await svc.apply(p, selected: pick, createGoal: true)).outcome, ApplyOutcome.alreadyApplied);
    expect(await fingerprint(s), fp);
  });

  test('crash mid-apply leaves nothing; retry applies exactly once', () async {
    final s = await newTestStore(now: planNow);
    await seedHistory(s);
    final p = await proposal(s);
    final before = await fingerprint(s);
    var calls = 0;
    final crashing = PlanService(s, faultInjector: (stage) {
      if (stage == 'apply_mid' && ++calls == 2) throw StateError('killed');
    });
    await expectLater(crashing.apply(p, selected: {for (final x in p.actions) x.id}, createGoal: true), throwsStateError);
    expect(await fingerprint(s), before, reason: 'no partial plan');
    final r = await PlanService(s).apply(p, selected: {for (final x in p.actions) x.id}, createGoal: true);
    expect(r.outcome, ApplyOutcome.applied);
    expect((await s.db.select(s.db.smartPlanChanges).get()).length, p.actions.length + 1);
  });

  test('undo restores exact previous values once; a later user edit is kept; restart keeps state', () async {
    final dir = await Directory.systemTemp.createTemp('fils_plan');
    final f = File('${dir.path}/p.db');
    var db = AppDatabase(NativeDatabase(f));
    var s = FinanceStore(db, clock: () => planNow);
    await s.ensureSeeded();
    await seedHistory(s);
    final shop = await s.saveBudget(categoryId: Cat.shopping, amountMinor: 95000, currency: 'KWD');
    final p = await proposal(s);
    final before = jsonEncode((await liveBudgets(s)).map((b) => [b.categoryId, b.amountMinor]).toList());
    final all = {for (final x in p.actions) x.id};
    await PlanService(s).apply(p, selected: all, createGoal: true);
    // Restart: apply again is still a no-op.
    await db.close();
    db = AppDatabase(NativeDatabase(f));
    s = FinanceStore(db, clock: () => planNow);
    expect((await PlanService(s).apply(p, selected: all, createGoal: true)).outcome, ApplyOutcome.alreadyApplied);
    // The user edits one of the plan's budgets by hand afterwards.
    final edited = p.actions.firstWhere((a) => a.categoryId != Cat.shopping);
    final eb = (await liveBudgets(s)).singleWhere((b) => b.categoryId == edited.categoryId);
    await s.saveBudget(id: eb.id, categoryId: eb.categoryId, amountMinor: eb.amountMinor + 5000, currency: 'KWD');
    final u = await PlanService(s).undo(p.id);
    expect(u.outcome, UndoOutcome.undone);
    expect(u.keptUserEdits, [edited.categoryId]);
    final afterUndo = await liveBudgets(s);
    if (p.actions.any((a) => a.categoryId == Cat.shopping)) {
      expect(afterUndo.singleWhere((b) => b.id == shop.id).amountMinor, 95000, reason: 'restored exactly');
    }
    expect(afterUndo.singleWhere((b) => b.categoryId == edited.categoryId).amountMinor, eb.amountMinor + 5000);
    expect((await s.db.select(s.db.goals).get()).where((g) => g.deletedAt == null), isEmpty, reason: 'created goal removed');
    final fp = await fingerprint(s);
    expect((await PlanService(s).undo(p.id)).outcome, UndoOutcome.alreadyUndone);
    expect(await fingerprint(s), fp);
    expect((await PlanService(s).apply(p, selected: all)).outcome, ApplyOutcome.alreadyUndone, reason: 'an undone plan is not re-applied by a late tap');
    // Without the manual edit everything would be back to the original values.
    expect(before, isNotEmpty);
    await db.close();
    await dir.delete(recursive: true);
  });

  test('crash mid-undo leaves the plan applied; retry undoes once', () async {
    final s = await newTestStore(now: planNow);
    await seedHistory(s);
    final p = await proposal(s);
    await PlanService(s).apply(p, selected: {for (final x in p.actions) x.id});
    final applied = await fingerprint(s);
    await expectLater(PlanService(s, faultInjector: (st) => throw StateError('killed')).undo(p.id), throwsStateError);
    expect(await fingerprint(s), applied);
    expect((await PlanService(s).undo(p.id)).outcome, UndoOutcome.undone);
  });

  test('double confirmation from two connections: applied exactly once', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final dir = await Directory.systemTemp.createTemp('fils_plan2');
    final f = File('${dir.path}/c.db');
    void setup(dynamic d) {
      d.execute('PRAGMA journal_mode = WAL');
      d.execute('PRAGMA busy_timeout = 5000');
    }

    final dbA = AppDatabase(NativeDatabase.createInBackground(f, setup: setup));
    final a = FinanceStore(dbA, clock: () => planNow);
    await a.ensureSeeded();
    await seedHistory(a);
    final dbB = AppDatabase(NativeDatabase.createInBackground(f, setup: setup));
    final b = FinanceStore(dbB, clock: () => planNow);
    final p = await proposal(a);
    final sel = {for (final x in p.actions) x.id};
    final results = await Future.wait([PlanService(a).apply(p, selected: sel, createGoal: true), PlanService(b).apply(p, selected: sel, createGoal: true)]);
    expect(results.map((r) => r.outcome).toSet(), {ApplyOutcome.applied, ApplyOutcome.alreadyApplied});
    expect((await a.db.select(a.db.smartPlanChanges).get()).length, p.actions.length + 1);
    expect((await a.db.select(a.db.goals).get()).length, 1);
    await dbA.close();
    await dbB.close();
    await dir.delete(recursive: true);
  });

  test('a new plan for the same cycle supersedes the old one; activePlan returns the latest', () async {
    final s = await newTestStore(now: planNow);
    await seedHistory(s);
    final p1 = await proposal(s, id: 'p1');
    await PlanService(s).apply(p1, selected: {p1.actions.first.id});
    final p2 = buildPlan(await plannerInputFrom(s), parseGoal('اوفر 250 دينار الشهر ده', baseCurrency: 'KWD'), proposalId: 'p2');
    await PlanService(s).apply(p2, selected: {for (final x in p2.actions) x.id});
    final rows = await s.db.select(s.db.smartPlans).get();
    expect(rows.singleWhere((r) => r.id == 'p1').status, 'superseded');
    expect((await PlanService(s).activePlan(planNow))!.id, 'p2');
  });

  test('preferences are explicit, local, editable and resettable', () async {
    final s = await newTestStore(now: planNow);
    final svc = PlanService(s);
    expect((await svc.prefs()).protectedCategories, isEmpty);
    await svc.savePrefs(const PlannerPrefs(protectedCategories: {Cat.fitness, Cat.housing}));
    expect((await svc.prefs()).protectedCategories, {Cat.fitness, Cat.housing});
    await svc.resetPrefs();
    expect((await svc.prefs()).protectedCategories, isEmpty);
  });

  test('wipeAll clears plans too', () async {
    final s = await newTestStore(now: planNow);
    await seedHistory(s);
    final p = await proposal(s);
    await PlanService(s).apply(p, selected: {for (final x in p.actions) x.id}, createGoal: true);
    await s.wipeAll();
    expect(await s.db.select(s.db.smartPlans).get(), isEmpty);
    expect(await s.db.select(s.db.smartPlanChanges).get(), isEmpty);
  });

  test('real v4 database (generated by accbad4) upgrades to v5, keeps every record, then plans, applies and undoes', () async {
    final manifest = jsonDecode(File('test/fixtures/db/v4_accbad4.db.json').readAsStringSync()) as Map<String, dynamic>;
    expect(manifest['user_version'], 4);
    final dir = await Directory.systemTemp.createTemp('fils_v5');
    final f = File('${dir.path}/old.db');
    File('test/fixtures/db/v4_accbad4.db').copySync(f.path);
    final db = AppDatabase(NativeDatabase(f));
    final s = FinanceStore(db, clock: () => DateTime.utc(2026, 11, 22, 15));
    expect((await db.customSelect('PRAGMA user_version').getSingle()).data.values.first, 5);
    final counts = (manifest['counts'] as Map).cast<String, int>();
    for (final t in ['accounts', 'transactions', 'source_events', 'budgets', 'goals', 'outbox', 'audit_events', 'settings', 'categories']) {
      final n = (await db.customSelect('SELECT COUNT(*) AS n FROM $t').getSingle()).data['n'] as int;
      expect(n, counts[t], reason: '$t preserved');
    }
    // The new Fitness category is added by the normal startup seeding.
    await s.ensureSeeded();
    expect((await s.categories()).any((c) => c.id == Cat.fitness), isTrue);
    expect(await db.select(db.smartPlans).get(), isEmpty);
    // Too little history in the old file → the planner asks, then plans with the user's figures.
    final input = PlannerInput(txs: await s.allTransactions(), budgets: await liveBudgets(s), accounts: await s.accounts(), baseCurrency: 'KWD', now: DateTime.utc(2026, 11, 22, 15));
    final i = parseGoal('اوفر 100 دينار الشهر ده', baseCurrency: 'KWD');
    expect(buildPlan(input, i, proposalId: 'x').status, PlanStatus.needsInput);
    final p = buildPlan(input, i.copyWith(incomeMinor: 900000, typicalSpendingMinor: 850000), proposalId: 'v5');
    expect(p.status, PlanStatus.feasible);
    expect((await PlanService(s).apply(p, selected: {for (final x in p.actions) x.id})).outcome, ApplyOutcome.applied);
    expect((await PlanService(s).undo('v5')).outcome, UndoOutcome.undone);
    await db.close();
    await dir.delete(recursive: true);
  });
}
