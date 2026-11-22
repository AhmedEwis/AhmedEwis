import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/services.dart';
import '../../data/voice/speech_service.dart';
import '../../core/ledger/ledger.dart';
import '../../core/voice/voice_parser.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import '../transactions/add_transaction_sheet.dart';

enum VoiceStage { idle, listening, processing, error }

/// Push-to-talk voice entry. Holding the button records (with a visible recording state);
/// releasing stops. The transcript is editable, and the parsed draft opens in an editable
/// confirmation sheet. Nothing is saved without confirmation. Raw audio is never kept.
class VoiceScreen extends ConsumerStatefulWidget {
  const VoiceScreen({super.key});
  @override
  ConsumerState<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends ConsumerState<VoiceScreen> with SingleTickerProviderStateMixin {
  VoiceStage stage = VoiceStage.idle;
  String transcript = '';
  String? error;
  final textCtrl = TextEditingController();
  late final AnimationController pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  SpeechProvider? _speech; // cached: `ref` must not be used in dispose()

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _speech = ref.read(speechProvider);
  }

  @override
  void dispose() {
    pulse.dispose();
    // Leaving the screen always releases the microphone (no hidden recording).
    _speech?.cancel().catchError((_) {}); // best-effort on teardown
    super.dispose();
  }

  Future<void> _start() async {
    final s = S.of(context);
    final sp = ref.read(speechProvider);
    setState(() {
      error = null;
      transcript = '';
    });
    if (!await sp.requestPermission()) {
      setState(() {
        stage = VoiceStage.error;
        error = s.voiceMicDenied;
      });
      return;
    }
    try {
      setState(() => stage = VoiceStage.listening);
      await sp.start(locale: ref.read(settingsProvider).ar ? 'ar-KW' : 'en-US', onPartial: (t) => setState(() => transcript = t));
    } catch (e) {
      setState(() {
        stage = VoiceStage.error;
        error = '$e'.contains('permission') ? s.voiceMicDenied : s.voiceUnavailable;
      });
    }
  }

  Future<void> _stop() async {
    if (stage != VoiceStage.listening) return;
    final s = S.of(context);
    setState(() => stage = VoiceStage.processing);
    final r = await ref.read(speechProvider).stop();
    if (!mounted) return;
    if (r.error != null) {
      setState(() {
        stage = VoiceStage.error;
        error = r.error == 'no_speech' ? s.voiceNoSpeech : (r.error == 'provider_not_configured' ? s.backendNotConfigured : s.genericError);
      });
      return;
    }
    textCtrl.text = r.text;
    setState(() {
      transcript = r.text;
      stage = VoiceStage.idle;
    });
    await _toDraft(r.text);
  }

  Future<void> _toDraft(String text) async {
    if (text.trim().isEmpty) return;
    final s = S.of(context);
    final base = ref.read(settingsProvider).baseCurrency;
    final d = VoiceParser(currency: base).parse(text);
    if (!d.complete && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.voiceAmountMissing)));
    }
    if (!mounted) return;
    final id = await showAddTransactionSheet(
      context,
      ref,
      draft: TxDraft(
        kind: d.income ? TxKinds.income : TxKinds.expense,
        amountMinor: d.amountMinor,
        currency: base,
        merchant: d.merchant,
        categoryId: d.categoryId,
        note: text,
        source: 'voice',
      ),
    );
    if (id != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.saved)));
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = context.fp;
    final listening = stage == VoiceStage.listening;
    return Scaffold(
      appBar: AppBar(title: Text(s.voiceTitle)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Text(s.voiceHint, textAlign: TextAlign.center, style: context.tt.bodyMedium?.copyWith(color: p.inkSecondary)),
              const SizedBox(height: 24),
              Expanded(
                child: Center(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      transcript.isEmpty
                          ? (listening ? s.listening : (stage == VoiceStage.processing ? s.processing : (error ?? '')))
                          : transcript,
                      textAlign: TextAlign.center,
                      style: context.tt.headlineMedium?.copyWith(color: error != null && transcript.isEmpty ? p.negative : null),
                    ),
                  ),
                ),
              ),
              if (listening)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Container(width: 10, height: 10, decoration: BoxDecoration(color: p.negative, shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Text(s.recordingIndicator, style: TextStyle(color: p.negative, fontWeight: FontWeight.w600)),
                  ]),
                ),
              Semantics(
                button: true,
                label: listening ? s.stop : s.tapToSpeak,
                child: GestureDetector(
                  onLongPressStart: (_) => _start(),
                  onLongPressEnd: (_) => _stop(),
                  onTap: () => listening ? _stop() : _start(),
                  child: AnimatedBuilder(
                    animation: pulse,
                    builder: (_, child) => Container(
                      width: 96 + (listening ? pulse.value * 16 : 0),
                      height: 96 + (listening ? pulse.value * 16 : 0),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: listening ? p.negative : Theme.of(context).colorScheme.primary,
                        boxShadow: [BoxShadow(color: (listening ? p.negative : Theme.of(context).colorScheme.primary).withValues(alpha: 0.35), blurRadius: 24)],
                      ),
                      child: Icon(listening ? Icons.stop_rounded : Icons.mic_rounded, color: Colors.white, size: 44),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(listening ? s.listening : s.tapToSpeak, style: context.tt.labelLarge),
              if (listening) TextButton(onPressed: () async {
                await ref.read(speechProvider).cancel();
                setState(() => stage = VoiceStage.idle);
              }, child: Text(s.cancel)),
              const SizedBox(height: 20),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: textCtrl,
                    decoration: InputDecoration(hintText: s.typeInstead),
                    onSubmitted: _toDraft,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(onPressed: () => _toDraft(textCtrl.text), icon: const Icon(Icons.arrow_upward), tooltip: s.next),
              ]),
              const SizedBox(height: 8),
              Pill(ref.watch(speechProvider).id == 'azure' ? 'Azure Speech' : (s.ar ? 'التعرف على الجهاز' : 'On-device recognition')),
            ],
          ),
        ),
      ),
    );
  }
}
