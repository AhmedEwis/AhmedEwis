import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/ledger/ledger.dart';
import '../../core/time/kuwait_time.dart';
import '../../data/db/database.dart';
import '../../l10n/strings.dart';
import '../../ui/format.dart';
import '../../ui/theme/theme.dart';
import '../../ui/theme/tokens.dart';
import '../../ui/widgets/common.dart';
import '../home/period_sheet.dart';

class InsightsScreen extends ConsumerWidget {
  const InsightsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final p = context.fp;
    final settings = ref.watch(settingsProvider);
    final fmt = settings.fmt;
    final base = settings.baseCurrency;
    final period = ref.watch(periodProvider);
    final totals = ref.watch(periodTotalsProvider);
    final txs = ref.watch(allTxProvider).value ?? const <TxRow>[];
    final splits = ref.watch(splitsProvider).value ?? const {};
    final cats = ref.watch(categoryMapProvider);
    final cyc = settings.cycle;
    final prevPeriod = Period(period.start.subtract(period.length), period.start);
    final prev = totalsFor(txs, prevPeriod, splitsByTx: splits);

    final byCat = (totals.byCategory[base] ?? const <String, int>{}).entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    final spent = totals.spentIn(base);
    final byMerchant = (totals.byMerchant[base] ?? const <String, int>{}).entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    final delta = spent - prev.spentIn(base);

    // Last 6 cycles: income vs spent
    final now = ref.watch(nowProvider)();
    final cycles = <Period>[];
    var c = cyc.cycleFor(now);
    for (var i = 0; i < 6; i++) {
      cycles.insert(0, c);
      c = cyc.previous(c);
    }
    final flows = [for (final pp in cycles) totalsFor(txs, pp, splitsByTx: splits)];

    // Daily spending within the period
    final dayCount = period.length.inDays.clamp(1, 62);
    final daily = List<int>.filled(dayCount, 0);
    for (final t in txs) {
      if (!period.contains(t.occurredAt) || t.currency != base) continue;
      final v = categorySpend(t, splits: splits[t.id] ?? const []).values.fold<int>(0, (a, b) => a + b);
      if (v == 0) continue;
      final d = t.occurredAt.difference(period.start).inDays;
      if (d >= 0 && d < dayCount) daily[d] += v;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(s.insights),
        actions: [TextButton(onPressed: () => showPeriodSheet(context, ref), child: Text(periodLabel(context, ref, period)))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          FCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.spentByCategory, style: context.tt.labelSmall?.copyWith(color: p.inkSecondary)),
              const SizedBox(height: 12),
              if (byCat.isEmpty)
                Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(s.noDataPeriod, style: TextStyle(color: p.inkSecondary))))
              else
                CategoryDonut(entries: byCat, total: spent, currency: base, fmt: fmt, cats: cats),
              const Divider(height: 24),
              Row(children: [
                Text(s.total, style: context.tt.bodyMedium?.copyWith(color: p.inkSecondary)),
                const Spacer(),
                Directionality(textDirection: TextDirection.ltr, child: Text(fmt.money(spent, base), style: context.tt.titleMedium)),
              ]),
              const SizedBox(height: 4),
              Row(children: [
                Text(s.comparePrevious, style: context.tt.bodySmall?.copyWith(color: p.inkSecondary)),
                const Spacer(),
                Text('${delta >= 0 ? '▲' : '▼'} ${fmt.money(delta.abs(), base)}', style: context.tt.labelMedium?.copyWith(color: delta > 0 ? p.negative : p.positive)),
              ]),
            ]),
          ),
          const SizedBox(height: 16),
          FCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.dailySpending, style: context.tt.titleSmall),
              const SizedBox(height: 12),
              SizedBox(
                height: 140,
                child: Semantics(
                  label: '${s.dailySpending}: ${s.total} ${fmt.money(spent, base)}',
                  child: BarChart(BarChartData(
                    gridData: const FlGridData(show: false),
                    borderData: FlBorderData(show: false),
                    titlesData: const FlTitlesData(show: false),
                    barTouchData: BarTouchData(
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipColor: (_) => p.surface,
                        getTooltipItem: (g, _, rod, __) => BarTooltipItem(
                          '${fmt.dayMonth(ReportingZone.kuwait.toWall(period.start.add(Duration(days: g.x))))}\n${fmt.money(rod.toY.round(), base)}',
                          context.tt.labelMedium!.copyWith(color: p.ink),
                        ),
                      ),
                    ),
                    barGroups: [
                      for (var i = 0; i < dayCount; i++)
                        BarChartGroupData(x: i, barRods: [
                          BarChartRodData(toY: daily[i].toDouble(), color: Theme.of(context).colorScheme.primary, width: dayCount > 31 ? 3 : 6, borderRadius: BorderRadius.circular(3)),
                        ]),
                    ],
                  )),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          FCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.cashFlow, style: context.tt.titleSmall),
              const SizedBox(height: 12),
              SizedBox(
                height: 160,
                child: BarChart(BarChartData(
                  gridData: const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    leftTitles: const AxisTitles(),
                    rightTitles: const AxisTitles(),
                    topTitles: const AxisTitles(),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (v, _) => Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(fmt.dayMonth(ReportingZone.kuwait.toWall(cycles[v.toInt()].start)), style: context.tt.labelSmall?.copyWith(color: p.inkSecondary, letterSpacing: 0)),
                        ),
                      ),
                    ),
                  ),
                  barGroups: [
                    for (var i = 0; i < cycles.length; i++)
                      BarChartGroupData(x: i, barsSpace: 3, barRods: [
                        BarChartRodData(toY: flows[i].incomeIn(base).toDouble(), color: p.positive, width: 9, borderRadius: BorderRadius.circular(3)),
                        BarChartRodData(toY: flows[i].spentIn(base).toDouble(), color: Theme.of(context).colorScheme.primary, width: 9, borderRadius: BorderRadius.circular(3)),
                      ]),
                  ],
                )),
              ),
              const SizedBox(height: 8),
              // Accessible table of the underlying values
              for (var i = cycles.length - 1; i >= cycles.length - 3 && i >= 0; i--)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Expanded(child: Text(fmt.dayMonth(ReportingZone.kuwait.toWall(cycles[i].start)), style: context.tt.bodySmall)),
                    Text('${s.income} ${fmt.money(flows[i].incomeIn(base), base)}', style: context.tt.bodySmall?.copyWith(color: p.positive)),
                    const SizedBox(width: 10),
                    Text('${s.spent} ${fmt.money(flows[i].spentIn(base), base)}', style: context.tt.bodySmall),
                  ]),
                ),
            ]),
          ),
          const SizedBox(height: 16),
          FCard(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 4), child: Text(s.byMerchant, style: context.tt.titleSmall)),
              if (byMerchant.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(s.noDataPeriod, style: TextStyle(color: p.inkSecondary))),
              for (final e in byMerchant.take(8))
                ListTile(
                  dense: true,
                  title: Text(e.key, style: context.tt.bodyLarge),
                  subtitle: FProgress(value: spent == 0 ? 0 : e.value / spent, height: 5),
                  trailing: Directionality(textDirection: TextDirection.ltr, child: Text(fmt.money(e.value, base), style: context.tt.titleSmall)),
                ),
            ]),
          ),
        ],
      ),
    );
  }
}

