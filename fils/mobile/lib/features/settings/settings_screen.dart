import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/config.dart';
import '../../app/providers.dart';
import '../../app/services.dart';
import '../../core/money/money.dart';
import '../../data/api/api_client.dart';
import '../../data/db/database.dart';
import '../../data/db/open.dart';
import '../../data/import_export.dart';
import '../../data/store.dart';
import '../../data/sync/sync_engine.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import '../auth/sign_in_sheet.dart';

/// Records a consent decision locally (always) and on the server (when signed in).
Future<void> recordConsent(WidgetRef ref, String kind, bool granted) async {
  final store = ref.read(storeProvider);
  await store.db.into(store.db.localConsents).insert(LocalConsentsCompanion.insert(
        id: newId(),
        kind: kind,
        granted: granted,
        policyVersion: AppConfig.policyVersion,
        at: DateTime.now().toUtc(),
      ));
  await store.setSetting('consent_$kind', '$granted');
  final api = ref.read(apiProvider);
  if (api.configured && ref.read(sessionProvider).value != null) {
    try {
      await api.recordConsent(kind, granted, AppConfig.policyVersion);
    } catch (_) {}
  }
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final p = context.fp;
    final settings = ref.watch(settingsProvider);
    final store = ref.watch(storeProvider);
    final session = ref.watch(sessionProvider).value;
    final api = ref.watch(apiProvider);
    final raw = settings.raw;

    Widget section(String t) => Padding(padding: const EdgeInsets.fromLTRB(20, 20, 20, 6), child: Text(t.toUpperCase(), style: context.tt.labelSmall?.copyWith(color: p.inkSecondary)));
    Widget group(List<Widget> children) => Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: FCard(padding: EdgeInsets.zero, child: Column(children: children)));

    return Scaffold(
      appBar: AppBar(title: Text(s.settings)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          // Account
          group([
            ListTile(
              leading: CircleAvatar(child: Text(session == null ? '👤' : ((session['display_name'] as String?)?.characters.firstOrNull ?? '✓'))),
              title: Text(session == null ? s.notSignedIn : (session['display_name'] as String? ?? session['email'] as String? ?? s.signedInAs)),
              subtitle: Text(session == null ? (api.configured ? s.cloudConsentNote : s.backendNotConfigured) : (session['email'] as String? ?? s.signedInAs)),
              trailing: session == null
                  ? FilledButton(onPressed: api.configured ? () => showSignInSheet(context, ref) : null, child: Text(s.signIn))
                  : TextButton(onPressed: () => _signOut(context, ref), child: Text(s.signOut)),
            ),
            if (settings.demoMode)
              ListTile(
                leading: const Icon(Icons.science_outlined),
                title: Text(s.demoBadge),
                subtitle: Text(s.ar ? 'اضغط لمسح البيانات التجريبية والبدء من جديد' : 'Tap to clear demo data and start fresh'),
                onTap: () async {
                  await store.wipeAll();
                  if (context.mounted) context.go('/onboarding');
                },
              ),
          ]),

          section(s.theme),
          group([
            ListTile(
              leading: const Icon(Icons.language),
              title: Text(s.language),
              trailing: SegmentedButton<String>(
                segments: const [ButtonSegment(value: 'ar', label: Text('عربي')), ButtonSegment(value: 'en', label: Text('EN'))],
                selected: {settings.locale.languageCode},
                onSelectionChanged: (v) => store.setSetting(SettingKeys.locale, v.first),
                showSelectedIcon: false,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.dark_mode_outlined),
              title: Text(s.theme),
              trailing: DropdownButton<String>(
                value: raw[SettingKeys.themeMode] ?? 'system',
                underline: const SizedBox(),
                items: [DropdownMenuItem(value: 'system', child: Text(s.themeSystem)), DropdownMenuItem(value: 'light', child: Text(s.themeLight)), DropdownMenuItem(value: 'dark', child: Text(s.themeDark))],
                onChanged: (v) => store.setSetting(SettingKeys.themeMode, v!),
              ),
            ),
            SwitchListTile(secondary: const Icon(Icons.pin_outlined), title: Text(s.arabicDigits), value: settings.arabicDigits, onChanged: (v) => store.setSetting('arabic_digits', '$v')),
          ]),

          section(s.ar ? 'المال' : 'Money'),
          group([
            ListTile(
              leading: const Icon(Icons.event_repeat),
              title: Text(s.salaryDay),
              subtitle: Text(s.dayOfMonth(settings.cycleStartDay)),
              trailing: DropdownButton<int>(
                value: settings.cycleStartDay,
                underline: const SizedBox(),
                items: [for (var d = 1; d <= 31; d++) DropdownMenuItem(value: d, child: Text('$d'))],
                onChanged: (v) => store.setSetting(SettingKeys.cycleStartDay, '$v'),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.currency_exchange),
              title: Text(s.baseCurrencyLabel),
              trailing: DropdownButton<String>(
                value: settings.baseCurrency,
                underline: const SizedBox(),
                items: [for (final c in Currency.all) DropdownMenuItem(value: c.code, child: Text(c.code))],
                onChanged: (v) => store.setSetting(SettingKeys.baseCurrency, v!),
              ),
            ),
            ListTile(leading: const Icon(Icons.account_balance_outlined), title: Text(s.accounts), trailing: const Icon(Icons.chevron_right), onTap: () => context.push('/accounts')),
            ListTile(leading: const Icon(Icons.bolt_outlined), title: Text(s.dataAndCapture), trailing: const Icon(Icons.chevron_right), onTap: () => context.push('/capture')),
            ListTile(leading: const Icon(Icons.group_outlined), title: Text(s.household), trailing: const Icon(Icons.chevron_right), onTap: () => context.push('/household')),
          ]),

          section(s.notifications),
          group([
            ListTile(
              leading: const Icon(Icons.notifications_outlined),
              title: Text(s.notifications),
              subtitle: Text(raw['notif_permission'] == 'granted'
                  ? s.permissionGranted
                  : (raw['notif_permission'] == 'denied' ? (s.ar ? 'مرفوض. فعّله من إعدادات الجهاز' : 'Denied. Enable it in device settings') : s.permissionMissing)),
              trailing: raw['notif_permission'] == 'granted'
                  ? null
                  : TextButton(
                      onPressed: () async {
                        await ref.read(notificationSchedulerProvider).requestPermission();
                        await ref.read(notificationSchedulerProvider).reschedule(arabic: settings.ar, money: settings.fmt.money);
                      },
                      child: Text(s.ar ? 'السماح' : 'Allow')),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.event_repeat_outlined),
              title: Text(s.ar ? 'تذكير الفواتير والالتزامات' : 'Bill & recurring reminders'),
              value: raw['notif_bills'] != 'false',
              onChanged: (v) async {
                await store.setSetting('notif_bills', '$v');
                await ref.read(notificationSchedulerProvider).reschedule(arabic: settings.ar, money: settings.fmt.money);
              },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.pie_chart_outline),
              title: Text(s.ar ? 'تنبيهات تجاوز الميزانية' : 'Budget threshold alerts'),
              value: raw['notif_budgets'] != 'false',
              onChanged: (v) async {
                await store.setSetting('notif_budgets', '$v');
                await ref.read(notificationSchedulerProvider).reschedule(arabic: settings.ar, money: settings.fmt.money);
              },
            ),
          ]),

          section(s.privacy),
          group([
            SwitchListTile(
              secondary: const Icon(Icons.fingerprint),
              title: Text(s.biometricLock),
              subtitle: Text(s.biometricNote),
              value: settings.biometricLock,
              onChanged: (v) async {
                if (v) {
                  final la = LocalAuthentication();
                  final ok = await la.authenticate(localizedReason: s.unlock).catchError((_) => false);
                  if (!ok) return;
                }
                await store.setSetting(SettingKeys.biometricLock, '$v');
              },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.auto_awesome_outlined),
              title: Text(s.cloudAi),
              subtitle: Text(s.ar ? 'يُرسل نصاً منقحاً أو إجماليات فقط' : 'Sends sanitized text or totals only'),
              value: settings.aiCloud,
              onChanged: api.configured
                  ? (v) async {
                      await recordConsent(ref, 'cloud_ai', v);
                      await store.setSetting(SettingKeys.aiCloudEnabled, '$v');
                    }
                  : null,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.record_voice_over_outlined),
              title: Text(s.cloudVoice),
              subtitle: Text(s.ar ? 'Azure Speech. الصوت لا يُخزن' : 'Azure Speech. Audio is not stored'),
              value: raw[SettingKeys.voiceProvider] == 'azure',
              onChanged: api.configured
                  ? (v) async {
                      await recordConsent(ref, 'cloud_voice', v);
                      await store.setSetting(SettingKeys.voiceProvider, v ? 'azure' : 'device');
                    }
                  : null,
            ),
            ListTile(
              leading: const Icon(Icons.history_toggle_off),
              title: Text(s.rawRetention),
              trailing: DropdownButton<int>(
                value: int.tryParse(raw[SettingKeys.retainRawDays] ?? '') ?? 30,
                underline: const SizedBox(),
                items: [for (final d in [0, 7, 30]) DropdownMenuItem(value: d, child: Text(s.daysN(d)))],
                onChanged: (v) => store.setSetting(SettingKeys.retainRawDays, '$v'),
              ),
            ),
          ]),

          section(s.syncBackup),
          group([
            SwitchListTile(
              secondary: const Icon(Icons.cloud_sync_outlined),
              title: Text(s.cloudSync),
              subtitle: Text(session == null ? s.requiresSignInSync : s.cloudConsentNote),
              value: raw[SyncKeys.enabled] == 'true',
              onChanged: session == null ? null : (v) => _toggleSync(context, ref, v),
            ),
            _SyncStatusTile(),
          ]),

          section(s.ar ? 'بياناتي' : 'My data'),
          group([
            ListTile(leading: const Icon(Icons.ios_share), title: Text(s.exportData), onTap: () => _export(context, ref)),
            if (session != null) ListTile(leading: const Icon(Icons.devices_other), title: Text(s.devices), onTap: () => _sessions(context, ref)),
            ListTile(leading: const Icon(Icons.workspace_premium_outlined), title: Text(s.subscription), trailing: const Icon(Icons.chevron_right), onTap: () => context.push('/pro')),
            ListTile(
              leading: Icon(Icons.cleaning_services_outlined, color: p.warning),
              title: Text(s.wipeLocal),
              onTap: () => _confirm(context, s.wipeLocal, s.ar ? 'سيتم مسح كل البيانات من هذا الجهاز.' : 'All data on this device will be erased.', () async {
                await store.wipeAll();
                if (context.mounted) context.go('/onboarding');
              }),
            ),
            if (session != null)
              ListTile(
                leading: Icon(Icons.delete_forever_outlined, color: p.negative),
                title: Text(s.deleteAccount, style: TextStyle(color: p.negative)),
                onTap: () => _deleteAccount(context, ref),
              ),
          ]),

          section(s.about),
          group([
            ListTile(leading: const Icon(Icons.privacy_tip_outlined), title: Text(s.privacy), subtitle: const Text(AppConfig.privacyPolicyUrl)),
            ListTile(leading: const Icon(Icons.help_outline), title: Text(s.support), subtitle: const Text(AppConfig.supportUrl)),
            ListTile(leading: const Icon(Icons.info_outline), title: Text('${s.appName} · ${AppConfig.environment}'), subtitle: Text(s.ar ? 'لسنا تطبيقاً رسمياً لأي بنك.' : 'Not an official app of any bank.')),
          ]),
        ],
      ),
    );
  }

  Future<void> _toggleSync(BuildContext context, WidgetRef ref, bool v) async {
    final s = S.of(context);
    final store = ref.read(storeProvider);
    final engine = ref.read(syncEngineProvider);
    if (v) {
      final user = ref.read(sessionProvider).value;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(s.cloudSync),
          content: Text(s.ar
              ? 'سيتم رفع حساباتك وعملياتك وميزانياتك إلى خوادم فلس (مشفرة أثناء النقل والتخزين). الخادم يستطيع قراءتها لأغراض المزامنة، وهذا ليس تشفيراً من طرف إلى طرف. يمكنك الإيقاف في أي وقت.'
              : 'Your accounts, transactions and budgets will be uploaded to Fils servers (encrypted in transit and at rest). The server can read them to sync; this is not end-to-end encryption. You can turn it off anytime.'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.confirm))],
        ),
      );
      if (ok != true) return;
      if (user != null && !await engine.bindOwner(user['id'] as String)) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.ar ? 'بيانات هذا الجهاز تخص حساباً آخر. امسح البيانات المحلية أولاً.' : 'Local data belongs to another account. Erase local data first.')));
        }
        return;
      }
      await recordConsent(ref, 'cloud_sync', true);
      await store.setSetting(SyncKeys.enabled, 'true');
      await engine.enqueueAll();
      final r = await engine.sync();
      if (context.mounted && r.error != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.genericError)));
    } else {
      await recordConsent(ref, 'cloud_sync', false);
      await store.setSetting(SyncKeys.enabled, 'false');
    }
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final data = await exportAll(ref.read(storeProvider));
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    final j = File('${dir.path}/fils-export-$stamp.json')..writeAsStringSync(data['json']!);
    final c = File('${dir.path}/fils-transactions-$stamp.csv')..writeAsStringSync(data['csv']!);
    await SharePlus.instance.share(ShareParams(files: [XFile(j.path), XFile(c.path)], subject: 'Fils export'));
  }

  Future<void> _sessions(BuildContext context, WidgetRef ref) async {
    final s = S.of(context);
    final api = ref.read(apiProvider);
    List<dynamic> list = const [];
    try {
      list = await api.sessions();
    } catch (_) {}
    if (!context.mounted) return;
    await showFSheet(
      context,
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(s.devices, style: context.tt.titleLarge),
          for (final x in list.cast<Map>())
            ListTile(
              leading: Icon(x['platform'] == 'ios' ? Icons.phone_iphone : Icons.phone_android),
              title: Text('${x['device_name'] ?? x['platform'] ?? ''}${x['current'] == true ? ' · ${s.ar ? 'هذا الجهاز' : 'this device'}' : ''}'),
              subtitle: Text('${x['last_used_at'] ?? x['created_at'] ?? ''}'),
              trailing: x['current'] == true ? null : TextButton(onPressed: () async {
                await api.revokeSession(x['id'] as String);
                if (context.mounted) Navigator.pop(context);
              }, child: Text(s.remove)),
            ),
        ]),
      ),
    );
  }

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final s = S.of(context);
    final wipe = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.signOut),
        content: Text(s.ar ? 'هل تريد إبقاء البيانات على هذا الجهاز؟' : 'Keep your data on this device?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.wipeLocal)),
          FilledButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.ar ? 'إبقاء البيانات' : 'Keep data')),
        ],
      ),
    );
    if (wipe == null) return;
    await ref.read(sessionProvider.notifier).signOut(wipeLocal: wipe);
  }

  Future<void> _deleteAccount(BuildContext context, WidgetRef ref) async {
    final s = S.of(context);
    await _confirm(context, s.deleteAccount, s.deleteAccountBody, () async {
      final user = ref.read(sessionProvider).value;
      final provider = ((user?['identities'] as List?)?.firstOrNull as Map?)?['provider'] as String? ?? 'apple';
      try {
        final reauth = await ref.read(authServiceProvider).reauthenticate(provider);
        await ref.read(apiProvider).deleteAccount(reauth);
      } on ApiException catch (e) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${s.genericError} (${e.code})')));
        return;
      } catch (_) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.genericError)));
        return;
      }
      await ref.read(apiProvider).tokens.clear();
      await ref.read(storeProvider).wipeAll();
      await DatabaseOpener.destroy().catchError((_) {});
      await ref.read(sessionProvider.notifier).set(null);
      if (context.mounted) context.go('/onboarding');
    });
  }

  Future<void> _confirm(BuildContext context, String title, String body, Future<void> Function() action) async {
    final s = S.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: context.fp.negative), onPressed: () => Navigator.pop(ctx, true), child: Text(s.confirm)),
        ],
      ),
    );
    if (ok == true) await action();
  }
}

