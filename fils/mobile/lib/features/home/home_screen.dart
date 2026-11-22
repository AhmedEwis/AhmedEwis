import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/ledger/ledger.dart';
import '../../core/time/kuwait_time.dart';
import '../../data/db/database.dart';
import '../../data/store.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/theme/tokens.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/tx_tile.dart';
import '../accounts/account_widgets.dart';
import '../transactions/add_transaction_sheet.dart';
import 'period_sheet.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final p = context.fp;
    final settings = ref.watch(settingsProvider);
    final fmt = settings.fmt;
    final base = settings.baseCurrency;
    final period = ref.watch(periodProvider);
    final totals = ref.watch(periodTotalsProvider);
    final accounts = ref.watch(accountsProvider).value ?? const <AccountRow>[];
    final balances = ref.watch(balancesProvider);
    final txs = ref.watch(allTxProvider).value ?? const <TxRow>[];
    final cats = ref.watch(categoryMapProvider);
    final reviewCount = ref.watch(reviewCountProvider).value ?? 0;
    final selectedAcct = ref.watch(selectedAccountProvider);
    final acctMap = {for (final a in accounts) a.id: a};

    final now = ref.watch(nowProvider)();
    final todayP = Period(ReportingZone.kuwait.startOfDay(now), ReportingZone.kuwait.startOfDay(now).add(const Duration(days: 1)));
    final todaySpent = totalsFor(txs, todayP, accountIds: selectedAcct == null ? null : {selectedAcct}).spentIn(base);

    final scoped = accounts.where((a) => selectedAcct == null || a.id == selectedAcct).where((a) => a.currency == base);
    final assetBal = scoped.where((a) => !a.isLiability).fold<int>(0, (s0, a) => s0 + (balances[a.id] ?? 0));
    final owed = scoped.where((a) => a.isLiability).fold<int>(0, (s0, a) => s0 + (balances[a.id] ?? 0));
    final otherCur = totals.spent.entries.where((e) => e.key != base && e.value != 0).map((e) => fmt.money(e.value, e.key)).join(' · ');

    final recent = [...txs]..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    final recentShown = recent.where((t) => selectedAcct == null || t.accountId == selectedAcct || t.counterAccountId == selectedAcct).take(6).toList();

    return Scaffold(
      body: Stack(
        children: [
          // Gradient hero background
          Container(
            height: 640,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [p.heroTop, Color.lerp(p.heroTop, p.heroBottom, 0.55)!, p.heroBottom],
                stops: const [0, 0.62, 1],
              ),
            ),
          ),
          CustomScrollView(
            slivers: [
              SliverSafeArea(
                bottom: false,
                sliver: SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: FilsSpace.gutter),
                    child: Column(
                      children: [
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            _HeroIconButton(
                              label: s.settings,
                              onTap: () => context.push('/settings'),
                              child: Text(settings.demoMode ? 'D' : '👤', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18)),
                              dot: reviewCount > 0,
                            ),
                            const Spacer(),
                            _PeriodPill(label: periodLabel(context, ref, period), onTap: () => showPeriodSheet(context, ref)),
                            const Spacer(),
                            _HeroIconButton(label: s.insights, onTap: () => context.push('/insights'), child: const Icon(Icons.show_chart_rounded, color: Colors.white)),
                          ],
                        ),
                        if (settings.demoMode) Padding(padding: const EdgeInsets.only(top: 8), child: Pill(s.demoBadge, bg: Colors.white24, fg: Colors.white)),
                        const SizedBox(height: 26),
                        Text(s.spent, style: context.tt.titleMedium?.copyWith(color: Colors.white70, fontWeight: FontWeight.w500)),
                        const SizedBox(height: 4),
                        Semantics(
                          label: '${s.spent} ${fmt.money(totals.spentIn(base), base)}',
                          excludeSemantics: true,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Directionality(
                              textDirection: TextDirection.ltr,
                              child: Text(fmt.money(totals.spentIn(base), base),
                                  style: context.tt.displayLarge?.copyWith(color: Colors.white, fontSize: 50)),
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(context.isRtl ? Icons.subdirectory_arrow_left : Icons.subdirectory_arrow_right, size: 16, color: Colors.white.withValues(alpha: 0.9)),
                          const SizedBox(width: 2),
                          Text(s.todayAmount(fmt.money(todaySpent, base)), style: context.tt.titleSmall?.copyWith(color: Colors.white.withValues(alpha: 0.9))),
                        ]),
                        if (otherCur.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(s.otherCurrencies(otherCur), style: context.tt.bodySmall?.copyWith(color: Colors.white70), textAlign: TextAlign.center),
                          ),
                        const SizedBox(height: 18),
                        TextButton(
                          onPressed: () => showAccountFilterSheet(context, ref),
                          style: TextButton.styleFrom(foregroundColor: Colors.white),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(selectedAcct == null ? s.allAccounts : (acctMap[selectedAcct]?.name ?? s.allAccounts), style: context.tt.titleMedium?.copyWith(color: Colors.white)),
                            const SizedBox(width: 4),
                            const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white),
                          ]),
                        ),
                        Semantics(
                          label: '${s.balance} ${fmt.money(assetBal, base)}. ${s.calculatedBalanceNote}',
                          excludeSemantics: true,
                          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Text('${s.balance}  ', style: context.tt.bodyLarge?.copyWith(color: Colors.white70)),
                            Directionality(
                              textDirection: TextDirection.ltr,
                              child: Text(fmt.money(assetBal, base), style: context.tt.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
                            ),
                          ]),
                        ),
                        if (owed < 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(s.youOwe(fmt.money(-owed, base)), style: context.tt.bodyMedium?.copyWith(color: Colors.white70)),
                          ),
                        const SizedBox(height: 26),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            CircleAction(icon: Icons.add_rounded, label: s.add, onTap: () => showAddTransactionSheet(context, ref)),
                            CircleAction(icon: Icons.mic_none_rounded, label: s.voice, onTap: () => context.push('/voice')),
                            CircleAction(icon: Icons.download_rounded, label: s.import, onTap: () => context.push('/capture')),
                            CircleAction(icon: Icons.more_horiz_rounded, label: s.more, onTap: () => _showMore(context), badge: reviewCount > 0 ? '$reviewCount' : null),
                          ],
                        ),
                        const SizedBox(height: 36),
                      ],
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(child: _StatusCards(reviewCount: reviewCount)),
              SliverToBoxAdapter(child: PaydayCard()),
              SliverToBoxAdapter(child: SectionHeader(s.accounts, action: s.seeAll, onAction: () => context.push('/accounts'))),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 116,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: FilsSpace.gutter),
                    children: [
                      AccountMiniCard(
                        title: s.allAccounts,
                        amount: fmt.money(assetBal + owed, base),
                        leading: const CategoryTile(emoji: '💳', color: Color(0xFF0B7A8F), size: 38),
                        emphasized: true,
                        onTap: () => context.push('/accounts'),
                      ),
                      for (final a in accounts)
                        AccountMiniCard(
                          title: a.name,
                          amount: fmt.money(balances[a.id] ?? 0, a.currency),
                          leading: accountBadge(a, size: 38),
                          onTap: () => context.push('/accounts/${a.id}'),
                        ),
                      AccountMiniCard(
                        title: s.addAccount,
                        amount: '',
                        leading: Icon(Icons.add_circle_outline, color: Theme.of(context).colorScheme.primary, size: 34),
                        onTap: () => context.push('/accounts/new'),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: SectionHeader(s.recentTransactions, action: s.viewAll(txs.length), onAction: () => context.push('/transactions')),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: FilsSpace.gutter),
                  child: FCard(
                    padding: EdgeInsets.zero,
                    child: recentShown.isEmpty
                        ? EmptyState(emoji: '🧾', title: s.noTransactions, body: s.noTransactionsBody, action: s.setUp, onAction: () => context.push('/capture'))
                        : Column(children: [
                            for (var i = 0; i < recentShown.length; i++) ...[
                              if (i > 0) const Divider(indent: 78),
                              TxTile(t: recentShown[i], cats: cats, accounts: acctMap, fmt: fmt, onTap: () => context.push('/transactions/${recentShown[i].id}')),
                            ],
                          ]),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 120)),
            ],
          ),
        ],
      ),
    );
  }

  void _showMore(BuildContext context) {
    final s = S.of(context);
    showFSheet(
      context,
      SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _MoreTile(icon: Icons.inbox_outlined, label: s.reviewInbox, onTap: () => context.push('/review')),
          _MoreTile(icon: Icons.receipt_long_outlined, label: s.transactions, onTap: () => context.push('/transactions')),
          _MoreTile(icon: Icons.account_balance_outlined, label: s.accounts, onTap: () => context.push('/accounts')),
          _MoreTile(icon: Icons.bolt_outlined, label: s.captureSetup, onTap: () => context.push('/capture')),
          _MoreTile(icon: Icons.insights_outlined, label: s.insights, onTap: () => context.push('/insights')),
          _MoreTile(icon: Icons.group_outlined, label: s.household, onTap: () => context.push('/household')),
          _MoreTile(icon: Icons.settings_outlined, label: s.settings, onTap: () => context.push('/settings')),
          const SizedBox(height: 12),
        ]),
      ),
    );
  }
}

