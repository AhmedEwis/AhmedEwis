import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/services.dart';
import '../../data/household/household_sharing.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';

/// Explicit consent sheet: shows exactly what will and won't be shared.
Future<void> showShareSheet(BuildContext context, WidgetRef ref, {String? transactionId, String? budgetId}) async {
  final s = S.of(context);
  final households = (ref.read(householdsCacheProvider).value ?? const <HouseholdInfo>[]).where((h) => h.canShare).toList();
  if (households.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.ar ? 'أنشئ عائلة أو انضم لواحدة بصلاحية عضو أولاً.' : 'Create or join a household as a member first.')));
    return;
  }
  var picked = households.first;
  var includeNote = false;
  final ok = await showFSheet<bool>(
    context,
    StatefulBuilder(
      builder: (ctx, set) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(s.ar ? 'مشاركة مع العائلة' : 'Share with household', style: context.tt.titleLarge),
          const SizedBox(height: 8),
          if (households.length > 1)
            DropdownButtonFormField<String>(
              initialValue: picked.id,
              items: [for (final h in households) DropdownMenuItem(value: h.id, child: Text(h.name))],
              onChanged: (v) => set(() => picked = households.firstWhere((h) => h.id == v)),
            ),
          const SizedBox(height: 8),
          FCard(
            color: context.fp.surfaceMuted,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.ar ? 'سيتم مشاركة:' : 'Will be shared:', style: context.tt.labelLarge),
              Text(transactionId != null
                  ? (s.ar ? '• التاريخ، المبلغ، العملة، التاجر، الفئة' : '• Date, amount, currency, merchant, category')
                  : (s.ar ? '• الفئة، الحد الشهري، العملة' : '• Category, monthly limit, currency')),
              const SizedBox(height: 8),
              Text(s.ar ? 'لن تتم مشاركة:' : 'Never shared:', style: context.tt.labelLarge),
              Text(s.ar
                  ? '• حسابك أو بطاقتك أو رصيدك\n• نص الرسالة الأصلية\n• باقي عملياتك'
                  : '• Your account, card digits or balance\n• The original message text\n• Any of your other transactions'),
            ]),
          ),
          if (transactionId != null)
            SwitchListTile(contentPadding: EdgeInsets.zero, value: includeNote, onChanged: (v) => set(() => includeNote = v), title: Text(s.ar ? 'تضمين الملاحظة' : 'Include note')),
          Text(s.ar ? 'يمكنك إلغاء المشاركة في أي وقت.' : 'You can revoke this at any time.', style: context.tt.bodySmall),
          const SizedBox(height: 12),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.ar ? 'مشاركة' : 'Share')),
        ]),
      ),
    ),
  );
  if (ok != true) return;
  final sharing = ref.read(householdSharingProvider);
  final me = ref.read(sessionProvider).value;
  final name = (me?['display_name'] as String?) ?? (s.ar ? 'عضو' : 'Member');
  if (transactionId != null) {
    await sharing.shareTransaction(transactionId, picked, includeNote: includeNote, displayName: name);
  } else if (budgetId != null) {
    await sharing.shareBudget(budgetId, picked);
  }
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.ar ? 'تمت المشاركة (تُرفع عند المزامنة)' : 'Shared (uploads on next sync)')));
}
