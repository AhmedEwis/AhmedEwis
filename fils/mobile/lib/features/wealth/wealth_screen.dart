import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/ledger/ledger.dart';
import '../../core/money/money.dart';
import '../../core/time/kuwait_time.dart';
import '../../data/db/database.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/theme/tokens.dart';
import '../../ui/widgets/common.dart';
import '../accounts/account_widgets.dart';

enum WealthTab { net, assets, debt }

enum Range { m1, m3, y1, all }

class WealthScreen extends ConsumerStatefulWidget {
  const WealthScreen({super.key});
  @override
  ConsumerState<WealthScreen> createState() => _WealthScreenState();
}

class _WealthScreenState extends ConsumerState<WealthScreen> {
  WealthTab tab = WealthTab.net;
  Range range = Range.y1;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = context.fp;
    final settings = ref.watch(settingsProvider);
    final fmt = settings.fmt;
    final base = settings.baseCurrency;
    final accounts = ref.watch(accountsProvider).value ?? const <AccountRow>[];
    final balances = ref.watch(balancesProvider);
    final assets = ref.watch(assetsProvider).value ?? const <AssetRow>[];
    final txs = ref.watch(allTxProvider).value ?? const <TxRow>[];
    final now = ref.watch(nowProvider)();

    final nw = netWorth(accounts: accounts, balances: balances, assets: assets);
    final tracked = accounts.where((a) => a.includeInNetWorth).map((a) => a.id).toSet();
    final assetTotal = accounts.where((a) => a.currency == base && (balances[a.id] ?? 0) > 0).fold<int>(0, (x, a) => x + (balances[a.id] ?? 0)) +
        assets.where((a) => a.currency == base && !a.isLiability && !(a.linkedAccountId != null && tracked.contains(a.linkedAccountId))).fold<int>(0, (x, a) => x + a.valueMinor);
    final debtTotal = accounts.where((a) => a.currency == base && (balances[a.id] ?? 0) < 0).fold<int>(0, (x, a) => x - (balances[a.id] ?? 0)) +
        assets.where((a) => a.currency == base && a.isLiability).fold<int>(0, (x, a) => x + a.valueMinor);
    final headline = switch (tab) {
      WealthTab.net => nw[base] ?? 0,
      WealthTab.assets => assetTotal,
      WealthTab.debt => debtTotal,
    };
    final otherCur = nw.entries.where((e) => e.key != base && e.value != 0).map((e) => fmt.money(e.value, e.key)).join(' · ');

    // History: account balances reconstructed from transactions (exact), plus manual
    // assets at their current recorded value (no historical prices are invented).
    final days = switch (range) { Range.m1 => 30, Range.m3 => 90, Range.y1 => 365, Range.all => _allDays(txs, now) };
    final points = _history(accounts.where((a) => a.currency == base && a.includeInNetWorth).toList(), txs, assets.where((a) => a.currency == base).toList(), tracked, now, days);
    final start = points.isEmpty ? 0 : points.first.y;
    final change = points.isEmpty ? 0 : (points.last.y - start);

