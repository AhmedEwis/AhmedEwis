import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/config.dart';
import '../../app/providers.dart';
import '../../app/services.dart';
import '../../core/parsing/bank_registry.dart';
import '../../data/demo/demo_seed.dart';
import '../../data/store.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/theme/tokens.dart';
import '../../ui/widgets/common.dart';
import '../auth/sign_in_sheet.dart';
import '../settings/settings_screen.dart';

/// Onboarding: language → welcome → privacy → accounts → salary cycle → capture.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});
  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  int step = 0;
  final selectedBanks = <String>{};
  int salaryDay = 25;
  bool seeding = false;

  Future<void> _finish() async {
    final store = ref.read(storeProvider);
    for (final id in selectedBanks) {
      final b = bankById(id)!;
      final existing = (await store.accounts()).where((a) => a.institutionId == id);
      if (existing.isEmpty) {
        await store.createAccount(name: b.nameEn, kind: 'bank', currency: 'KWD', institutionId: id, color: b.brandColor);
      }
    }
    await store.setSetting(SettingKeys.cycleStartDay, '$salaryDay');
    await store.setSetting(SettingKeys.onboarded, 'true');
    await recordConsent(ref, 'local_processing', true);
    if (mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = context.fp;
    final store = ref.watch(storeProvider);
    final settings = ref.watch(settingsProvider);
    Widget page;
    switch (step) {
      case 0:
        page = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: PopupMenuButton<String>(
              onSelected: (v) => store.setSetting(SettingKeys.locale, v),
              itemBuilder: (_) => const [PopupMenuItem(value: 'ar', child: Text('العربية')), PopupMenuItem(value: 'en', child: Text('English'))],
              child: Chip(avatar: const Icon(Icons.language, size: 18), label: Text(settings.ar ? 'العربية' : 'English')),
            ),
          ),
          const Spacer(),
          Text(s.obTitle1, style: context.tt.displayMedium),
          Text(s.obTitle2, style: context.tt.displayMedium?.copyWith(color: Theme.of(context).colorScheme.primary)),
          const SizedBox(height: 12),
          Text(s.obSubtitle, style: context.tt.bodyLarge?.copyWith(color: p.inkSecondary)),
          const SizedBox(height: 28),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final b in kuwaitBanks)
              Container(
                padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
                decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(FilsRadius.pill), border: Border.all(color: p.border)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  BankBadge(code: b.shortCode, color: Color(b.brandColor), size: 32),
                  const SizedBox(width: 8),
                  Text(s.ar ? b.nameAr : b.nameEn, style: context.tt.labelLarge),
                ]),
              ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Icon(Icons.info_outline, size: 18, color: p.inkSecondary),
            const SizedBox(width: 6),
            Expanded(child: Text(s.coverageNote, style: context.tt.bodySmall?.copyWith(color: p.inkSecondary))),
          ]),
          const Spacer(),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: () => setState(() => step = 1), child: Text(s.getStarted))),
          if (AppConfig.allowDemo)
            Center(
              child: TextButton(
                onPressed: seeding
                    ? null
                    : () async {
                        setState(() => seeding = true);
                        await DemoSeeder(store).seed();
                        if (context.mounted) context.go('/');
                      },
                child: seeding ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(s.tryDemo),
              ),
            ),
        ]);
      case 1:
        page = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Spacer(),
          const Text('🔒', style: TextStyle(fontSize: 56)),
          const SizedBox(height: 12),
          Text(s.obPrivacyTitle, style: context.tt.headlineMedium),
          const SizedBox(height: 12),
          Text(s.obPrivacyBody, style: context.tt.bodyLarge?.copyWith(color: p.inkSecondary)),
          const SizedBox(height: 20),
          if (ref.watch(apiProvider).configured) ...[
            OutlinedButton.icon(
              onPressed: () => showSignInSheet(context, ref),
              icon: const Icon(Icons.person_outline),
              label: Text(ref.watch(sessionProvider).value == null ? s.signIn : s.signedInAs),
            ),
            const SizedBox(height: 6),
            Text(s.cloudConsentNote, style: context.tt.bodySmall?.copyWith(color: p.inkSecondary)),
          ],
          const Spacer(),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: () => setState(() => step = 2), child: Text(ref.watch(sessionProvider).value == null ? s.continueWithoutAccount : s.next))),
        ]);
      case 2:
        page = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 20),
          Text(s.obAccountsTitle, style: context.tt.headlineMedium),
          const SizedBox(height: 8),
          Text(s.obAccountsBody, style: context.tt.bodyLarge?.copyWith(color: p.inkSecondary)),
          const SizedBox(height: 20),
          Expanded(
            child: ListView(children: [
              for (final b in kuwaitBanks)
                CheckboxListTile(
                  value: selectedBanks.contains(b.id),
                  onChanged: (v) => setState(() => v == true ? selectedBanks.add(b.id) : selectedBanks.remove(b.id)),
                  secondary: BankBadge(code: b.shortCode, color: Color(b.brandColor)),
                  title: Text(s.ar ? b.nameAr : b.nameEn),
                ),
            ]),
          ),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: () => setState(() => step = 3), child: Text(s.next))),
        ]);
      case 3:
        page = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Spacer(),
          const Text('💰', style: TextStyle(fontSize: 56)),
          Text(s.obSalaryTitle, style: context.tt.headlineMedium),
          const SizedBox(height: 8),
          Text(s.obSalaryBody, style: context.tt.bodyLarge?.copyWith(color: p.inkSecondary)),
          const SizedBox(height: 24),
          Center(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton.filledTonal(onPressed: () => setState(() => salaryDay = salaryDay <= 1 ? 31 : salaryDay - 1), icon: const Icon(Icons.remove)),
              const SizedBox(width: 20),
              Text('$salaryDay', style: context.tt.displayLarge),
              const SizedBox(width: 20),
              IconButton.filledTonal(onPressed: () => setState(() => salaryDay = salaryDay >= 31 ? 1 : salaryDay + 1), icon: const Icon(Icons.add)),
            ]),
          ),
          Center(child: Text(s.dayOfMonth(salaryDay), style: context.tt.bodyMedium)),
          const Spacer(),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: () => setState(() => step = 4), child: Text(s.next))),
        ]);
      default:
        page = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Spacer(),
          const Text('⚡', style: TextStyle(fontSize: 56)),
          Text(s.obCaptureTitle, style: context.tt.headlineMedium),
          const SizedBox(height: 8),
          Text(Theme.of(context).platform == TargetPlatform.iOS ? s.iosShortcutBody : s.androidNotifBody, style: context.tt.bodyLarge?.copyWith(color: p.inkSecondary)),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () async {
              await _finish();
              if (context.mounted) context.push('/capture');
            },
            icon: const Icon(Icons.bolt),
            label: Text(s.setUp),
          ),
          const Spacer(),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: _finish, child: Text(s.done))),
        ]);
    }
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
          child: Column(children: [
            if (step > 0)
              Row(children: [
                IconButton(onPressed: () => setState(() => step--), icon: Icon(context.isRtl ? Icons.arrow_forward : Icons.arrow_back), tooltip: s.back),
                Expanded(child: LinearProgressIndicator(value: step / 4, borderRadius: BorderRadius.circular(4))),
                const SizedBox(width: 12),
              ]),
            Expanded(child: page),
          ]),
        ),
      ),
    );
  }
}
