import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/services.dart';
import '../../core/assistant/local_assistant.dart';
import '../../core/assistant/tools.dart';
import '../../data/store.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/theme/tokens.dart';
import '../../ui/widgets/common.dart';
import '../insights/insights_screen.dart';

class ChatMsg {
  final bool user;
  final String text;
  final List<ToolResult> results;
  final bool onDevice;
  const ChatMsg(this.user, this.text, {this.results = const [], this.onDevice = true});
}

class AssistantScreen extends ConsumerStatefulWidget {
  const AssistantScreen({super.key});
  @override
  ConsumerState<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends ConsumerState<AssistantScreen> {
  final msgs = <ChatMsg>[];
  final ctrl = TextEditingController();
  final scroll = ScrollController();
  bool busy = false;
  bool listening = false;

  Future<void> _ask(String q) async {
    if (q.trim().isEmpty || busy) return;
    final s = S.of(context);
    ctrl.clear();
    setState(() {
      msgs.add(ChatMsg(true, q));
      busy = true;
    });
    final snap = snapshotFrom(ref.read);
    final local = ref.read(localAssistantProvider);
    AssistantAnswer a = local.answer(q, snap);
    final cloudOn = ref.read(settingsProvider).raw[SettingKeys.aiCloudEnabled] == 'true' && ref.read(apiProvider).configured && ref.read(sessionProvider).value != null;
    if (!a.understood && cloudOn) {
      try {
        a = await ref.read(cloudAssistantProvider).answer(q, snap, arabic: s.ar);
      } catch (_) {
        a = AssistantAnswer(s.genericError, const [], understood: false);
      }
    }
    if (!mounted) return;
    setState(() {
      msgs.add(ChatMsg(false, a.understood ? a.text : (cloudOn ? s.genericError : s.assistantDidNotUnderstand), results: a.results, onDevice: a.onDevice));
      busy = false;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (scroll.hasClients) scroll.animateTo(scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  Future<void> _voice() async {
    final sp = ref.read(speechProvider);
    final s = S.of(context);
    if (listening) {
      final r = await sp.stop();
      setState(() => listening = false);
      if (r.text.isNotEmpty) await _ask(r.text);
      return;
    }
    if (!await sp.requestPermission()) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.voiceMicDenied)));
      return;
    }
    setState(() => listening = true);
    try {
      await sp.start(locale: s.ar ? 'ar-KW' : 'en-US', onPartial: (t) => ctrl.text = t);
    } catch (_) {
      setState(() => listening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = context.fp;
    final cloudOn = ref.watch(settingsProvider).raw[SettingKeys.aiCloudEnabled] == 'true';
    final suggestions = [s.askSuggest1, s.askSuggest2, s.askSuggest3, s.askSuggest4, s.askSuggest5, s.askSuggest6];
    return Scaffold(
      appBar: AppBar(
        title: Text(s.askTitle),
        actions: [IconButton(icon: const Icon(Icons.edit_square), tooltip: s.newChat, onPressed: () => setState(msgs.clear))],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: msgs.isEmpty
                ? ListView(padding: const EdgeInsets.all(20), children: [
                    const SizedBox(height: 20),
                    const Center(child: Text('✨', style: TextStyle(fontSize: 44))),
                    const SizedBox(height: 8),
                    Center(child: Text(s.askTitle, style: context.tt.titleLarge)),
                    const SizedBox(height: 6),
                    Center(child: Text(cloudOn ? s.assistantCloud : s.assistantCloudOff, textAlign: TextAlign.center, style: context.tt.bodySmall?.copyWith(color: p.inkSecondary))),
                    const SizedBox(height: 20),
                    for (final q in suggestions)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: FCard(onTap: () => _ask(q), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14), child: Text(q, style: context.tt.bodyLarge)),
                      ),
                  ])
                : ListView.builder(
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                    itemCount: msgs.length + (busy ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i == msgs.length) return const Padding(padding: EdgeInsets.all(12), child: Align(alignment: AlignmentDirectional.centerStart, child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))));
                      final m = msgs[i];
                      if (m.user) {
                        return Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 12, left: 40),
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                            decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(FilsRadius.xl)),
                            child: Text(m.text, style: context.tt.bodyLarge?.copyWith(color: Colors.white)),
                          ),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 16, right: 12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          for (final r in m.results.where((r) => r.tool == 'spending_summary' && r.data['merchant'] == null && r.data['category_id'] == null))
                            Padding(padding: const EdgeInsets.only(bottom: 10), child: _SpendCard(result: r)),
                          SelectableText(m.text, style: context.tt.bodyLarge),
                          const SizedBox(height: 4),
                          Text(m.onDevice ? s.assistantOffline : s.assistantCloud, style: context.tt.bodySmall?.copyWith(color: p.inkTertiary)),
                        ]),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
            child: Container(
              decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(FilsRadius.pill), border: Border.all(color: p.border)),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(children: [
                IconButton(
                  icon: Icon(listening ? Icons.stop_circle : Icons.mic_none_rounded, color: listening ? p.negative : null),
                  tooltip: listening ? s.stop : s.voice,
                  onPressed: _voice,
                ),
                Expanded(
                  child: TextField(
                    controller: ctrl,
                    decoration: InputDecoration(hintText: s.askHint, filled: false, border: InputBorder.none),
                    onSubmitted: _ask,
                    textInputAction: TextInputAction.send,
                  ),
                ),
                IconButton.filledTonal(icon: const Icon(Icons.arrow_upward), tooltip: s.send, onPressed: busy ? null : () => _ask(ctrl.text)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Inline category chart attached to a spending answer (reference: chart card in chat).
class _SpendCard extends ConsumerWidget {
  final ToolResult result;
  const _SpendCard({required this.result});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final fmt = ref.watch(settingsProvider).fmt;
    final cats = ref.watch(categoryMapProvider);
    final cur = result.data['currency'] as String;
    final top = (result.data['top_categories'] as List).cast<Map>();
    if (top.isEmpty) return const SizedBox.shrink();
    final entries = [for (final c in top) MapEntry(c['category_id'] as String, (c['spent_minor'] as num).toInt())];
    return FCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s.spentByCategory, style: context.tt.labelSmall?.copyWith(color: context.fp.inkSecondary)),
        const SizedBox(height: 10),
        CategoryDonut(entries: entries, total: (result.data['spent_minor'] as num).toInt(), currency: cur, fmt: fmt, cats: cats),
      ]),
    );
  }
}
