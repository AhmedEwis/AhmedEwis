import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/analytics/recurrence.dart';
import '../../core/ledger/ledger.dart';
import '../../core/money/money.dart';
import '../../core/time/kuwait_time.dart';
import '../../data/db/database.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/theme/tokens.dart';
import '../../ui/widgets/common.dart';
import '../transactions/add_transaction_sheet.dart';

enum PlanTab { budgets, recurring, goals }

class PlansScreen extends ConsumerStatefulWidget {
  const PlansScreen({super.key});
  @override
  ConsumerState<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends ConsumerState<PlansScreen> {
  PlanTab tab = PlanTab.budgets;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(children: [
                Expanded(child: Semantics(header: true, child: Text(s.navPlans, style: context.tt.displayMedium))),
                IconButton(
                  iconSize: 30,
                  color: Theme.of(context).colorScheme.primary,
                  tooltip: s.add,
                  icon: const Icon(Icons.add),
                  onPressed: () => switch (tab) {
                    PlanTab.budgets => showFSheet(context, const BudgetForm()),
                    PlanTab.goals => showFSheet(context, const GoalForm()),
                    PlanTab.recurring => showFSheet(context, const RecurringForm()),
                  },
                ),
              ]),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Segmented<PlanTab>(
                items: [(PlanTab.budgets, s.budgets), (PlanTab.recurring, s.recurring), (PlanTab.goals, s.goals)],
                value: tab,
                onChanged: (v) => setState(() => tab = v),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: switch (tab) {
              PlanTab.budgets => const BudgetsView(),
              PlanTab.recurring => const RecurringView(),
              PlanTab.goals => const GoalsView(),
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- Budgets
class BudgetsView extends ConsumerWidget {
  const BudgetsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final p = context.fp;
    final budgets = ref.watch(budgetsProvider).value ?? const <BudgetRow>[];
    final txs = ref.watch(allTxProvider).value ?? const <TxRow>[];
    final splits = ref.watch(splitsProvider).value ?? const {};
    final cats = ref.watch(categoryMapProvider);
    final settings = ref.watch(settingsProvider);
    final fmt = settings.fmt;
    final now = ref.watch(nowProvider)();
    final cycle = settings.cycle.cycleFor(now);
    if (budgets.isEmpty) {
      return EmptyState(emoji: '🎯', title: s.budgetsEmpty, action: s.addBudget, onAction: () => showFSheet(context, const BudgetForm()));
    }
    final sorted = [...budgets]..sort((a, b) => (a.categoryId == null ? 0 : 1).compareTo(b.categoryId == null ? 0 : 1));
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final b in sorted) ...[
          Builder(builder: (context) {
            final period = switch (b.period) {
              'monthly' => calendarMonth(now),
              'weekly' => Period(ReportingZone.kuwait.startOfDay(now).subtract(Duration(days: (ReportingZone.kuwait.toWall(now).weekday + 1) % 7)),
                  ReportingZone.kuwait.startOfDay(now).subtract(Duration(days: (ReportingZone.kuwait.toWall(now).weekday + 1) % 7)).add(const Duration(days: 7))),
              _ => cycle,
            };
            final used = budgetUsage(txs, period, b.currency, b.categoryId, splitsByTx: splits);
            var limit = b.amountMinor;
            if (b.rollover && b.period != 'weekly') {
              final prev = b.period == 'monthly' ? calendarMonth(period.start.subtract(const Duration(seconds: 1))) : settings.cycle.previous(period);
              if (!prev.start.isBefore(b.startDate.subtract(const Duration(days: 31)))) {
                final prevUsed = budgetUsage(txs, prev, b.currency, b.categoryId, splitsByTx: splits);
                if (prev.end.isAfter(b.startDate)) limit += (b.amountMinor - prevUsed).clamp(0, b.amountMinor);
              }
            }
            final ratio = limit == 0 ? 0.0 : used / limit;
            final c = b.categoryId == null ? null : cats[b.categoryId];
            final thresholds = b.alertThresholds.split(',').map(int.tryParse).whereType<int>().toList();
            final crossed = thresholds.where((t) => ratio * 100 >= t).fold<int?>(null, (m, t) => m == null || t > m ? t : m);
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: FCard(
                onTap: () => showFSheet(context, BudgetForm(existing: b)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    CategoryTile(emoji: c?.icon ?? '💼', color: Color(c?.color ?? 0xFF0B7A8F), size: 40),
                    const SizedBox(width: 12),
                    Expanded(child: Text(c == null ? s.overallBudget : (s.ar ? c.nameAr : c.nameEn), style: context.tt.titleMedium)),
                    if (crossed != null) Pill('$crossed%', bg: ratio >= 1 ? p.negativeBg : p.warningBg, fg: ratio >= 1 ? p.negative : p.warning, icon: Icons.notifications_active_outlined),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Directionality(textDirection: TextDirection.ltr, child: Text(fmt.money(used, b.currency), style: context.tt.titleLarge)),
                    Text('  / ${fmt.money(limit, b.currency)}', style: context.tt.bodyMedium?.copyWith(color: p.inkSecondary)),
                  ]),
                  const SizedBox(height: 8),
                  FProgress(value: ratio),
                  const SizedBox(height: 6),
                  Text(used <= limit ? s.left(fmt.money(limit - used, b.currency)) : s.over(fmt.money(used - limit, b.currency)),
                      style: context.tt.bodySmall?.copyWith(color: used <= limit ? p.inkSecondary : p.negative)),
                ]),
              ),
            );
          }),
        ],
        Text(s.budgetNote, style: context.tt.bodySmall?.copyWith(color: p.inkSecondary)),
      ]),
    );
  }
}

