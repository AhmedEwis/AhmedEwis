/// Preview → Confirm → Apply → Undo for "My Smart Plan".
///
/// - Preview only reads.
/// - Apply runs in one database transaction. The plan row is the idempotency claim
///   (inserted first), so a second confirm, a retry after a crash, or a second engine
///   applying the same plan is a no-op. Only the selected budgets and (optionally) one
///   goal change. Transactions are never touched and no money moves.
/// - Undo restores the exact previous values, once. A budget the user edited after the
///   plan was applied is left as the user set it.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/planner/plan_models.dart';
import '../db/database.dart';
import '../store.dart';

/// One change a plan would make. Shown in the preview, before anything is written.
class PlannedChange {
  final String entity; // budget|goal
  final String? entityId; // existing row, or null when it will be created
  final String? categoryId; // budgets: category ('*' = overall); goals: null
  final int? beforeMinor;
  final int afterMinor;
  final String actionId; // the plan action (or 'goal')
  const PlannedChange(this.entity, this.entityId, this.categoryId, this.beforeMinor, this.afterMinor, this.actionId);
}

enum ApplyOutcome { applied, alreadyApplied, alreadyUndone, nothingSelected }

class ApplyResult {
  final ApplyOutcome outcome;
  final List<PlannedChange> changes;
  const ApplyResult(this.outcome, this.changes);
}

enum UndoOutcome { undone, alreadyUndone, notApplied }

class UndoResult {
  final UndoOutcome outcome;

  /// Budgets left alone because the user changed them after the plan was applied.
  final List<String> keptUserEdits;
  const UndoResult(this.outcome, [this.keptUserEdits = const []]);
}

/// Explicit, local planner preferences. Stored on this phone only; never used to train
/// any model.
class PlannerPrefs {
  final Set<String> protectedCategories;
  const PlannerPrefs({this.protectedCategories = const {}});
  Map<String, Object?> toJson() => {'protected': protectedCategories.toList()..sort()};
  factory PlannerPrefs.fromJson(Map<String, Object?> j) => PlannerPrefs(protectedCategories: {...((j['protected'] as List?) ?? const []).cast<String>()});
}

const plannerPrefsKey = 'planner_prefs';

class PlanService {
  final FinanceStore store;

  /// Test hook: called inside the apply/undo transaction to simulate a crash.
  final void Function(String stage)? faultInjector;
  PlanService(this.store, {this.faultInjector});

  AppDatabase get db => store.db;

  Future<BudgetRow?> _budgetFor(String categoryId, String currency) async {
    final rows = await (db.select(db.budgets)
          ..where((b) =>
              b.deletedAt.isNull() &
              b.currency.equals(currency) &
              b.period.equals('cycle') &
              (categoryId == '*' ? b.categoryId.isNull() : b.categoryId.equals(categoryId))))
        .get();
    return rows.isEmpty ? null : rows.first;
  }

  String goalName(PlanProposal p) => 'Smart plan · خطتي الذكية';

  /// What applying would change. Read-only.
  Future<List<PlannedChange>> preview(PlanProposal p, {required Set<String> selected, bool createGoal = false}) async {
    final out = <PlannedChange>[];
    for (final a in p.actions) {
      if (!selected.contains(a.id)) continue;
      final b = await _budgetFor(a.categoryId, p.currency);
      if (b != null && b.amountMinor == a.limitMinor) continue;
      out.add(PlannedChange('budget', b?.id, a.categoryId, b?.amountMinor, a.limitMinor, a.id));
    }
    if (createGoal && p.intent.targetMinor != null) {
      out.add(PlannedChange('goal', null, null, null, p.intent.targetMinor!, 'goal'));
    }
    return out;
  }

  /// Applies the selected actions of [p]. Atomic and idempotent per plan id.
  Future<ApplyResult> apply(PlanProposal p, {required Set<String> selected, bool createGoal = false, Map<String, Object?>? explanation}) =>
      db.transaction(() async {
        final existing = await (db.select(db.smartPlans)..where((x) => x.id.equals(p.id))).getSingleOrNull();
        if (existing != null) {
          return ApplyResult(existing.status == 'undone' ? ApplyOutcome.alreadyUndone : ApplyOutcome.alreadyApplied, const []);
        }
        final changes = await preview(p, selected: selected, createGoal: createGoal);
        if (changes.isEmpty) return const ApplyResult(ApplyOutcome.nothingSelected, []);
        final now = store.now;
        // Claim first: the plan row makes any repeat a no-op.
        await db.into(db.smartPlans).insert(SmartPlansCompanion.insert(
              id: p.id,
              status: 'applied',
              proposalJson: _snapshot(p, selected),
              explanationJson: Value(explanation == null ? null : jsonEncode(explanation)),
              understoodBy: p.intent.understoodBy,
              currency: p.currency,
              periodStart: p.periodStart,
              periodEnd: p.periodEnd,
              appliedAt: now,
            ));
        // An earlier plan for the same cycle is superseded (its budgets stay as they are).
        await (db.update(db.smartPlans)
              ..where((x) => x.id.isNotValue(p.id) & x.status.equals('applied') & x.periodStart.equals(p.periodStart)))
            .write(SmartPlansCompanion(status: const Value('superseded'), supersededBy: Value(p.id)));
        for (final c in changes) {
          if (c.entity == 'budget') {
            final cur = c.entityId == null ? null : await (db.select(db.budgets)..where((b) => b.id.equals(c.entityId!))).getSingle();
            final row = await store.saveBudget(
              id: cur?.id,
              categoryId: c.categoryId == '*' ? null : c.categoryId,
              amountMinor: c.afterMinor,
              currency: p.currency,
              period: 'cycle',
              rollover: cur?.rollover ?? false,
              thresholds: cur?.alertThresholds ?? '80,100',
            );
            await _recordChange(p.id, 'budget', row.id, c.categoryId, created: cur == null, before: c.beforeMinor, after: c.afterMinor);
          } else {
            final g = await store.saveGoal(name: goalName(p), emoji: '🎯', targetMinor: c.afterMinor, currency: p.currency, targetDate: p.periodEnd);
            await _recordChange(p.id, 'goal', g.id, null, created: true, before: null, after: c.afterMinor);
          }
          faultInjector?.call('apply_mid');
        }
        return ApplyResult(ApplyOutcome.applied, changes);
      });