    final spendable = accounts.where((a) => !a.isLiability && (a.kind == 'bank' || a.kind == 'cash' || a.kind == 'wallet') && a.currency == base).toList();
    final spendableTotal = spendable.fold<int>(0, (x, a) => x + (balances[a.id] ?? 0));
    final kinds = <String, int>{};
    for (final a in assets.where((a) => !a.isLiability && a.currency == base)) {
      kinds[a.kind] = (kinds[a.kind] ?? 0) + a.valueMinor;
    }
    kinds['spendable'] = spendableTotal.clamp(0, 1 << 62);
    final kindsTotal = kinds.values.fold<int>(0, (a, b) => a + b);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
          children: [
            Row(children: [
              Expanded(child: Semantics(header: true, child: Text(s.wealth, style: context.tt.displayMedium))),
              IconButton(iconSize: 30, color: Theme.of(context).colorScheme.primary, tooltip: s.addAsset, icon: const Icon(Icons.add), onPressed: () => showFSheet(context, const AssetForm())),
            ]),
            const SizedBox(height: 8),
            Segmented<WealthTab>(items: [(WealthTab.net, s.netWorth), (WealthTab.assets, s.assets), (WealthTab.debt, s.debt)], value: tab, onChanged: (v) => setState(() => tab = v)),
            const SizedBox(height: 16),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Directionality(textDirection: TextDirection.ltr, child: Text(fmt.money(headline, base), style: context.tt.displayLarge)),
            ),
            if (tab == WealthTab.net && points.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Pill('${change >= 0 ? '▲' : '▼'} ${fmt.money(change.abs(), base)}${start != 0 ? ' (${fmt.percent((change / start.abs()).abs())})' : ''}',
                      bg: change >= 0 ? p.positiveBg : p.negativeBg, fg: change >= 0 ? p.positive : p.negative),
                  const SizedBox(width: 8),
                  Text(switch (range) { Range.m1 => s.ar ? 'هذا الشهر' : 'this month', Range.m3 => s.ar ? 'آخر ٣ أشهر' : 'last 3 months', Range.y1 => s.ar ? 'هذه السنة' : 'this year', Range.all => s.ar ? 'منذ البداية' : 'all time' },
                      style: context.tt.bodyMedium?.copyWith(color: p.inkSecondary)),
                ]),
              ),
            Text('${fmt.money(spendableTotal, base)} ${s.ar ? 'متاح الآن' : 'available now'}', style: context.tt.bodyMedium?.copyWith(color: p.inkSecondary)),
            if (otherCur.isNotEmpty) Text(s.otherCurrencies(otherCur), style: context.tt.bodySmall?.copyWith(color: p.inkSecondary)),
            const SizedBox(height: 16),
            if (tab == WealthTab.net)
              SizedBox(
                height: 220,
                child: points.length < 2
                    ? Center(child: Text(s.noDataPeriod, style: TextStyle(color: p.inkSecondary)))
                    : Semantics(
                        label: '${s.netWorth}: ${fmt.money(points.first.y.round(), base)} → ${fmt.money(points.last.y.round(), base)}',
                        child: LineChart(LineChartData(
                          gridData: const FlGridData(show: false),
                          borderData: FlBorderData(show: false),
                          titlesData: const FlTitlesData(show: false),
                          lineTouchData: LineTouchData(
                            touchTooltipData: LineTouchTooltipData(
                              getTooltipColor: (_) => p.surface,
                              getTooltipItems: (spots) => [
                                for (final sp in spots)
                                  LineTooltipItem(
                                    '${fmt.money(sp.y.round(), base)}\n${fmt.dayMonthYear(ReportingZone.kuwait.toWall(now.subtract(Duration(days: (days - sp.x).round()))))}',
                                    context.tt.labelMedium!.copyWith(color: p.ink),
                                  ),
                              ],
                            ),
                          ),
                          lineBarsData: [
                            LineChartBarData(
                              spots: points,
                              isCurved: true,
                              color: Theme.of(context).colorScheme.primary,
                              barWidth: 3,
                              dotData: const FlDotData(show: false),
                              belowBarData: BarAreaData(
                                show: true,
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Theme.of(context).colorScheme.primary.withValues(alpha: 0.25), Theme.of(context).colorScheme.primary.withValues(alpha: 0.0)],
                                ),
                              ),
                            ),
                          ],
                        )),
                      ),
              ),
            if (tab == WealthTab.net) ...[
              const SizedBox(height: 8),
              Segmented<Range>(items: const [(Range.m1, '1M'), (Range.m3, '3M'), (Range.y1, '1Y'), (Range.all, 'All')], value: range, onChanged: (v) => setState(() => range = v)),
              const SizedBox(height: 16),
              if (kindsTotal > 0) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Row(children: [
                    for (final (i, e) in kinds.entries.indexed)
                      if (e.value > 0) Expanded(flex: (e.value * 1000 ~/ kindsTotal).clamp(1, 1000), child: Container(height: 10, color: FilsColors.chart[i % FilsColors.chart.length])),
                  ]),
                ),
                const SizedBox(height: 8),
                Wrap(spacing: 12, runSpacing: 4, children: [
                  for (final (i, e) in kinds.entries.indexed)
                    if (e.value > 0)
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        Container(width: 9, height: 9, decoration: BoxDecoration(color: FilsColors.chart[i % FilsColors.chart.length], shape: BoxShape.circle)),
                        const SizedBox(width: 4),
                        Text('${_kindLabel(s, e.key)} ${fmt.percent(e.value / kindsTotal)}', style: context.tt.labelMedium?.copyWith(color: p.inkSecondary)),
                      ]),
                ]),
              ],
            ],
            const SizedBox(height: 20),
            Row(children: [
              Text('💰 ${s.spendable}', style: context.tt.labelSmall?.copyWith(color: p.inkSecondary)),
              const Spacer(),
              Directionality(textDirection: TextDirection.ltr, child: Text(fmt.money(spendableTotal, base), style: context.tt.titleSmall)),
            ]),
            const SizedBox(height: 8),
            FCard(
              padding: EdgeInsets.zero,
              child: Column(children: [
                for (final a in accounts.where((a) => tab != WealthTab.debt ? (balances[a.id] ?? 0) >= 0 : (balances[a.id] ?? 0) < 0))
                  ListTile(
                    leading: accountBadge(a, size: 44),
                    title: Text(a.name, style: context.tt.titleSmall),
                    subtitle: Text(a.maskLast4 == null ? '' : '•••• ${a.maskLast4}'),
                    trailing: Directionality(textDirection: TextDirection.ltr, child: Text(fmt.money(balances[a.id] ?? 0, a.currency), style: context.tt.titleSmall)),
                    onTap: () => context.push('/accounts/${a.id}'),
                  ),
              ]),
            ),
            const SizedBox(height: 16),
            Text(s.assets.toUpperCase(), style: context.tt.labelSmall?.copyWith(color: p.inkSecondary)),
            const SizedBox(height: 8),
            FCard(
              padding: EdgeInsets.zero,
              child: assets.where((a) => tab == WealthTab.debt ? a.isLiability : (tab == WealthTab.assets ? !a.isLiability : true)).isEmpty
                  ? EmptyState(emoji: '🪙', title: s.addAsset, body: s.wealthNote, action: s.add, onAction: () => showFSheet(context, const AssetForm()))
                  : Column(children: [
                      for (final a in assets.where((a) => tab == WealthTab.debt ? a.isLiability : (tab == WealthTab.assets ? !a.isLiability : true)))
                        ListTile(
                          leading: CategoryTile(emoji: _kindEmoji(a.kind), color: a.isLiability ? p.negative : const Color(0xFFD4A017), size: 44),
                          title: Text(a.name, style: context.tt.titleSmall),
                          subtitle: Text(
                              '${s.valuationDate} ${fmt.dayMonthYear(ReportingZone.kuwait.toWall(a.valuationDate))} · ${s.manualValue}${a.linkedAccountId != null && tracked.contains(a.linkedAccountId) ? '\n${s.linkedToAccount}' : ''}'),
                          isThreeLine: a.linkedAccountId != null,
                          trailing: Directionality(
                              textDirection: TextDirection.ltr,
                              child: Text(fmt.money(a.isLiability ? -a.valueMinor : a.valueMinor, a.currency), style: context.tt.titleSmall?.copyWith(color: a.isLiability ? p.negative : null))),
                          onTap: () => showFSheet(context, AssetForm(existing: a)),
                        ),
                    ]),
            ),
            const SizedBox(height: 8),
            Text(s.wealthNote, style: context.tt.bodySmall?.copyWith(color: p.inkSecondary)),
          ],
        ),
      ),
    );
  }

  int _allDays(List<TxRow> txs, DateTime now) {
    if (txs.isEmpty) return 30;
    final first = txs.map((t) => t.occurredAt).reduce((a, b) => a.isBefore(b) ? a : b);
    return now.difference(first).inDays.clamp(30, 3650) + 1;
  }

  List<FlSpot> _history(List<AccountRow> accts, List<TxRow> txs, List<AssetRow> assets, Set<String> tracked, DateTime now, int days) {
    if (accts.isEmpty && assets.isEmpty) return const [];
    final manualAssets = assets.where((a) => !(a.linkedAccountId != null && tracked.contains(a.linkedAccountId))).toList();
    final step = days > 120 ? 7 : 1;
    final out = <FlSpot>[];
    final ids = accts.map((a) => a.id).toSet();
    final relevant = txs.where((t) => ids.contains(t.accountId) || (t.counterAccountId != null && ids.contains(t.counterAccountId))).toList();
    for (var d = days; d >= 0; d -= step) {
      final at = now.subtract(Duration(days: d));
      var total = 0;
      for (final a in accts) {
        if (a.openingBalanceDate.isAfter(at)) continue;
        total += calculatedBalance(a, relevant.where((t) => !t.occurredAt.isAfter(at)));
      }
      // A manual asset counts from its valuation date at its recorded value. No
      // historical prices are fabricated.
      final assetsKnown = manualAssets.where((x) => !x.valuationDate.isAfter(at)).fold<int>(0, (x, a) => x + (a.isLiability ? -a.valueMinor : a.valueMinor));
      out.add(FlSpot((days - d).toDouble(), (total + assetsKnown).toDouble()));
    }
    return out;
  }
}