/// Donut + legend (reference: "SPENT BY CATEGORY · THIS MONTH" card).
class CategoryDonut extends StatefulWidget {
  final List<MapEntry<String, int>> entries;
  final int total;
  final String currency;
  final Fmt fmt;
  final Map<String, CategoryRow> cats;
  const CategoryDonut({super.key, required this.entries, required this.total, required this.currency, required this.fmt, required this.cats});
  @override
  State<CategoryDonut> createState() => _CategoryDonutState();
}

class _CategoryDonutState extends State<CategoryDonut> {
  bool showAll = false;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = context.fp;
    final shown = showAll ? widget.entries : widget.entries.take(5).toList();
    Color colorFor(int i, String id) => widget.cats[id] != null ? Color(widget.cats[id]!.color) : FilsColors.chart[i % FilsColors.chart.length];
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 140,
        height: 140,
        child: Stack(alignment: Alignment.center, children: [
          PieChart(PieChartData(
            sectionsSpace: 0,
            centerSpaceRadius: 46,
            startDegreeOffset: -90,
            sections: [
              for (final (i, e) in widget.entries.indexed)
                PieChartSectionData(value: e.value.toDouble(), color: colorFor(i, e.key), radius: 22, showTitle: false),
            ],
          )),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Text(s.spent.toUpperCase(), style: context.tt.labelSmall?.copyWith(color: p.inkSecondary)),
            Text(widget.fmt.amount(widget.total, widget.currency, compact: true), style: context.tt.titleLarge),
          ]),
        ]),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final (i, e) in shown.indexed)
            Semantics(
              label: '${_name(s, e.key)} ${widget.fmt.money(e.value, widget.currency)} ${widget.fmt.percent(e.value / widget.total)}',
              excludeSemantics: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Container(width: 10, height: 10, decoration: BoxDecoration(color: colorFor(i, e.key), shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_name(s, e.key), style: context.tt.bodyMedium, overflow: TextOverflow.ellipsis)),
                  Text(widget.fmt.percent(widget.total == 0 ? 0 : e.value / widget.total), style: context.tt.labelMedium?.copyWith(color: p.inkSecondary)),
                ]),
              ),
            ),
          if (widget.entries.length > 5)
            TextButton(
              onPressed: () => setState(() => showAll = !showAll),
              child: Text(showAll ? (s.ar ? 'عرض أقل' : 'Show less') : s.showAllN(widget.entries.length)),
            ),
        ]),
      ),
    ]);
  }

  String _name(S s, String id) {
    final c = widget.cats[id];
    if (c == null) return id;
    return s.ar ? c.nameAr : c.nameEn;
  }
}