  Future<void> _recordChange(String planId, String entity, String entityId, String? categoryId, {required bool created, int? before, required int after}) =>
      db.into(db.smartPlanChanges).insert(SmartPlanChangesCompanion.insert(
            id: '$planId:$entity:$entityId',
            planId: planId,
            entity: entity,
            entityId: entityId,
            categoryId: Value(categoryId),
            created: created,
            beforeAmountMinor: Value(before),
            afterAmountMinor: after,
          ));

  String _snapshot(PlanProposal p, Set<String> selected) {
    final j = p.toJson();
    j['selected'] = selected.toList()..sort();
    return jsonEncode(j);
  }

  /// Restores what [planId] changed. Atomic and idempotent.
  Future<UndoResult> undo(String planId) => db.transaction(() async {
        final plan = await (db.select(db.smartPlans)..where((x) => x.id.equals(planId))).getSingleOrNull();
        if (plan == null) return const UndoResult(UndoOutcome.notApplied);
        if (plan.status == 'undone') return const UndoResult(UndoOutcome.alreadyUndone);
        final changes = await (db.select(db.smartPlanChanges)..where((c) => c.planId.equals(planId))).get();
        final kept = <String>[];
        for (final c in changes) {
          if (c.entity == 'budget') {
            final b = await (db.select(db.budgets)..where((x) => x.id.equals(c.entityId))).getSingleOrNull();
            if (b == null || b.deletedAt != null) continue;
            if (b.amountMinor != c.afterAmountMinor) {
              kept.add(c.categoryId ?? '*'); // the user changed it since: keep their value
              continue;
            }
            if (c.created) {
              await store.deleteBudget(b.id);
            } else {
              await store.saveBudget(
                  id: b.id, categoryId: b.categoryId, amountMinor: c.beforeAmountMinor!, currency: b.currency, period: b.period, rollover: b.rollover, thresholds: b.alertThresholds);
            }
          } else if (c.created) {
            await store.deleteGoal(c.entityId);
          }
          faultInjector?.call('undo_mid');
        }
        await (db.update(db.smartPlans)..where((x) => x.id.equals(planId))).write(SmartPlansCompanion(status: const Value('undone'), undoneAt: Value(store.now)));
        return UndoResult(UndoOutcome.undone, kept);
      });

  /// The plan applied for the cycle containing [at], if any.
  Future<SmartPlanRow?> activePlan(DateTime at) async {
    final rows = await (db.select(db.smartPlans)
          ..where((x) => x.status.equals('applied') & x.periodStart.isSmallerOrEqualValue(at) & x.periodEnd.isBiggerThanValue(at))
          ..orderBy([(x) => OrderingTerm(expression: x.appliedAt, mode: OrderingMode.desc)]))
        .get();
    return rows.isEmpty ? null : rows.first;
  }

  static PlanProposal proposalOf(SmartPlanRow r) => PlanProposal.decode(r.proposalJson);
  static Set<String> selectedOf(SmartPlanRow r) => {...(((jsonDecode(r.proposalJson) as Map)['selected'] as List?) ?? const []).cast<String>()};

  // ---- Preferences (explicit, local).
  Future<PlannerPrefs> prefs() async {
    final raw = await store.getSetting(plannerPrefsKey);
    if (raw == null) return const PlannerPrefs();
    try {
      return PlannerPrefs.fromJson((jsonDecode(raw) as Map).cast());
    } catch (_) {
      return const PlannerPrefs();
    }
  }

  Future<void> savePrefs(PlannerPrefs p) => store.setSetting(plannerPrefsKey, jsonEncode(p.toJson()));
  Future<void> resetPrefs() => (db.delete(db.settings)..where((s) => s.key.equals(plannerPrefsKey))).go();
}