class _MoreTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _MoreTile({required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon),
        title: Text(label),
        onTap: () {
          Navigator.of(context).pop();
          onTap();
        },
      );
}

class _HeroIconButton extends StatelessWidget {
  final Widget child;
  final String label;
  final VoidCallback onTap;
  final bool dot;
  const _HeroIconButton({required this.child, required this.label, required this.onTap, this.dot = false});

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Stack(children: [
            Container(
              width: 50,
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
              child: child,
            ),
            if (dot)
              PositionedDirectional(
                top: 4,
                end: 4,
                child: Container(width: 11, height: 11, decoration: BoxDecoration(color: context.fp.negative, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 1.5))),
              ),
          ]),
        ),
      );
}

class _PeriodPill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PeriodPill({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(FilsRadius.pill),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 46),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(FilsRadius.pill)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: context.tt.titleMedium?.copyWith(color: Colors.white)),
              const SizedBox(width: 6),
              const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white),
            ]),
          ),
        ),
      );
}

/// Capture status + review prompt.
class _StatusCards extends ConsumerWidget {
  final int reviewCount;
  const _StatusCards({required this.reviewCount});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final p = context.fp;
    final settings = ref.watch(settingsProvider);
    final lastAt = DateTime.tryParse(settings.raw[SettingKeys.lastCaptureAt] ?? '');
    final src = settings.raw[SettingKeys.lastCaptureSource];
    final fmt = settings.fmt;
    String status;
    if (lastAt == null) {
      status = s.neverCaptured;
    } else {
      final w = ReportingZone.kuwait.toWall(lastAt);
      status = s.lastCaptured('${fmt.dayMonth(w)} ${fmt.time(w)}${src != null ? ' · $src' : ''}');
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(FilsSpace.gutter, 0, FilsSpace.gutter, 0),
      child: Column(children: [
        FCard(
          onTap: () => context.push('/capture'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            Icon(Icons.bolt_rounded, color: lastAt == null ? p.warning : p.positive),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.captureStatus, style: context.tt.titleSmall),
                Text(status, style: context.tt.bodySmall?.copyWith(color: p.inkSecondary)),
              ]),
            ),
            if (lastAt == null) Text(s.setUp, style: context.tt.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
            Icon(context.isRtl ? Icons.chevron_left : Icons.chevron_right, color: p.inkTertiary),
          ]),
        ),
        if (reviewCount > 0) ...[
          const SizedBox(height: 10),
          FCard(
            color: p.warningBg,
            onTap: () => context.push('/review'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              Icon(Icons.inbox_rounded, color: p.warning),
              const SizedBox(width: 10),
              Expanded(child: Text(s.reviewPending(reviewCount), style: context.tt.titleSmall)),
              Icon(context.isRtl ? Icons.chevron_left : Icons.chevron_right, color: p.warning),
            ]),
          ),
        ],
      ]),
    );
  }
}

