import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/services.dart';
import '../../data/api/api_client.dart';
import '../../data/sync/sync_engine.dart';
import '../../app/providers.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import '../auth/sign_in_sheet.dart';
import '../../data/household/household_sharing.dart';
import 'shared_feed.dart';

final _householdsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final api = ref.watch(apiProvider);
  if (!api.configured || ref.watch(sessionProvider).value == null) return const [];
  final list = (await api.households()).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
  // Keep the local membership cache current and purge households we no longer belong to.
  await ref.read(householdSharingProvider).updateMemberships(
      [for (final h in list) HouseholdInfo(h['id'] as String, h['name'] as String? ?? '', h['my_role'] as String? ?? 'viewer')]);
  return list;
});

/// Household sharing: explicit invitations with roles. Nothing personal is shared
/// automatically; budgets and transactions are shared only when the user marks them.
class HouseholdScreen extends ConsumerWidget {
  const HouseholdScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final p = context.fp;
    final api = ref.watch(apiProvider);
    final session = ref.watch(sessionProvider).value;
    final syncOn = ref.watch(settingsProvider).raw[SyncKeys.enabled] == 'true';
    final hh = ref.watch(_householdsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(s.household)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        FCard(child: Text(s.householdBody, style: context.tt.bodyMedium)),
        const SizedBox(height: 12),
        if (!api.configured) EmptyState(emoji: '☁️', title: s.backendNotConfigured),
        if (api.configured && session == null)
          EmptyState(emoji: '👨‍👩‍👧', title: s.requiresSignInSync, action: s.signIn, onAction: () => showSignInSheet(context, ref)),
        if (api.configured && session != null && !syncOn)
          Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(s.requiresSignInSync, style: TextStyle(color: p.warning))),
        if (api.configured && session != null)
          hh.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text(s.genericError),
            data: (list) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final h in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: FCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [
                        Expanded(child: Text(h['name'] as String? ?? '', style: context.tt.titleMedium)),
                        Pill(h['my_role'] as String? ?? ''),
                      ]),
                      const SizedBox(height: 8),
                      Text(s.members, style: context.tt.labelMedium),
                      for (final m in (h['members'] as List? ?? const []).cast<Map>())
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.person_outline),
                          title: Text(m['display_name'] as String? ?? '—'),
                          subtitle: Text(m['role'] as String? ?? ''),
                          trailing: (h['my_role'] == 'owner' && m['user_id'] != session['id']) || m['user_id'] == session['id']
                              ? TextButton(
                                  onPressed: () async {
                                    await api.removeMember(h['id'] as String, m['user_id'] as String);
                                    ref.invalidate(_householdsProvider);
                                  },
                                  child: Text(m['user_id'] == session['id'] ? s.leave : s.remove),
                                )
                              : null,
                        ),
                      if (h['my_role'] == 'owner')
                        OutlinedButton.icon(onPressed: () => _invite(context, ref, h['id'] as String), icon: const Icon(Icons.person_add_alt), label: Text(s.inviteMember)),
                      const Divider(height: 24),
                      SharedFeed(householdId: h['id'] as String),
                    ]),
                  ),
                ),
              FilledButton.icon(onPressed: () => _create(context, ref), icon: const Icon(Icons.add_home_outlined), label: Text(s.createHousehold)),
              const SizedBox(height: 8),
              OutlinedButton.icon(onPressed: () => _join(context, ref), icon: const Icon(Icons.vpn_key_outlined), label: Text(s.joinHousehold)),
            ]),
          ),
      ]),
    );
  }

  Future<String?> _prompt(BuildContext context, String title, String label) async {
    final s = S.of(context);
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true, decoration: InputDecoration(labelText: label)),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.confirm))],
      ),
    );
    return ok == true && c.text.trim().isNotEmpty ? c.text.trim() : null;
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final s = S.of(context);
    final name = await _prompt(context, s.createHousehold, s.ar ? 'الاسم' : 'Name');
    if (name == null) return;
    try {
      await ref.read(apiProvider).createHousehold(name);
      ref.invalidate(_householdsProvider);
    } on ApiException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${s.genericError} (${e.code})')));
    }
  }

  Future<void> _join(BuildContext context, WidgetRef ref) async {
    final s = S.of(context);
    final code = await _prompt(context, s.joinHousehold, s.inviteCode);
    if (code == null) return;
    try {
      await ref.read(apiProvider).joinHousehold(code);
      ref.invalidate(_householdsProvider);
    } on ApiException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${s.genericError} (${e.code})')));
    }
  }

  Future<void> _invite(BuildContext context, WidgetRef ref, String id) async {
    final s = S.of(context);
    final role = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(title: Text(s.inviteMember), children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'member'), child: Text(s.ar ? 'عضو (يضيف ويعدل المشترك)' : 'Member (can edit shared items)')),
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'viewer'), child: Text(s.ar ? 'مشاهد فقط' : 'Viewer (read-only)')),
      ]),
    );
    if (role == null) return;
    try {
      final r = await ref.read(apiProvider).invite(id, role);
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(s.inviteCode),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SelectableText(r['code'] as String, style: context.tt.headlineMedium),
            const SizedBox(height: 8),
            Text(s.ar ? 'يظهر مرة واحدة وينتهي في ${r['expires_at']}' : 'Shown once. Expires ${r['expires_at']}', style: context.tt.bodySmall),
          ]),
          actions: [
            TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: r['code'] as String)), child: Text(s.ar ? 'نسخ' : 'Copy')),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(s.done)),
          ],
        ),
      );
    } on ApiException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${s.genericError} (${e.code})')));
    }
  }
}
