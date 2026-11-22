import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/config.dart';
import '../../app/providers.dart';
import '../../app/services.dart';
import '../../core/import/csv_import.dart';
import '../../core/parsing/bank_registry.dart';
import '../../core/parsing/models.dart';
import '../../core/time/kuwait_time.dart';
import '../../data/db/database.dart';
import '../../data/import_export.dart';
import '../../data/ingestion.dart';
import '../../data/store.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import 'capture_status.dart';

class CaptureScreen extends ConsumerStatefulWidget {
  const CaptureScreen({super.key});
  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends ConsumerState<CaptureScreen> with WidgetsBindingObserver {
  bool? notifAccess;
  Map<String, dynamic> listener = const {};
  List<String> monitored = const [];
  bool? batteryOk;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
      ref.read(captureServiceProvider).drain();
    }
  }

  Future<void> _refresh() async {
    final b = ref.read(captureBridgeProvider);
    if (!Platform.isAndroid) return;
    try {
      final a = await b.notificationAccessGranted();
      final l = await b.listenerStatus();
      final m = await b.monitoredPackages();
      final bat = await b.ignoringBatteryOptimizations();
      if (mounted) {
        setState(() {
          notifAccess = a;
          listener = l;
          monitored = m;
          batteryOk = bat;
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.captureSetup)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          const CapturePipelineStatus(),
          const SizedBox(height: 12),
          if (Platform.isIOS) ..._ios(context),
          if (Platform.isAndroid) ..._android(context),
          if (!Platform.isIOS && !Platform.isAndroid) FCard(child: Text(s.ar ? 'الالتقاط التلقائي متاح على iOS وAndroid.' : 'Auto-capture is available on iOS and Android.')),
          const SizedBox(height: 16),
          _Section(
            icon: Icons.content_paste_rounded,
            title: s.pasteTitle,
            body: s.pasteBody,
            child: FilledButton.tonalIcon(onPressed: () => _paste(context), icon: const Icon(Icons.content_paste_go), label: Text(s.pasteTitle)),
          ),
          const SizedBox(height: 12),
          _Section(
            icon: Icons.table_chart_outlined,
            title: s.importFileTitle,
            body: s.ar ? 'CSV يتم على جهازك. ملفات PDF والصور تتطلب تفعيل الذكاء السحابي.' : 'CSV is processed on your device. PDF and images need cloud processing (opt-in).',
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.tonalIcon(onPressed: () => _importCsv(context), icon: const Icon(Icons.upload_file), label: const Text('CSV')),
              OutlinedButton.icon(
                onPressed: ref.watch(apiProvider).configured && ref.watch(sessionProvider).value != null && ref.watch(settingsProvider).aiCloud
                    ? () => _importDocument(context)
                    : null,
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: Text(s.ar ? 'PDF / صورة' : 'PDF / image'),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          _CoverageCard(),
        ],
      ),
    );
  }

  List<Widget> _ios(BuildContext context) {
    final s = S.of(context);
    final p = context.fp;
    final testAt = DateTime.tryParse(ref.watch(settingsProvider).raw[SettingKeys.shortcutTestReceivedAt] ?? '');
    final steps = s.ar
        ? [
            'افتح تطبيق الاختصارات ← الأتمتة ← "+" ← أتمتة شخصية جديدة.',
            'اختر "رسالة". في "المرسل" اختر جهة البنك (مثل NBK أو KFH)، أو استخدم "الرسالة تحتوي" مع كلمة مثل KWD أو د.ك.',
            'اختر "تشغيل فوراً" إن توفر، ثم "التالي".',
            'أضف إجراء "Import Bank Message" من فلس.',
            'اضغط على حقل "Message Text" واختر متغير "مُدخل الاختصار" (محتوى الرسالة).',
            'احفظ. كرر لكل بنك (أو استخدم شرط "تحتوي KWD").',
          ]
        : [
            'Open Shortcuts → Automation → "+" → New personal automation.',
            'Choose "Message". Set Sender to your bank (e.g. NBK, KFH), or use "Message Contains" with a keyword such as KWD.',
            'Choose "Run Immediately" if offered, then Next.',
            'Add the action "Import Bank Message" (Fils).',
            'Tap "Message Text" and choose the "Shortcut Input" variable (the message content).',
            'Save. Repeat per bank (or use a single "contains KWD" rule).',
          ];
    return [
      _Section(
        icon: Icons.sms_outlined,
        title: s.iosShortcutTitle,
        body: s.iosShortcutBody,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final (i, st) in steps.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                CircleAvatar(radius: 11, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
                const SizedBox(width: 10),
                Expanded(child: Text(st, style: context.tt.bodyMedium)),
              ]),
            ),
          const SizedBox(height: 10),
          OutlinedButton.icon(onPressed: () => ref.read(captureBridgeProvider).openShortcutsApp(), icon: const Icon(Icons.open_in_new), label: Text(s.openShortcuts)),
          const SizedBox(height: 10),
          FCard(
            color: testAt != null ? p.positiveBg : p.surfaceMuted,
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Icon(testAt != null ? Icons.check_circle : Icons.hourglass_empty, color: testAt != null ? p.positive : p.inkSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  testAt != null
                      ? s.testReceived
                      : (s.ar ? '${s.sendTest}: شغّل اختصار "Test Fils Capture" من تطبيق الاختصارات ثم ارجع هنا.' : '${s.sendTest}: run the "Test Fils Capture" shortcut in Shortcuts, then come back.'),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(s.troubleshooting),
            children: [
              for (final t in (s.ar
                  ? [
                      'إذا طلب الآيفون تأكيداً كل مرة، فعّل "تشغيل فوراً" وأطفئ "الإشعار عند التشغيل" (حسب إصدار iOS).',
                      'الرسائل تُحفظ في صندوق فلس وتُعالج عند فتح التطبيق. هذا طبيعي.',
                      'إذا كان الجهاز مقفلاً منذ إعادة التشغيل ولم يُفتح بعد، قد لا تعمل الأتمتة حتى أول فتح.',
                      'تأكد أن حقل Message Text مربوط بمحتوى الرسالة وليس فارغاً.',
                      'فلس لا يستطيع قراءة كل رسائلك، فقط ما ترسله له الأتمتة.',
                    ]
                  : [
                      'If iPhone asks for confirmation every time, enable "Run Immediately" and turn off "Notify When Run" (varies by iOS version).',
                      'Messages are saved to the Fils inbox and processed when you open the app. That is expected.',
                      'Right after a restart, automations may not run until you unlock the phone once.',
                      'Make sure "Message Text" is linked to the message content, not empty.',
                      'Fils cannot read your inbox, only what the automation sends it.',
                    ]))
                ListTile(dense: true, leading: const Icon(Icons.info_outline, size: 18), title: Text(t)),
            ],
          ),
        ]),
      ),
      const SizedBox(height: 12),
      _Section(
        icon: Icons.contactless_outlined,
        title: s.iosWalletTitle,
        body: s.iosWalletBody,
        child: Text(
          s.ar
              ? 'الاختصارات ← الأتمتة ← "+" ← "المعاملة" ← اختر البطاقات ← أضف "Import Apple Pay Transaction" واربط التاجر والمبلغ والبطاقة. إذا وصلت رسالة البنك لنفس العملية، يتم دمجهما تلقائياً.'
              : 'Shortcuts → Automation → "+" → "Transaction" → pick cards → add "Import Apple Pay Transaction" and map Merchant, Amount and Card. If the bank SMS for the same purchase also arrives, they are merged automatically.',
          style: context.tt.bodySmall,
        ),
      ),
    ];
  }

  List<Widget> _android(BuildContext context) {
    final s = S.of(context);
    final p = context.fp;
    final b = ref.read(captureBridgeProvider);
    final last = (listener['lastEventAt'] as num?)?.toInt() ?? 0;
    return [
      _Section(
        icon: Icons.notifications_active_outlined,
        title: s.androidNotifTitle,
        body: s.androidNotifBody,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(notifAccess == true ? Icons.check_circle : Icons.error_outline, color: notifAccess == true ? p.positive : p.warning),
            title: Text(notifAccess == true ? s.permissionGranted : s.permissionMissing),
            subtitle: Text(notifAccess == true
                ? '${listener['connected'] == true ? s.monitoring : s.notMonitoring}${last > 0 ? ' · ${s.lastCaptured(DateTime.fromMillisecondsSinceEpoch(last).toString().substring(0, 16))}' : ''}'
                : ''),
            trailing: TextButton(onPressed: () => b.openNotificationAccessSettings(), child: Text(s.openSettings)),
          ),
          OutlinedButton.icon(onPressed: () => _pickApps(context), icon: const Icon(Icons.apps), label: Text('${s.chooseBankApps} (${monitored.length})')),
          if (notifAccess == true && listener['connected'] != true)
            TextButton(onPressed: () => b.requestRebind(), child: Text(s.ar ? 'إعادة الاتصال بالخدمة' : 'Reconnect listener')),
          if (batteryOk == false)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.battery_alert, color: p.warning),
              title: Text(s.batteryTip),
              trailing: TextButton(onPressed: () => b.openBatterySettings(), child: Text(s.openSettings)),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      FutureBuilder<bool>(
        future: b.smsCaptureAvailable(),
        builder: (_, snap) => _Section(
          icon: Icons.sms_outlined,
          title: s.androidSmsTitle,
          body: AppConfig.androidFlavor == 'sms' ? (snap.data == true ? s.permissionGranted : s.permissionMissing) : s.androidSmsUnavailable,
        ),
      ),
    ];
  }

  Future<void> _pickApps(BuildContext context) async {
    final s = S.of(context);
    final b = ref.read(captureBridgeProvider);
    final apps = await b.launchableApps();
    final selected = {...monitored};
    if (!context.mounted) return;
    final hints = kuwaitBanks.expand((k) => k.textHints).toList();
    apps.sort((x, y) {
      bool bank(Map<String, String> a) => hints.any((h) => (a['label'] ?? '').toLowerCase().contains(h)) || (a['label'] ?? '').toLowerCase().contains('bank');
      return (bank(y) ? 1 : 0) - (bank(x) ? 1 : 0);
    });
    await showFSheet(
      context,
      StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(s.chooseBankApps, style: context.tt.titleLarge),
            Text(s.androidNotifBody, style: context.tt.bodySmall),
            const SizedBox(height: 8),
            for (final a in apps)
              CheckboxListTile(
                value: selected.contains(a['package']),
                title: Text(a['label'] ?? a['package']!),
                subtitle: Text(a['package']!, style: context.tt.bodySmall),
                onChanged: (v) => set(() => v == true ? selected.add(a['package']!) : selected.remove(a['package'])),
              ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () async {
                await b.setMonitoredPackages(selected.toList());
                await ref.read(storeProvider).setSetting(SettingKeys.monitoredPackages, jsonEncode(selected.toList()));
                if (ctx.mounted) Navigator.pop(ctx);
                _refresh();
              },
              child: Text(s.save),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _paste(BuildContext context) async {
    final s = S.of(context);
    final ctrl = TextEditingController();
    final ok = await showFSheet<bool>(
      context,
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(s.pasteTitle, style: context.tt.titleLarge),
          Text(s.ar ? 'افصل بين الرسائل بسطر فارغ.' : 'Separate messages with a blank line.', style: context.tt.bodySmall),
          const SizedBox(height: 8),
          TextField(controller: ctrl, maxLines: 10, minLines: 5, decoration: InputDecoration(hintText: s.pasteBody)),
          const SizedBox(height: 12),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(s.import)),
        ]),
      ),
    );
    if (ok != true || ctrl.text.trim().isEmpty) return;
    final ing = ref.read(ingestionWithAiProvider);
    final parts = ctrl.text.split(RegExp(r'\n\s*\n')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    var posted = 0, review = 0, ignored = 0;
    for (final ptxt in parts) {
      final r = await ing.ingest(RawEvent(text: ptxt, receivedAt: DateTime.now().toUtc(), source: SourceKind.paste));
      switch (r.outcome) {
        case IngestOutcome.posted || IngestOutcome.merged || IngestOutcome.settledPending:
          posted++;
        case IngestOutcome.review || IngestOutcome.possibleDuplicate:
          review++;
        default:
          ignored++;
      }
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(s.ar ? 'تم: $posted، للمراجعة: $review، متجاهلة: $ignored' : 'Imported $posted · to review $review · ignored $ignored'),
        action: review > 0 ? SnackBarAction(label: s.reviewInbox, onPressed: () => context.push('/review')) : null,
      ));
    }
  }

  Future<void> _importCsv(BuildContext context) async {
    final s = S.of(context);
    final res = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['csv', 'txt']);
    final f = res.firstOrNull;
    if (f == null) return;
    if ((await f.length() ?? 0) > 5 * 1024 * 1024) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.ar ? 'الملف كبير جداً (الحد ٥ ميجابايت)' : 'File too large (5 MB max)')));
      return;
    }
    final parsed = parseCsvStatement(utf8.decode(await f.readAsBytes(), allowMalformed: true), defaultCurrency: ref.read(settingsProvider).baseCurrency);
    if (!context.mounted) return;
    final accounts = ref.read(accountsProvider).value ?? const <AccountRow>[];
    String? acct = accounts.where((a) => a.isDefault).firstOrNull?.id ?? accounts.firstOrNull?.id;
    final fmt = ref.read(settingsProvider).fmt;
    final go = await showFSheet<bool>(
      context,
      StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${s.importFileTitle} · ${parsed.rows.length}', style: context.tt.titleLarge),
            if (parsed.errors.isNotEmpty) Text(parsed.errors.take(3).join('\n'), style: TextStyle(color: context.fp.negative)),
            DropdownButtonFormField<String>(
              initialValue: acct,
              decoration: InputDecoration(labelText: s.account),
              items: [for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name))],
              onChanged: (v) => set(() => acct = v),
            ),
            const SizedBox(height: 8),
            for (final r in parsed.rows.take(8))
              ListTile(
                dense: true,
                title: Text(r.description, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(fmt.dayMonthYear(ReportingZone.kuwait.toWall(r.occurredAt))),
                trailing: Text(fmt.money(r.credit ? r.amountMinor : -r.amountMinor, r.currency)),
              ),
            if (parsed.rows.length > 8) Text('… +${parsed.rows.length - 8}'),
            const SizedBox(height: 12),
            FilledButton(onPressed: acct == null || parsed.rows.isEmpty ? null : () => Navigator.pop(ctx, true), child: Text(s.import)),
          ]),
        ),
      ),
    );
    if (go != true || acct == null) return;
    final sum = await importCsvRows(ref.read(storeProvider), acct!, parsed.rows);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.ar ? 'تم استيراد ${sum.imported}، مكرر ${sum.duplicates}' : 'Imported ${sum.imported} · skipped ${sum.duplicates} duplicates')));
    }
  }
}