/// "Estimated amount available until payday" with its assumptions spelled out.
class PaydayCard extends ConsumerWidget {
  const PaydayCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final p = context.fp;
    final settings = ref.watch(settingsProvider);
    final fmt = settings.fmt;
    final base = settings.baseCurrency;
    final now = ref.watch(nowProvider)();
    final cycle = settings.cycle.cycleFor(now);
    final daysLeft = settings.cycle.daysUntilNext(now);
    final accounts = ref.watch(accountsProvider).value ?? const <AccountRow>[];
    final balances = ref.watch(balancesProvider);
    final recurring = ref.watch(recurringProvider).value ?? const <RecurringRow>[];
    final budgets = ref.watch(budgetsProvider).value ?? const <BudgetRow>[];
    final txs = ref.watch(allTxProvider).value ?? const <TxRow>[];

    final spendable = accounts
        .where((a) => !a.isLiability && a.currency == base && (a.kind == 'bank' || a.kind == 'cash' || a.kind == 'wallet'))
        .fold<int>(0, (s0, a) => s0 + (balances[a.id] ?? 0));
    final dueBeforePayday = recurring
        .where((r) => r.status == 'active' && r.kind != 'salary' && r.currency == base && r.nextDueDate.isBefore(cycle.end) && !r.nextDueDate.isBefore(now.subtract(const Duration(days: 1))))
        .fold<int>(0, (s0, r) => s0 + r.amountMinor);
    final available = spendable - dueBeforePayday;
    final perDay = daysLeft > 0 ? available ~/ daysLeft : available;

