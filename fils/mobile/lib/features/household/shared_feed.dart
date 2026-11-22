import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/services.dart';
import '../../core/time/kuwait_time.dart';
import '../../data/db/database.dart';
import '../../data/household/household_sharing.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';

final _feedProvider = StreamProvider.family<List<SharedRow>, String>((ref, id) => ref.watch(householdSharingProvider).watch(id));

/// Items shared into one household: shared budgets (with household usage this month) and
/// shared transactions. Items I shared can be revoked; others' items are read-only.
class SharedFeed extends ConsumerWidget {
  final String householdId;
  const SharedFeed({super.key, required this.householdId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final p = context.fp;
    final rows = ref.watch(_feedProvider(householdId)).value ?? const <SharedRow>[];
    final fmt = ref.watch(settingsProvider).fmt;
    final cats = ref.watch(categoryMapProvider);
    final month = calendarMonth(ref.watch(nowProvider)());
    final budgets = rows.where((r) => r.entity == 'budget').toList();
    final txs = rows.where((r) => r.entity == 'transaction').toList();
    if (budgets.isEmpty && txs.isEmpty) {
      return Text(s.ar ? 'لا يوجد شيء مشترك بعد. شارك عملية أو ميزانية من صفحتها.' : 'Nothing shared yet. Share a transaction or budget from its screen.',
          style: context.tt.bodySmall?.copyWith(color: p.inkSecondary));
    }
    Widget revoke(SharedRow r) => r.ownerUserId == null
        ? TextButton(onPressed: () => ref.read(householdSharingProvider).revoke(r.id), child: Text(s.ar ? 'إلغاء' : 'Revoke'))
        : Pill(s.ar ? 'من عضو' : 'Member');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (budgets.isNotEmpty) Text(s.ar ? 'ميزانيات مشتركة (هذا الشهر)' : 'Shared budgets (this month)', style: context.tt.labelLarge),
      for (final b in budgets)
        Builder(builder: (_) {
          final pl = jsonDecode(b.payloadJson) as Map<String, dynamic>;
          final cat = pl['category_id'] as String?;
          final cur = pl['currency'] as String;
          final used = HouseholdSharing.householdSpending(rows, month.start, month.end, categoryId: cat)[cur] ?? 0;
          final limit = (pl['amount_minor'] as num).toInt();
          return ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(cat == null ? s.overallBudget : (s.ar ? cats[cat]?.nameAr : cats[cat]?.nameEn) ?? cat),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${fmt.money(used, cur)} / ${fmt.money(limit, cur)}'),
              const SizedBox(height: 4),
              FProgress(value: limit == 0 ? 0 : used / limit),
            ]),
            trailing: revoke(b),
          );
        }),
      if (txs.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(s.ar ? 'عمليات مشتركة' : 'Shared transactions', style: context.tt.labelLarge),
      ],
      for (final t in txs)
        Builder(builder: (_) {
          final pl = jsonDecode(t.payloadJson) as Map<String, dynamic>;
          final at = DateTime.parse(pl['occurred_at'] as String);
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Text(cats[pl['category_id']]?.icon ?? '📦', style: const TextStyle(fontSize: 22)),
            title: Text(pl['merchant'] as String? ?? '—'),
            subtitle: Text('${fmt.dayMonth(ReportingZone.kuwait.toWall(at))}${pl['note'] != null ? ' · ${pl['note']}' : ''}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Directionality(textDirection: TextDirection.ltr, child: Text(fmt.money((pl['amount_minor'] as num).toInt(), pl['currency'] as String))),
              revoke(t),
            ]),
          );
        }),
      const SizedBox(height: 4),
      Text(s.ar ? 'المبالغ المشتركة لا تؤثر على أرصدتك الشخصية.' : 'Shared items never change your personal balances.', style: context.tt.bodySmall?.copyWith(color: p.inkSecondary)),
    ]);
  }
}
