/// State and logic for "My Smart Plan" (no widget code, so it's testable).
library;

import 'package:material_ui/material_ui.dart' show ChangeNotifier;
import 'package:uuid/uuid.dart';

import '../../core/planner/goal_parser.dart';
import '../../core/planner/plan_engine.dart';
import '../../core/planner/plan_models.dart';
import '../../data/db/database.dart';
import '../../data/planner/cloud_planner.dart';
import '../../data/planner/plan_service.dart';
import '../../data/store.dart';

/// How the request was understood. Shown to the user: live AI is never claimed unless a
/// live, validated model response was used.
enum Understanding { none, liveAi, local }

class SmartPlanController extends ChangeNotifier {
  final FinanceStore store;
  final PlanService service;
  final CloudPlanner? cloud;
  final bool arabic;
  final String baseCurrency;
  final int cycleStartDay;
  final DateTime Function() now;
  SmartPlanController({
    required this.store,
    required this.service,
    required this.cloud,
    required this.arabic,
    required this.baseCurrency,
    required this.cycleStartDay,
    required this.now,
  });

  String text = '';
  PlanIntent? intent;
  PlanProposal? proposal;
  PlanExplanation? explanation;
  Understanding understanding = Understanding.none;
  AiUnavailable? aiReason; // why live AI wasn't used (null when it was)
  bool explanationIsLive = false;
  bool busy = false;
  final Map<String, int> overrides = {};
  final Set<String> deselected = {};
  bool createGoal = true;
  String proposalId = const Uuid().v4();
  Set<String> remembered = {};

  // Accepted plan for this cycle.
  SmartPlanRow? active;
  PlanProposal? activeProposal;
  PlanProgress? progress;
  PlanProposal? updated; // a fresh proposal offered when circumstances changed
  List<PlanChange> updateReasons = const [];

  Set<String> get selected => {for (final a in proposal?.actions ?? const <PlanAction>[]) if (!deselected.contains(a.id)) a.id};

  Future<PlannerInput> _input() async => PlannerInput(
        txs: await store.allTransactions(),
        splits: await store.allSplits(),
        recurring: await store.recurring(),
        budgets: await (store.db.select(store.db.budgets)..where((b) => b.deletedAt.isNull())).get(),
        accounts: await store.accounts(),
        baseCurrency: baseCurrency,
        cycleStartDay: cycleStartDay,
        now: now(),
      );

  Future<void> load() async {
    remembered = (await service.prefs()).protectedCategories;
    active = await service.activePlan(now());
    activeProposal = active == null ? null : PlanService.proposalOf(active!);
    progress = activeProposal == null ? null : planProgress(activeProposal!, await _input());
    notifyListeners();
  }

  /// Understands [input] (live AI when consented and available, else the local parser),
  /// then computes the plan. The model's output is validated; it can't set any amount
  /// that isn't in the user's own words.
  Future<void> understand(String input) async {
    if (input.trim().isEmpty) return;
    text = input;
    busy = true;
    notifyListeners();
    PlanIntent? i;
    aiReason = null;
    if (cloud != null) {
      try {
        i = await cloud!.understand(input, arabic: arabic, today: now(), cycleStartDay: cycleStartDay);
        understanding = Understanding.liveAi;
      } on PlannerAiException catch (e) {
        aiReason = e.reason;
      }
    } else {
      aiReason = AiUnavailable.notConfigured;
    }
    if (i == null) {
      i = parseGoal(input, baseCurrency: baseCurrency);
      understanding = Understanding.local;
    }
    // Remembered protections apply only when the user asked Fils to remember them.
    if (remembered.isNotEmpty) i = i.copyWith(protectedCategories: {...i.protectedCategories, ...remembered});
    intent = i;
    overrides.clear();
    deselected.clear();
    proposalId = const Uuid().v4();
    await _recompute(explain: true);
    busy = false;
    notifyListeners();
  }