extension on _CaptureScreenState {
  Future<void> _importDocument(BuildContext context) async {
    final s = S.of(context);
    final res = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg', 'csv']);
    final f = res.firstOrNull;
    if (f == null) return;
    if ((await f.length() ?? 0) > 10 * 1024 * 1024) return;
    final api = ref.read(apiProvider);
    try {
      var job = await api.uploadDocument(await f.readAsBytes(), f.name);
      for (var i = 0; i < 30 && (job['status'] == 'queued' || job['status'] == 'running'); i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        job = await api.job(job['id'] as String);
      }
      if (job['status'] != 'succeeded') throw Exception(job['error'] ?? 'failed');
      final rows = <CsvCandidate>[];
      var line = 0;
      for (final r in ((job['result'] as Map?)?['rows'] as List? ?? job['result'] as List? ?? const []).cast<Map>()) {
        line++;
        final d = DateTime.tryParse('${r['occurred_on']}');
        final amt = (r['amount_minor'] as num?)?.toInt();
        if (d == null || amt == null || amt == 0) continue;
        rows.add(CsvCandidate(ReportingZone.kuwait.fromWall(d.year, d.month, d.day, 12), '${r['description'] ?? ''}', amt.abs(), r['direction'] == 'credit', '${r['currency'] ?? 'KWD'}', line));
      }
      if (!context.mounted) return;
      final accounts = ref.read(accountsProvider).value ?? const <AccountRow>[];
      final acct = accounts.where((a) => a.isDefault).firstOrNull?.id ?? accounts.firstOrNull?.id;
      if (acct == null || rows.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.noTransactions)));
        return;
      }
      // Preview + confirm, then the same duplicate-safe import as CSV.
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${s.importFileTitle} · ${rows.length}'),
          content: SizedBox(width: 320, child: ListView(shrinkWrap: true, children: [for (final r in rows.take(10)) ListTile(dense: true, title: Text(r.description, maxLines: 1), trailing: Text(ref.read(settingsProvider).fmt.money(r.credit ? r.amountMinor : -r.amountMinor, r.currency)))])),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.import))],
        ),
      );
      if (ok != true) return;
      final sum = await importCsvRows(ref.read(storeProvider), acct, rows);
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${sum.imported} · ${sum.duplicates}')));
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.genericError)));
    }
  }
}