class BudgetForm extends ConsumerStatefulWidget {
  final BudgetRow? existing;
  const BudgetForm({super.key, this.existing});
  @override
  ConsumerState<BudgetForm> createState() => _BudgetFormState();
}

class _BudgetFormState extends ConsumerState<BudgetForm> {
  String? categoryId;
  late final amount = TextEditingController(text: widget.existing == null ? '' : Money(widget.existing!.amountMinor, widget.existing!.currency).toDecimalString());
  String period = 'cycle';
  bool rollover = false;
  Set<int> thresholds = {80, 100};
  String? error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      categoryId = e.categoryId;
      period = e.period;
      rollover = e.rollover;
      thresholds = e.alertThresholds.split(',').map(int.tryParse).whereType<int>().toSet();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final cats = (ref.watch(categoriesProvider).value ?? const <CategoryRow>[]).where((c) => c.kind == 'expense').toList();
    final base = ref.watch(settingsProvider).baseCurrency;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.existing == null ? s.addBudget : s.edit, style: context.tt.titleLarge),
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          initialValue: categoryId,
          decoration: InputDecoration(labelText: s.category),
          items: [
            DropdownMenuItem(value: null, child: Text('💼 ${s.overallBudget}')),
            for (final c in cats) DropdownMenuItem(value: c.id, child: Text('${c.icon} ${s.ar ? c.nameAr : c.nameEn}')),
          ],
          onChanged: (v) => setState(() => categoryId = v),
        ),
        const SizedBox(height: 12),
        TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: '${s.limit} ($base)')),
        const SizedBox(height: 12),
        Segmented<String>(
          items: [('cycle', s.thisCycle), ('monthly', s.cadenceMonthly), ('weekly', s.cadenceWeekly)],
          value: period,
          onChanged: (v) => setState(() => period = v),
        ),
        SwitchListTile(value: rollover, onChanged: period == 'weekly' ? null : (v) => setState(() => rollover = v), title: Text(s.rollover), contentPadding: EdgeInsets.zero),
        Text(s.alertsAt, style: context.tt.titleSmall),
        Wrap(spacing: 8, children: [
          for (final t in [50, 80, 90, 100])
            FilterChip(label: Text('$t%'), selected: thresholds.contains(t), onSelected: (v) => setState(() => v ? thresholds.add(t) : thresholds.remove(t))),
        ]),
        if (error != null) Text(error!, style: TextStyle(color: context.fp.negative)),
        const SizedBox(height: 16),
        Row(children: [
          if (widget.existing != null)
            TextButton(
              onPressed: () async {
                await ref.read(storeProvider).deleteBudget(widget.existing!.id);
                if (context.mounted) Navigator.pop(context);
              },
              child: Text(s.delete, style: TextStyle(color: context.fp.negative)),
            ),
          const Spacer(),
          FilledButton(
            onPressed: () async {
              final m = Money.parse(amount.text, base);
              if (m == null || m.minor <= 0) return setState(() => error = s.invalidAmount);
              await ref.read(storeProvider).saveBudget(
                    id: widget.existing?.id,
                    categoryId: categoryId,
                    amountMinor: m.minor,
                    currency: base,
                    period: period,
                    rollover: rollover,
                    thresholds: (thresholds.toList()..sort()).join(','),
                  );
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(s.save),
          ),
        ]),
      ]),
    );
  }
}