  Future<void> _recompute({bool explain = false}) async {
    final i = intent;
    if (i == null) return;
    proposal = buildPlan(await _input(), i, proposalId: proposalId, limitOverrides: Map.of(overrides));
    explanationIsLive = false;
    explanation = null;
    final p = proposal!;
    if (p.status != PlanStatus.needsInput) {
      if (explain && understanding == Understanding.liveAi && cloud != null) {
        try {
          explanation = await cloud!.explain(p, arabic: arabic);
          explanationIsLive = true;
        } on PlannerAiException catch (e) {
          aiReason ??= e.reason;
        }
      }
      explanation ??= localExplanation(p, arabic: arabic);
    }
    notifyListeners();
  }

  // ---- Answers and edits: every change recalculates immediately.
  Future<void> setIncome(int minor) async {
    intent = (intent ?? const PlanIntent()).copyWith(incomeMinor: minor);
    await _recompute();
  }

  Future<void> setTypicalSpending(int minor) async {
    intent = (intent ?? const PlanIntent()).copyWith(typicalSpendingMinor: minor);
    await _recompute();
  }

  Future<void> setTarget(int minor) async {
    intent = (intent ?? const PlanIntent()).copyWith(targetMinor: minor);
    await _recompute();
  }

  Future<void> setDeadline(DeadlineKind k, {int months = 1}) async {
    intent = (intent ?? const PlanIntent()).copyWith(deadline: k, months: months);
    await _recompute();
  }

  Future<void> toggleProtected(String categoryId) async {
    final cur = {...?intent?.protectedCategories};
    cur.contains(categoryId) ? cur.remove(categoryId) : cur.add(categoryId);
    overrides.remove(categoryId);
    intent = (intent ?? const PlanIntent()).copyWith(protectedCategories: cur);
    await _recompute();
  }

  Future<void> adjustLimit(String categoryId, int newLimitMinor) async {
    overrides[categoryId] = newLimitMinor;
    await _recompute();
  }

  void toggleSelected(String actionId) {
    deselected.contains(actionId) ? deselected.remove(actionId) : deselected.add(actionId);
    notifyListeners();
  }

  void setCreateGoal(bool v) {
    createGoal = v;
    notifyListeners();
  }

  Future<void> rememberProtected() async {
    final p = intent?.protectedCategories ?? const <String>{};
    await service.savePrefs(PlannerPrefs(protectedCategories: p));
    remembered = p;
    notifyListeners();
  }

  Future<void> forget(String categoryId) async {
    remembered = {...remembered}..remove(categoryId);
    await service.savePrefs(PlannerPrefs(protectedCategories: remembered));
    notifyListeners();
  }

  Future<void> resetMemory() async {
    await service.resetPrefs();
    remembered = {};
    notifyListeners();
  }

  // ---- Preview → Confirm → Apply → Undo.
  Future<List<PlannedChange>> preview() => service.preview(proposal!, selected: selected, createGoal: createGoal);

  Future<ApplyResult> apply() async {
    final r = await service.apply(proposal!, selected: selected, createGoal: createGoal, explanation: explanation?.toJson());
    await load();
    return r;
  }

  Future<UndoResult> undo(String planId) async {
    final r = await service.undo(planId);
    updated = null;
    await load();
    return r;
  }

  /// Offers a fresh plan for the same goal when the accepted one no longer fits.
  /// Nothing changes until the user previews and confirms it.
  Future<void> offerUpdate() async {
    final a = activeProposal;
    if (a == null) return;
    updated = buildPlan(await _input(), a.intent, proposalId: const Uuid().v4());
    updateReasons = diffPlans(a, updated!);
    notifyListeners();
  }

  /// Opens the offered update as the current draft, ready to preview and confirm.
  Future<void> reviewUpdate() async {
    final u = updated;
    if (u == null) return;
    intent = u.intent;
    understanding = u.intent.understoodBy == 'ai' ? Understanding.liveAi : Understanding.local;
    proposalId = u.id;
    overrides.clear();
    deselected.clear();
    await _recompute();
  }

  void discardDraft() {
    intent = null;
    proposal = null;
    explanation = null;
    understanding = Understanding.none;
    text = '';
    notifyListeners();
  }
}