    final overall = budgets.where((b) => b.categoryId == null && b.currency == base).firstOrNull;
    final used = overall == null ? 0 : budgetUsage(txs, cycle, base, null);

    return Padding(
      padding: const EdgeInsets.fromLTRB(FilsSpace.gutter, 12, FilsSpace.gutter, 0),
      child: FCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(s.leftUntilPayday, style: context.tt.titleSmall?.copyWith(color: p.inkSecondary)),
            const Spacer(),
            Pill(s.daysLeft(daysLeft), icon: Icons.calendar_today_rounded),
          ]),
          const SizedBox(height: 6),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Text(fmt.money(available, base), style: context.tt.headlineMedium?.copyWith(color: available < 0 ? p.negative : null)),
          ),
          const SizedBox(height: 2),
          Text(
            s.ar
                ? '≈ ${fmt.money(perDay, base)} يومياً · الرصيد القابل للصرف ناقص الالتزامات المؤكدة قبل الراتب (${fmt.money(dueBeforePayday, base)})'
                : '≈ ${fmt.money(perDay, base)}/day · spendable balance minus confirmed bills before payday (${fmt.money(dueBeforePayday, base)})',
            style: context.tt.bodySmall?.copyWith(color: p.inkSecondary),
          ),
          if (overall != null) ...[
            const SizedBox(height: 14),
            Row(children: [
              Text(s.budgetThisCycle, style: context.tt.labelMedium),
              const Spacer(),
              Text('${fmt.money(used, base)} / ${fmt.money(overall.amountMinor, base)}', style: context.tt.labelMedium?.copyWith(color: p.inkSecondary)),
            ]),
            const SizedBox(height: 6),
            FProgress(value: overall.amountMinor == 0 ? 0 : used / overall.amountMinor),
          ],
        ]),
      ),
    );
  }
}