// ---------------------------------------------------------------- Recurring
class RecurringView extends ConsumerWidget {
  const RecurringView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final p = context.fp;
    final items = ref.watch(recurringProvider).value ?? const <RecurringRow>[];
    final txs = ref.watch(allTxProvider).value ?? const <TxRow>[];
    final settings = ref.watch(settingsProvider);
    final fmt = settings.fmt;
    final base = settings.baseCurrency;
    final now = ref.watch(nowProvider)();
    final active = items.where((r) => r.status == 'active' && r.kind != 'salary').toList();
    final tracked = items.map((r) => (r.merchantPattern ?? r.name).toLowerCase()).toSet();
    final suggestions = detectRecurring(txs, alreadyTracked: tracked, now: now);
    final perMonth = active.where((r) => r.currency == base).fold<int>(0, (s0, r) => s0 + monthlyEquivalent(r));
    final installments = active.where((r) => r.kind == 'installment').toList();
    final remaining = installments.fold<int>(0, (s0, r) => s0 + (r.totalOccurrences == null ? 0 : (r.totalOccurrences! - r.completedOccurrences) * r.amountMinor));

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Color(0xFF5B5BD6), Color(0xFF7C6CF0)]),
            borderRadius: BorderRadius.circular(FilsRadius.xl),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.perMonth, style: context.tt.bodyMedium?.copyWith(color: Colors.white70)),
            Directionality(textDirection: TextDirection.ltr, child: Text(fmt.money(perMonth, base), style: context.tt.displayMedium?.copyWith(color: Colors.white))),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _StatBox(value: '${active.length}', label: s.activeN(active.length))),
              const SizedBox(width: 10),
              Expanded(child: _StatBox(value: fmt.money(remaining, base), label: s.ar ? 'المتبقي من الأقساط' : 'Installments remaining')),
            ]),
          ]),
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(s.suggested, style: context.tt.titleMedium),
          Text(s.suggestedBody, style: context.tt.bodySmall?.copyWith(color: p.inkSecondary)),
          const SizedBox(height: 8),
          for (final sug in suggestions.take(5))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FCard(
                child: Row(children: [
                  const CategoryTile(emoji: '🔁', color: Color(0xFF7C3AED), size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(sug.merchant, style: context.tt.titleSmall),
                      Text('${fmt.money(sug.typicalAmountMinor, sug.currency)} · ${sug.cadence == 'monthly' ? s.cadenceMonthly : (sug.cadence == 'weekly' ? s.cadenceWeekly : s.cadenceYearly)} · ×${sug.occurrences}',
                          style: context.tt.bodySmall?.copyWith(color: p.inkSecondary)),
                    ]),
                  ),
                  TextButton(
                    onPressed: () => ref.read(storeProvider).saveRecurring(RecurringsCompanion.insert(
                          id: '',
                          name: sug.merchant,
                          kind: sug.categoryId == 'subscriptions' ? 'subscription' : (sug.categoryId == 'installments' ? 'installment' : 'bill'),
                          amountMinor: sug.typicalAmountMinor,
                          currency: sug.currency,
                          accountId: Value(sug.accountId),
                          categoryId: Value(sug.categoryId),
                          cadence: sug.cadence,
                          anchorDate: sug.lastDate,
                          nextDueDate: sug.nextDate,
                          merchantPattern: Value(sug.merchant),
                          status: 'active',
                          updatedAt: now,
                        ).copyWith(id: const Value.absent())),
                    child: Text(s.confirmRecurring),
                  ),
                ]),
              ),
            ),
        ],
        const SizedBox(height: 20),
        Text(s.upcoming, style: context.tt.titleMedium),
        const SizedBox(height: 8),
        if (active.isEmpty) EmptyState(emoji: '📅', title: s.recurringEmpty, action: s.addRecurring, onAction: () => showFSheet(context, const RecurringForm())),
        for (final r in active)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FCard(
              onTap: () => showFSheet(context, RecurringForm(existing: r)),
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(children: [
                Container(width: 4, height: 44, decoration: BoxDecoration(color: _kindColor(r.kind), borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(r.name, style: context.tt.titleSmall),
                    Text(
                      [
                        _kindLabel(s, r.kind),
                        if (r.totalOccurrences != null) s.paymentsProgress(r.completedOccurrences, r.totalOccurrences!),
                      ].join(' · '),
                      style: context.tt.bodySmall?.copyWith(color: p.inkSecondary),
                    ),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Directionality(textDirection: TextDirection.ltr, child: Text(fmt.money(r.amountMinor, r.currency), style: context.tt.titleSmall)),
                  Text(s.inDays(r.nextDueDate.difference(ReportingZone.kuwait.startOfDay(now)).inDays.clamp(0, 9999)),
                      style: context.tt.bodySmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
                ]),
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    final store = ref.read(storeProvider);
                    if (v == 'paid') {
                      // Advancing the schedule doesn't create a transaction: the real payment
                      // arrives via capture or manual entry, so it is counted once.
                      final done = r.completedOccurrences + 1;
                      await store.saveRecurring(RecurringsCompanion(
                        id: Value(r.id),
                        name: Value(r.name),
                        kind: Value(r.kind),
                        amountMinor: Value(r.amountMinor),
                        currency: Value(r.currency),
                        cadence: Value(r.cadence),
                        anchorDate: Value(r.anchorDate),
                        nextDueDate: Value(addCadence(r.nextDueDate, r.cadence, r.interval)),
                        completedOccurrences: Value(done),
                        status: Value(r.totalOccurrences != null && done >= r.totalOccurrences! ? 'ended' : 'active'),
                        accountId: Value(r.accountId),
                        categoryId: Value(r.categoryId),
                        totalOccurrences: Value(r.totalOccurrences),
                        merchantPattern: Value(r.merchantPattern),
                        reminderDaysBefore: Value(r.reminderDaysBefore),
                        interval: Value(r.interval),
                        version: Value(r.version),
                      ));
                    } else if (v == 'record' && context.mounted) {
                      await showAddTransactionSheet(context, ref,
                          draft: TxDraft(amountMinor: r.amountMinor, currency: r.currency, merchant: r.name, categoryId: r.categoryId, accountId: r.accountId, source: 'recurring'));
                    } else if (v == 'pause') {
                      await store.setRecurringStatus(r.id, 'paused');
                    } else if (v == 'delete') {
                      await store.deleteRecurring(r.id);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'paid', child: Text(s.markPaid)),
                    PopupMenuItem(value: 'record', child: Text(s.ar ? 'تسجيل دفعة يدوية' : 'Record a manual payment')),
                    PopupMenuItem(value: 'pause', child: Text(s.ar ? 'إيقاف مؤقت' : 'Pause')),
                    PopupMenuItem(value: 'delete', child: Text(s.delete)),
                  ],
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}

Color _kindColor(String k) => switch (k) {
      'installment' => const Color(0xFF7C3AED),
      'subscription' => const Color(0xFFDB2777),
      'rent' => const Color(0xFF0B7A8F),
      'bill' => const Color(0xFFF59E0B),
      _ => const Color(0xFF64748B),
    };

String _kindLabel(S s, String k) => switch (k) {
      'installment' => s.kindInstallment,
      'subscription' => s.kindSubscription,
      'rent' => s.kindRent,
      'bill' => s.kindBill,
      'salary' => s.kindSalary,
      _ => s.kindOther,
    };

class _StatBox extends StatelessWidget {
  final String value;
  final String label;
  const _StatBox({required this.value, required this.label});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(FilsRadius.md)),
        child: Column(children: [
          FittedBox(child: Directionality(textDirection: TextDirection.ltr, child: Text(value, style: context.tt.titleMedium?.copyWith(color: Colors.white)))),
          Text(label, style: context.tt.bodySmall?.copyWith(color: Colors.white70), maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      );
}

class RecurringForm extends ConsumerStatefulWidget {
  final RecurringRow? existing;
  const RecurringForm({super.key, this.existing});
  @override
  ConsumerState<RecurringForm> createState() => _RecurringFormState();
}

class _RecurringFormState extends ConsumerState<RecurringForm> {
  late final name = TextEditingController(text: widget.existing?.name ?? '');
  late final amount = TextEditingController(text: widget.existing == null ? '' : Money(widget.existing!.amountMinor, widget.existing!.currency).toDecimalString());
  late final total = TextEditingController(text: widget.existing?.totalOccurrences?.toString() ?? '');
  late String kind = widget.existing?.kind ?? 'subscription';
  late String cadence = widget.existing?.cadence ?? 'monthly';
  late DateTime next = widget.existing?.nextDueDate ?? DateTime.now().toUtc().add(const Duration(days: 7));
  late int remind = widget.existing?.reminderDaysBefore ?? 1;
  String? error;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final settings = ref.watch(settingsProvider);
    final base = widget.existing?.currency ?? settings.baseCurrency;
    final fmt = settings.fmt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.existing == null ? s.addRecurring : s.edit, style: context.tt.titleLarge),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          for (final k in ['subscription', 'installment', 'rent', 'bill', 'salary', 'other'])
            ChoiceChip(label: Text(_kindLabel(s, k)), selected: kind == k, onSelected: (_) => setState(() => kind = k)),
        ]),
        const SizedBox(height: 12),
        TextField(controller: name, decoration: InputDecoration(labelText: s.ar ? 'الاسم' : 'Name')),
        const SizedBox(height: 12),
        TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: '${s.amount} ($base)')),
        const SizedBox(height: 12),
        Segmented<String>(items: [('weekly', s.cadenceWeekly), ('monthly', s.cadenceMonthly), ('yearly', s.cadenceYearly)], value: cadence, onChanged: (v) => setState(() => cadence = v)),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.event),
          label: Text('${s.nextDue}: ${fmt.dayMonthYear(ReportingZone.kuwait.toWall(next))}'),
          onPressed: () async {
            final w = ReportingZone.kuwait.toWall(next);
            final d = await showDatePicker(context: context, initialDate: w, firstDate: DateTime(2015), lastDate: DateTime(2100));
            if (d != null) setState(() => next = ReportingZone.kuwait.fromWall(d.year, d.month, d.day, 9));
          },
        ),
        if (kind == 'installment') ...[
          const SizedBox(height: 12),
          TextField(controller: total, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: s.ar ? 'عدد الدفعات الكلي' : 'Total number of payments')),
        ],
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: Text(s.remindDaysBefore)),
          DropdownButton<int>(value: remind, items: [for (final d in [0, 1, 2, 3, 5, 7]) DropdownMenuItem(value: d, child: Text('$d'))], onChanged: (v) => setState(() => remind = v!)),
        ]),
        if (error != null) Text(error!, style: TextStyle(color: context.fp.negative)),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () async {
            final m = Money.parse(amount.text, base);
            if (name.text.trim().isEmpty) return setState(() => error = s.required);
            if (m == null || m.minor <= 0) return setState(() => error = s.invalidAmount);
            final e = widget.existing;
            await ref.read(storeProvider).saveRecurring(RecurringsCompanion(
                  id: e == null ? const Value.absent() : Value(e.id),
                  name: Value(name.text.trim()),
                  kind: Value(kind),
                  amountMinor: Value(m.minor),
                  currency: Value(base),
                  cadence: Value(cadence),
                  anchorDate: Value(e?.anchorDate ?? next),
                  nextDueDate: Value(next),
                  totalOccurrences: Value(int.tryParse(total.text)),
                  completedOccurrences: Value(e?.completedOccurrences ?? 0),
                  merchantPattern: Value(e?.merchantPattern ?? name.text.trim()),
                  status: Value(e?.status ?? 'active'),
                  reminderDaysBefore: Value(remind),
                  accountId: Value(e?.accountId),
                  categoryId: Value(e?.categoryId ?? (kind == 'installment' ? 'installments' : (kind == 'subscription' ? 'subscriptions' : (kind == 'rent' ? 'housing' : 'bills')))),
                  version: Value(e?.version ?? 0),
                ));
            if (context.mounted) Navigator.pop(context);
          },
          child: Text(s.save),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- Goals
