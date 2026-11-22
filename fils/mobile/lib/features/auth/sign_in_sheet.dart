import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config.dart';
import '../../app/services.dart';
import '../../data/api/api_client.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';

Future<bool> showSignInSheet(BuildContext context, WidgetRef ref) async =>
    (await showFSheet<bool>(context, const SignInPanel())) ?? false;

/// Sign in with Apple / Google. Signing in is NOT consent to upload data: sync and
/// backup are separate switches with their own explanation.
class SignInPanel extends ConsumerStatefulWidget {
  const SignInPanel({super.key});
  @override
  ConsumerState<SignInPanel> createState() => _SignInPanelState();
}

class _SignInPanelState extends ConsumerState<SignInPanel> {
  bool busy = false;
  String? error;

  Future<void> _run(Future<Map<String, dynamic>> Function() f) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final r = await f();
      await ref.read(sessionProvider.notifier).set((r['user'] as Map?)?.cast<String, dynamic>());
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() => error = e.notConfigured || e.status == 0 ? S.of(context).backendNotConfigured : '${S.of(context).genericError} (${e.code})');
    } catch (e) {
      // User-cancelled flows end here too.
      setState(() => error = '$e'.contains('cancel') ? null : S.of(context).genericError);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final auth = ref.read(authServiceProvider);
    final api = ref.read(apiProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(s.signIn, style: context.tt.titleLarge),
        const SizedBox(height: 6),
        Text(s.cloudConsentNote, style: context.tt.bodyMedium?.copyWith(color: context.fp.inkSecondary)),
        const SizedBox(height: 20),
        if (!api.configured) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(s.backendNotConfigured, style: TextStyle(color: context.fp.warning))),
        if (Platform.isIOS || Platform.isMacOS)
          FilledButton.icon(onPressed: busy || !api.configured ? null : () => _run(auth.signInWithApple), icon: const Icon(Icons.apple), label: Text(s.signInWithApple)),
        const SizedBox(height: 10),
        OutlinedButton.icon(onPressed: busy || !api.configured ? null : () => _run(auth.signInWithGoogle), icon: const Text('G', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)), label: Text(s.signInWithGoogle)),
        if (!AppConfig.isProduction && api.configured) ...[
          const SizedBox(height: 10),
          // Development/staging only. The server also refuses demo sessions in production.
          TextButton(onPressed: busy ? null : () => _run(api.demoSession), child: Text(s.ar ? 'جلسة تجريبية (تطوير فقط)' : 'Demo session (development only)')),
        ],
        if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: Center(child: CircularProgressIndicator())),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: TextStyle(color: context.fp.negative))),
      ]),
    );
  }
}