String _kindLabel(S s, String k) => switch (k) {
      'spendable' => s.ar ? 'قابل للصرف' : 'Spendable',
      'gold' => s.assetGold,
      'property' => s.assetProperty,
      'vehicle' => s.assetVehicle,
      'investment' => s.assetInvestment,
      'deposit' => s.assetDeposit,
      'loan' => s.assetLoan,
      _ => s.assetOther,
    };

String _kindEmoji(String k) => switch (k) {
      'gold' => '🪙',
      'property' => '🏠',
      'vehicle' => '🚗',
      'investment' => '📈',
      'deposit' => '🏦',
      'loan' => '📄',
      'cash' => '💵',
      _ => '💼',
    };

class AssetForm extends ConsumerStatefulWidget {
  final AssetRow? existing;
  const AssetForm({super.key, this.existing});
  @override
  ConsumerState<AssetForm> createState() => _AssetFormState();
}

class _AssetFormState extends ConsumerState<AssetForm> {
  late final name = TextEditingController(text: widget.existing?.name ?? '');
  late final value = TextEditingController(text: widget.existing == null ? '' : Money(widget.existing!.valueMinor, widget.existing!.currency).toDecimalString());
  late String kind = widget.existing?.kind ?? 'gold';
  late String? linked = widget.existing?.linkedAccountId;
  String? error;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final base = widget.existing?.currency ?? ref.watch(settingsProvider).baseCurrency;
    final accounts = ref.watch(accountsProvider).value ?? const <AccountRow>[];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.existing == null ? s.addAsset : s.edit, style: context.tt.titleLarge),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final k in ['gold', 'property', 'vehicle', 'investment', 'deposit', 'other', 'loan'])
            ChoiceChip(label: Text('${_kindEmoji(k)} ${_kindLabel(s, k)}'), selected: kind == k, onSelected: (_) => setState(() => kind = k)),
        ]),
        const SizedBox(height: 12),
        TextField(controller: name, decoration: InputDecoration(labelText: s.ar ? 'الاسم' : 'Name')),
        const SizedBox(height: 12),
        TextField(controller: value, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: '${s.manualValue} ($base)')),
        if (kind == 'deposit' || kind == 'investment') ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            initialValue: linked,
            decoration: InputDecoration(labelText: s.ar ? 'مرتبط بحساب متتبع؟' : 'Already tracked as an account?', helperText: s.linkedToAccount, helperMaxLines: 2),
            items: [DropdownMenuItem(value: null, child: Text(s.ar ? 'لا' : 'No')), for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name))],
            onChanged: (v) => setState(() => linked = v),
          ),
        ],
        if (error != null) Text(error!, style: TextStyle(color: context.fp.negative)),
        const SizedBox(height: 16),
        Row(children: [
          if (widget.existing != null)
            TextButton(
              onPressed: () async {
                await ref.read(storeProvider).deleteAsset(widget.existing!.id);
                if (context.mounted) Navigator.pop(context);
              },
              child: Text(s.delete, style: TextStyle(color: context.fp.negative)),
            ),
          const Spacer(),
          FilledButton(
            onPressed: () async {
              final m = Money.parse(value.text, base);
              if (name.text.trim().isEmpty) return setState(() => error = s.required);
              if (m == null || m.minor < 0) return setState(() => error = s.invalidAmount);
              await ref.read(storeProvider).saveAsset(
                    id: widget.existing?.id,
                    name: name.text.trim(),
                    kind: kind,
                    valueMinor: m.minor,
                    currency: base,
                    isLiability: kind == 'loan',
                    linkedAccountId: linked,
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