class GoalsView extends ConsumerWidget {
  const GoalsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final p = context.fp;
    final goals = ref.watch(goalsProvider).value ?? const <GoalRow>[];
    final contribs = ref.watch(contributionsProvider).value ?? const <GoalContributionRow>[];
    final settings = ref.watch(settingsProvider);
    final fmt = settings.fmt;
    final now = ref.watch(nowProvider)();
    if (goals.isEmpty) return EmptyState(emoji: '🎯', title: s.goalsEmpty, action: s.addGoal, onAction: () => showFSheet(context, const GoalForm()));
    final base = settings.baseCurrency;
    final totalSaved = goals.where((g) => g.currency == base).fold<int>(0, (a, g) => a + projectGoal(g, contribs, now).saved);
    final totalTarget = goals.where((g) => g.currency == base).fold<int>(0, (a, g) => a + g.targetMinor);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.totalSaved, style: context.tt.labelMedium?.copyWith(color: p.inkSecondary)),
            Directionality(textDirection: TextDirection.ltr, child: Text(fmt.money(totalSaved, base), style: context.tt.headlineMedium)),
            const SizedBox(height: 8),
            FProgress(value: totalTarget == 0 ? 0 : totalSaved / totalTarget, color: const Color(0xFFD4A017)),
            const SizedBox(height: 4),
            Text('${fmt.percent(totalTarget == 0 ? 0 : totalSaved / totalTarget)} · ${fmt.money(totalTarget, base)}', style: context.tt.bodySmall?.copyWith(color: p.inkSecondary)),
          ]),
        ),
        const SizedBox(height: 16),
        for (final g in goals)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Builder(builder: (context) {
              final pr = projectGoal(g, contribs, now);
              final ratio = g.targetMinor == 0 ? 0.0 : pr.saved / g.targetMinor;
              return FCard(
                onTap: () => showFSheet(context, GoalDetail(goal: g)),
                child: Row(children: [
                  SizedBox(
                    width: 52,
                    height: 52,
                    child: Stack(alignment: Alignment.center, children: [
                      CircularProgressIndicator(value: ratio.clamp(0, 1).toDouble(), strokeWidth: 5, backgroundColor: p.surfaceMuted, color: const Color(0xFFD4A017)),
                      Text(g.emoji ?? '🎯', style: const TextStyle(fontSize: 22)),
                    ]),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(g.name, style: context.tt.titleSmall),
                      Text('${fmt.money(pr.saved, g.currency)} / ${fmt.money(g.targetMinor, g.currency)}', style: context.tt.bodySmall?.copyWith(color: p.inkSecondary)),
                      if (pr.neededPerMonthForDate != null && pr.remaining > 0)
                        Text(s.needsPerMonth(fmt.money(pr.neededPerMonthForDate!, g.currency)), style: context.tt.bodySmall?.copyWith(color: p.negative)),
                    ]),
                  ),
                  Text(fmt.percent(ratio), style: context.tt.titleSmall),
                ]),
              );
            }),
          ),
        Text(s.goalAssumption, style: context.tt.bodySmall?.copyWith(color: p.inkSecondary)),
      ]),
    );
  }
}

