import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/time/kuwait_time.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import '../accounts/account_widgets.dart';

String periodLabel(BuildContext context, WidgetRef ref, Period p) {
  final fmt = ref.read(settingsProvider).fmt;
  final a = ReportingZone.kuwait.toWall(p.start);
  final b = ReportingZone.kuwait.toWall(p.end.subtract(const Duration(seconds: 1)));
  return '${fmt.dayMonth(a)} - ${fmt.dayMonth(b)}';
}

Future<void> showPeriodSheet(BuildContext context, WidgetRef ref) async {
  final s = S.of(context);
  final cur = ref.read(periodSelProvider).kind;
  final startDay = ref.read(settingsProvider).cycleStartDay;
  Widget opt(PeriodKind k, String label, String? sub) => ListTile(
        title: Text(label),
        subtitle: sub == null ? null : Text(sub),
        trailing: cur == k ? Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary) : null,
        onTap: () {
          ref.read(periodSelProvider.notifier).set(PeriodSel(k));
          Navigator.pop(context);
        },
      );
  await showFSheet(
    context,
    SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        opt(PeriodKind.cycle, s.thisCycle, s.dayOfMonth(startDay)),
        opt(PeriodKind.lastCycle, s.ar ? 'الدورة السابقة' : 'Previous cycle', null),
        opt(PeriodKind.month, s.thisMonth, null),
        opt(PeriodKind.lastMonth, s.lastMonth, null),
        ListTile(
          title: Text(s.custom),
          trailing: cur == PeriodKind.custom ? Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary) : null,
          onTap: () async {
            final now = DateTime.now();
            final r = await showDateRangePicker(context: context, firstDate: DateTime(now.year - 5), lastDate: DateTime(now.year + 1));
            if (r == null) return;
            final z = ReportingZone.kuwait;
            ref.read(periodSelProvider.notifier).set(PeriodSel(PeriodKind.custom,
                custom: Period(z.fromWall(r.start.year, r.start.month, r.start.day), z.fromWall(r.end.year, r.end.month, r.end.day).add(const Duration(days: 1)))));
            if (context.mounted) Navigator.pop(context);
          },
        ),
        const SizedBox(height: 12),
      ]),
    ),
  );
}

Future<void> showAccountFilterSheet(BuildContext context, WidgetRef ref) async {
  final s = S.of(context);
  final accounts = ref.read(accountsProvider).value ?? const [];
  final sel = ref.read(selectedAccountProvider);
  final balances = ref.read(balancesProvider);
  final fmt = ref.read(settingsProvider).fmt;
  await showFSheet(
    context,
    SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.all_inclusive_rounded),
          title: Text(s.allAccounts),
          trailing: sel == null ? Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary) : null,
          onTap: () {
            ref.read(selectedAccountProvider.notifier).set(null);
            Navigator.pop(context);
          },
        ),
        for (final a in accounts)
          ListTile(
            leading: accountBadge(a, size: 34),
            title: Text(a.name),
            subtitle: Text(fmt.money(balances[a.id] ?? 0, a.currency), style: TextStyle(color: context.fp.inkSecondary)),
            trailing: sel == a.id ? Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary) : null,
            onTap: () {
              ref.read(selectedAccountProvider.notifier).set(a.id);
              Navigator.pop(context);
            },
          ),
        const SizedBox(height: 12),
      ]),
    ),
  );
}