class _Section extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Widget? child;
  const _Section({required this.icon, required this.title, required this.body, this.child});
  @override
  Widget build(BuildContext context) => FCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [Icon(icon, color: Theme.of(context).colorScheme.primary), const SizedBox(width: 10), Expanded(child: Text(title, style: context.tt.titleMedium))]),
          const SizedBox(height: 6),
          Text(body, style: context.tt.bodyMedium?.copyWith(color: context.fp.inkSecondary)),
          if (child != null) ...[const SizedBox(height: 12), child!],
        ]),
      );
}

class _CoverageCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    String status(ValidationStatus v) => switch (v) {
          ValidationStatus.syntheticTested => s.coverageSynthetic,
          ValidationStatus.realSampleTested => s.coverageReal,
          ValidationStatus.deviceVerified => s.coverageDevice,
        };
    return FCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(s.bankCoverage, style: context.tt.titleMedium),
        const SizedBox(height: 4),
        Text(s.coverageNote, style: context.tt.bodySmall?.copyWith(color: context.fp.inkSecondary)),
        const SizedBox(height: 8),
        for (final b in kuwaitBanks)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: BankBadge(code: b.shortCode, color: Color(b.brandColor), size: 32),
            title: Text(s.ar ? b.nameAr : b.nameEn),
            subtitle: Text(status(b.validation)),
          ),
      ]),
    );
  }
}