class GoalForm extends ConsumerStatefulWidget {
  final GoalRow? existing;
  const GoalForm({super.key, this.existing});
  @override
  ConsumerState<GoalForm> createState() => _GoalFormState();
}

class _GoalFormState extends ConsumerState<GoalForm> {
  late final name = TextEditingController(text: widget.existing?.name ?? '');
  late final target = TextEditingController(text: widget.existing == null ? '' : Money(widget.existing!.targetMinor, widget.existing!.currency).toDecimalString());
  late final monthly = TextEditingController(
      text: widget.existing?.plannedMonthlyMinor == null ? '' : Money(widget.existing!.plannedMonthlyMinor!, widget.existing!.currency).toDecimalString());
  late String emoji = widget.existing?.emoji ?? '🎯';
  late DateTime? date = widget.existing?.targetDate;
  String? error;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final settings = ref.watch(settingsProvider);
    final base = widget.existing?.currency ?? settings.baseCurrency;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.existing == null ? s.addGoal : s.edit, style: context.tt.titleLarge),
        const SizedBox(height: 12),
        Wrap(spacing: 6, children: [
          for (final e in ['🎯', '🚗', '🏠', '✈️', '💍', '🎓', '🕋', '🛟', '📱', '🏖️'])
            ChoiceChip(label: Text(e, style: const TextStyle(fontSize: 18)), selected: emoji == e, onSelected: (_) => setState(() => emoji = e)),
        ]),
        const SizedBox(height: 12),
        TextField(controller: name, decoration: InputDecoration(labelText: s.goalName)),
        const SizedBox(height: 12),
        TextField(controller: target, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: '${s.targetAmount} ($base)')),
        const SizedBox(height: 12),
        TextField(controller: monthly, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: s.plannedMonthly)),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.event),
          label: Text(date == null ? s.targetDate : '${s.targetDate}: ${settings.fmt.dayMonthYear(date!)}'),
          onPressed: () async {
            final now = DateTime.now();
            final d = await showDatePicker(context: context, initialDate: date ?? now.add(const Duration(days: 365)), firstDate: now, lastDate: DateTime(now.year + 40));
            if (d != null) setState(() => date = DateTime.utc(d.year, d.month, d.day));
          },
        ),
        if (error != null) Text(error!, style: TextStyle(color: context.fp.negative)),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () async {
            final t = Money.parse(target.text, base);
            if (name.text.trim().isEmpty) return setState(() => error = s.required);
            if (t == null || t.minor <= 0) return setState(() => error = s.invalidAmount);
            final m = monthly.text.trim().isEmpty ? null : Money.parse(monthly.text, base);
            await ref.read(storeProvider).saveGoal(
                  id: widget.existing?.id,
                  name: name.text.trim(),
                  emoji: emoji,
                  targetMinor: t.minor,
                  currency: base,
                  targetDate: date,
                  plannedMonthlyMinor: m?.minor,
                );
            if (context.mounted) Navigator.pop(context);
          },
          child: Text(s.save),
        ),
      ]),
    );
  }
}