class _SyncStatusTile extends ConsumerStatefulWidget {
  @override
  ConsumerState<_SyncStatusTile> createState() => _SyncStatusTileState();
}

class _SyncStatusTileState extends ConsumerState<_SyncStatusTile> {
  int pending = 0;
  int conflicts = 0;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final e = ref.read(syncEngineProvider);
    final p = await e.pendingCount();
    final c = (await e.conflicts()).length;
    if (mounted) setState(() {
      pending = p;
      conflicts = c;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final on = ref.watch(settingsProvider).raw[SyncKeys.enabled] == 'true';
    final last = ref.watch(settingsProvider).raw[SyncKeys.lastSyncAt];
    return Column(children: [
      ListTile(
        leading: const Icon(Icons.sync),
        title: Text(s.syncStatus),
        subtitle: Text(!on ? s.syncOff : (pending == 0 ? '${s.upToDate}${last != null ? ' · ${last.substring(0, 16).replaceAll('T', ' ')}' : ''}' : s.pendingChanges(pending))),
        trailing: on
            ? (busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : TextButton(
                    onPressed: () async {
                      setState(() => busy = true);
                      await ref.read(syncEngineProvider).sync();
                      await _load();
                      if (mounted) setState(() => busy = false);
                    },
                    child: Text(s.syncNow)))
            : null,
      ),
      if (conflicts > 0)
        ListTile(
          leading: Icon(Icons.warning_amber, color: context.fp.warning),
          title: Text('${s.conflicts} ($conflicts)'),
          onTap: () async {
            final e = ref.read(syncEngineProvider);
            final list = await e.conflicts();
            if (!context.mounted) return;
            await showFSheet(
              context,
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  for (final c in list)
                    ListTile(
                      title: Text('${c.entity} ${c.entityId.substring(0, 8)}'),
                      subtitle: Text(s.ar ? 'تم تعديله على جهاز آخر' : 'Changed on another device too'),
                      trailing: Wrap(children: [
                        TextButton(onPressed: () async {
                          await e.resolveConflict(c, keepMine: true);
                          if (context.mounted) Navigator.pop(context);
                        }, child: Text(s.ar ? 'نسختي' : 'Keep mine')),
                        TextButton(onPressed: () async {
                          await e.resolveConflict(c, keepMine: false);
                          if (context.mounted) Navigator.pop(context);
                        }, child: Text(s.ar ? 'نسخة السحابة' : 'Use cloud')),
                      ]),
                    ),
                ]),
              ),
            );
            await _load();
          },
        ),
    ]);
  }
}