class GoalDetail extends ConsumerWidget {
  final GoalRow goal;
  const GoalDetail({super.key, required this.goal});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final p = context.fp;
    final contribs = (ref.watch(contributionsProvider).value ?? const <GoalContributionRow>[]).where((c) => c.goalId == goal.id).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final fmt = ref.watch(settingsProvider).fmt;
    final now = ref.watch(nowProvider)();
    final pr = projectGoal(goal, contribs, now);
    String? paceText;
    if (pr.monthsAtPlannedPace != null) {
      final d = DateTime.utc(now.year, now.month + pr.monthsAtPlannedPace!, 1);
      paceText = s.reachBy(fmt.monthYear(d));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(child: Text(goal.emoji ?? '🎯', style: const TextStyle(fontSize: 48))),
        Center(child: Text(goal.name, style: context.tt.titleLarge)),
        const SizedBox(height: 8),
        Center(child: Directionality(textDirection: TextDirection.ltr, child: Text(fmt.money(pr.saved, goal.currency), style: context.tt.displayMedium))),
        Center(
          child: Text(
            '${s.ar ? 'من' : 'of'} ${fmt.money(goal.targetMinor, goal.currency)}${pr.monthsUntilTarget != null ? ' · ${pr.monthsUntilTarget} ${s.ar ? 'شهر متبقي' : 'months to go'}' : ''}',
            style: context.tt.bodyMedium?.copyWith(color: p.inkSecondary),
          ),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: p.negative), onPressed: () => _contribute(context, ref, 1), icon: const Icon(Icons.add), label: Text(s.addMoney))),
          const SizedBox(width: 10),
          Expanded(child: OutlinedButton.icon(onPressed: () => _contribute(context, ref, -1), icon: const Icon(Icons.south), label: Text(s.takeOut))),
        ]),
        const SizedBox(height: 10),
        if (pr.neededPerMonthForDate != null && pr.remaining > 0) Text(s.needsPerMonth(fmt.money(pr.neededPerMonthForDate!, goal.currency)), textAlign: TextAlign.center, style: TextStyle(color: p.negative)),
        if (paceText != null) Text(paceText, textAlign: TextAlign.center, style: context.tt.bodySmall),
        Text(s.goalAssumption, textAlign: TextAlign.center, style: context.tt.bodySmall?.copyWith(color: p.inkSecondary)),
        const SizedBox(height: 16),
        Text(s.ar ? 'المساهمات' : 'CONTRIBUTIONS', style: context.tt.labelSmall?.copyWith(color: p.inkSecondary)),
        for (final c in contribs)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(c.amountMinor >= 0 ? Icons.add_circle_outline : Icons.remove_circle_outline, color: c.amountMinor >= 0 ? p.positive : p.negative),
            title: Directionality(textDirection: TextDirection.ltr, child: Text(fmt.money(c.amountMinor, goal.currency, signed: true), textAlign: TextAlign.start)),
            subtitle: Text('${fmt.dayMonthYear(ReportingZone.kuwait.toWall(c.date))}${c.note != null ? ' · ${c.note}' : ''}'),
          ),
        const SizedBox(height: 8),
        Row(children: [
          TextButton(onPressed: () => showFSheet(context, GoalForm(existing: goal)), child: Text(s.edit)),
          const Spacer(),
          TextButton(
            onPressed: () async {
              await ref.read(storeProvider).archiveGoal(goal.id);
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(s.archive),
          ),
        ]),
      ]),
    );
  }

  Future<void> _contribute(BuildContext context, WidgetRef ref, int sign) async {
    final s = S.of(context);
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(sign > 0 ? s.addMoney : s.takeOut),
        content: TextField(controller: ctrl, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: s.amount)),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.save))],
      ),
    );
    if (ok != true) return;
    final m = Money.parse(ctrl.text, goal.currency);
    if (m == null || m.minor <= 0) return;
    await ref.read(storeProvider).addContribution(goal.id, sign * m.minor);
  }
}
