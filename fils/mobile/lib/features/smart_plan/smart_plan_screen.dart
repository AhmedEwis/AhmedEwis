/// "My Smart Plan" / خطتي الذكية — Fils Copilot.
///
/// Say or type a goal; Fils shows what it understood, asks only what it needs, and
/// proposes up to three changes with their computed impact. Nothing is written until
/// the user previews and confirms. Every amount on this screen comes from a computed
/// fact (observed, said by the user, or a labelled assumption).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../app/services.dart';
import '../../core/domain/categories.dart';
import '../../core/money/money.dart';
import '../../core/planner/plan_engine.dart';
import '../../core/planner/plan_models.dart';
import '../../core/time/kuwait_time.dart';
import '../../data/db/database.dart';
import '../../data/planner/cloud_planner.dart';
import '../../data/planner/plan_service.dart';
import '../../data/store.dart';
import '../../data/voice/speech_service.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/theme/tokens.dart';
import '../../ui/widgets/common.dart';
import 'smart_plan_controller.dart';

final planServiceProvider = Provider<PlanService>((ref) => PlanService(ref.watch(storeProvider)));

final cloudPlannerProvider = Provider<CloudPlanner>((ref) {
  final store = ref.watch(storeProvider);
  return CloudPlanner(ref.watch(apiProvider), () async => (await store.getSetting(SettingKeys.aiCloudEnabled)) == 'true');
});

class SmartPlanScreen extends ConsumerStatefulWidget {
  /// Prefilled request (demo scenarios and deep links).
  final String? initialText;
  const SmartPlanScreen({super.key, this.initialText});
  @override
  ConsumerState<SmartPlanScreen> createState() => _SmartPlanScreenState();
}

class _SmartPlanScreenState extends ConsumerState<SmartPlanScreen> {
  late final SmartPlanController c;
  final input = TextEditingController();
  bool listening = false;
  SpeechProvider? _speech;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    c = SmartPlanController(
      store: ref.read(storeProvider),
      service: ref.read(planServiceProvider),
      cloud: ref.read(cloudPlannerProvider),
      arabic: s.ar,
      baseCurrency: s.baseCurrency,
      cycleStartDay: s.cycleStartDay,
      now: ref.read(nowProvider),
    )..addListener(() {
        if (mounted) setState(() {});
      });
    c.load();
    if (widget.initialText != null) {
      input.text = widget.initialText!;
      c.understand(widget.initialText!);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _speech = ref.read(speechProvider);
  }

  @override
  void dispose() {
    if (listening) _speech?.cancel().catchError((_) {});
    c.dispose();
    input.dispose();
    super.dispose();
  }

  Future<void> _voice() async {
    final sp = ref.read(speechProvider);
    final s = S.of(context);
    if (listening) {
      final r = await sp.stop();
      setState(() => listening = false);
      if (r.text.isNotEmpty) {
        input.text = r.text;
        await c.understand(r.text);
      }
      return;
    }
    if (!await sp.requestPermission()) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.voiceMicDenied)));
      return;
    }
    setState(() => listening = true);
    try {
      await sp.start(locale: s.ar ? 'ar-KW' : 'en-US', onPartial: (t) => input.text = t);
    } catch (_) {
      setState(() => listening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final ar = s.ar;
    final p = c.proposal;
    return Scaffold(
      appBar: AppBar(
        title: Text(ar ? 'خطتي الذكية' : 'My Smart Plan'),
        actions: [
          IconButton(
            tooltip: ar ? 'ما يتذكره فلس' : 'What Fils remembers',
            icon: const Icon(Icons.bookmark_border_rounded),
            onPressed: () => _memorySheet(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(FilsSpace.gutter, 8, FilsSpace.gutter, 32),
        children: [
          if (c.activeProposal != null && p == null) ...[
            _ActivePlanCard(c: c),
            const SizedBox(height: 16),
          ],
          _Composer(c: c, input: input, listening: listening, onVoice: _voice),
          if (c.busy) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          if (!c.busy && p != null) ...[
            const SizedBox(height: 12),
            _UnderstoodCard(c: c),
            if (p.status == PlanStatus.needsInput) ...[const SizedBox(height: 12), _QuestionsCard(c: c)],
            if (p.status != PlanStatus.needsInput) ...[
              const SizedBox(height: 12),
              _SummaryCard(c: c),
              for (final a in p.actions) ...[const SizedBox(height: 12), _ActionCard(c: c, action: a)],
              if (p.alternatives.isNotEmpty) ...[const SizedBox(height: 12), _AlternativesCard(c: c)],
            ],
            if (p.limitations.isNotEmpty) ...[const SizedBox(height: 12), _LimitationsCard(p: p)],
            if (p.actions.isNotEmpty) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('plan_preview'),
                onPressed: c.selected.isEmpty ? null : () => _preview(context),
                icon: const Icon(Icons.fact_check_outlined),
                label: Text(ar ? 'معاينة التغييرات' : 'Preview changes'),
              ),
              const SizedBox(height: 6),
              Text(
                ar ? 'لن يتغير شيء قبل أن تؤكد. الخطة تعدّل الميزانيات المختارة فقط؛ لا تلمس عملياتك ولا تحوّل أي أموال.'
                    : 'Nothing changes until you confirm. The plan only sets the budgets you select; it never edits transactions or moves money.',
                style: context.tt.bodySmall?.copyWith(color: context.fp.inkSecondary),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ],
      ),
    );
  }

  Future<void> _preview(BuildContext context) async {
    final s = S.of(context);
    final ar = s.ar;
    final fmt = ref.read(settingsProvider).fmt;
    final cats = ref.read(categoryMapProvider);
    final p = c.proposal!;
    final changes = await c.preview();
    if (!context.mounted) return;
    final ok = await showFSheet<bool>(
      context,
      StatefulBuilder(builder: (context, set) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(ar ? 'معاينة: ما الذي سيتغير' : 'Preview: what will change', style: context.tt.titleLarge),
            const SizedBox(height: 4),
            Text(ar ? 'ميزانيات هذه الدورة فقط. العمليات والأرصدة لا تتغير.' : 'Budgets for this cycle only. Transactions and balances are not changed.',
                style: context.tt.bodySmall?.copyWith(color: context.fp.inkSecondary)),
            const SizedBox(height: 12),
            for (final ch in changes.where((x) => x.entity == 'budget'))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Text(ch.categoryId == '*' ? '🧮' : (cats[ch.categoryId]?.icon ?? '📦'), style: const TextStyle(fontSize: 22)),
                title: Text(_catName(ch.categoryId, cats, ar)),
                subtitle: Text(ch.beforeMinor == null ? (ar ? 'ميزانية جديدة' : 'New budget') : (ar ? 'تعديل ميزانية حالية' : 'Updates your current budget')),
                trailing: _ltr(Text(
                    '${ch.beforeMinor == null ? '—' : fmt.money(ch.beforeMinor!, p.currency)}  →  ${fmt.money(ch.afterMinor, p.currency)}',
                    style: context.tt.labelLarge)),
              ),
            SwitchListTile(
              key: const Key('plan_goal_toggle'),
              contentPadding: EdgeInsets.zero,
              value: c.createGoal,
              onChanged: (v) {
                c.setCreateGoal(v);
                set(() {});
              },
              title: Text(ar ? 'إنشاء هدف ادخار للمبلغ' : 'Also create a savings goal'),
              subtitle: _ltr(Text(fmt.money(p.intent.targetMinor ?? 0, p.currency))),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('plan_confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(ar ? 'تأكيد وتطبيق' : 'Confirm and apply'),
            ),
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(ar ? 'رجوع' : 'Back')),
          ]),
        );
      }),
    );
    if (ok != true || !context.mounted) return;
    final r = await c.apply();
    if (!context.mounted) return;
    final msg = switch (r.outcome) {
      ApplyOutcome.applied => ar ? 'تم تطبيق خطتك' : 'Your plan is applied',
      ApplyOutcome.alreadyApplied => ar ? 'هذه الخطة مطبقة بالفعل' : 'This plan is already applied',
      ApplyOutcome.alreadyUndone => ar ? 'تم التراجع عن هذه الخطة سابقاً' : 'This plan was undone earlier',
      ApplyOutcome.nothingSelected => ar ? 'لا يوجد ما يتغير' : 'Nothing to change',
    };
    final id = p.id;
    if (r.outcome == ApplyOutcome.applied) {
      showUndoSnack(context, msg, ar ? 'تراجع' : 'Undo', () => c.undo(id));
      c.discardDraft();
      input.clear();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _memorySheet(BuildContext context) async {
    final s = S.of(context);
    final ar = s.ar;
    final cats = ref.read(categoryMapProvider);
    await showFSheet<void>(
      context,
      StatefulBuilder(builder: (context, set) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(ar ? 'ما يتذكره فلس' : 'What Fils remembers', style: context.tt.titleLarge),
            const SizedBox(height: 6),
            Text(
              ar ? 'تُحفظ هذه التفضيلات على هاتفك فقط، وفقط عندما تطلب ذلك. فلس لا يستخدمها لتدريب أي نموذج ذكاء اصطناعي.'
                  : 'These preferences are stored only on this phone, and only when you ask. Fils doesn\'t use them to train any AI model.',
              style: context.tt.bodySmall?.copyWith(color: context.fp.inkSecondary),
            ),
            const SizedBox(height: 12),
            Text(ar ? 'فئات محمية دائماً' : 'Always protected', style: context.tt.titleSmall),
            const SizedBox(height: 8),
            if (c.remembered.isEmpty) Text(ar ? 'لا شيء محفوظ.' : 'Nothing saved.', style: context.tt.bodyMedium),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final id in c.remembered)
                InputChip(
                  label: Text(_catName(id, cats, ar)),
                  onDeleted: () async {
                    await c.forget(id);
                    set(() {});
                  },
                ),
            ]),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: c.remembered.isEmpty
                  ? null
                  : () async {
                      await c.resetMemory();
                      set(() {});
                    },
              child: Text(ar ? 'مسح كل ما يتذكره' : 'Reset everything'),
            ),
          ]),
        );
      }),
    );
  }
}

/// SYNTHETIC demo scenarios, shown only in demo mode and labelled as such.
class DemoScenario {
  final String id, labelEn, labelAr, text;
  const DemoScenario(this.id, this.labelEn, this.labelAr, this.text);
}

const smartPlanDemoScenarios = [
  DemoScenario('eg', 'Save 150, protect gym & home', 'أوفر 150 وأحمي الجيم والبيت', 'عايز أوفر 150 دينار الشهر ده، بس ما تقللش الجيم ولا مصاريف البيت.'),
  DemoScenario('kw', 'Too ambitious (900 this month)', 'هدف كبير (900 هالشهر)', 'ابي اوفر 900 دينار هالشهر بس لا تقرب النادي'),
  DemoScenario('en', '600 KD over 3 months', '600 د.ك خلال 3 أشهر', 'I want to save 600 KD in 3 months but keep groceries as they are'),
];

Widget _ltr(Widget w) => Directionality(textDirection: TextDirection.ltr, child: w);

String _catName(String? id, Map<String, CategoryRow> cats, bool ar) {
  if (id == null || id == '*') return ar ? 'كل المصروف' : 'All spending';
  final r = cats[id];
  if (r != null) return ar ? r.nameAr : r.nameEn;
  final d = systemCategories.where((c) => c.id == id).firstOrNull;
  return d == null ? id : (ar ? d.ar : d.en);
}

String _catIcon(String id, Map<String, CategoryRow> cats) =>
    id == '*' ? '🧮' : (cats[id]?.icon ?? systemCategories.where((c) => c.id == id).map((c) => c.icon).firstOrNull ?? '📦');

/// Where a number comes from, next to the number.
class _SourcePill extends StatelessWidget {
  final FactSource source;
  const _SourcePill(this.source);
  @override
  Widget build(BuildContext context) {
    final p = context.fp;
    final ar = S.of(context).ar;
    return switch (source) {
      FactSource.observed => Pill(ar ? 'من عملياتك' : 'Observed', icon: Icons.receipt_long_outlined),
      FactSource.confirmed => Pill(ar ? 'أنت قلت' : 'You said', icon: Icons.record_voice_over_outlined, bg: p.positiveBg, fg: p.positive),
      FactSource.assumption => Pill(ar ? 'افتراض' : 'Assumption', icon: Icons.tune_rounded, bg: p.warningBg, fg: p.warning),
    };
  }
}

class _Composer extends ConsumerWidget {
  final SmartPlanController c;
  final TextEditingController input;
  final bool listening;
  final VoidCallback onVoice;
  const _Composer({required this.c, required this.input, required this.listening, required this.onVoice});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ar = S.of(context).ar;
    final p = context.fp;
    return FCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(FilsRadius.md)),
            child: Icon(Icons.flag_circle_outlined, color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(ar ? 'إيش هدفك هالشهر؟' : 'What do you want to save?', style: context.tt.titleMedium)),
        ]),
        const SizedBox(height: 10),
        TextField(
          key: const Key('plan_input'),
          controller: input,
          minLines: 2,
          maxLines: 4,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: ar ? 'مثلاً: عايز أوفر 150 دينار الشهر ده، بس ما تقللش الجيم ولا مصاريف البيت' : 'e.g. Save 150 KD this month, but don\'t cut the gym or household expenses',
          ),
          onSubmitted: c.understand,
        ),
        const SizedBox(height: 10),
        Row(children: [
          IconButton.filledTonal(
            key: const Key('plan_mic'),
            tooltip: ar ? 'تحدث' : 'Speak',
            onPressed: onVoice,
            icon: Icon(listening ? Icons.stop_rounded : Icons.mic_none_rounded),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              key: const Key('plan_go'),
              onPressed: c.busy ? null : () => c.understand(input.text),
              child: Text(ar ? 'اعمل لي خطة' : 'Make my plan'),
            ),
          ),
        ]),
        if (ref.watch(settingsProvider).demoMode && c.understanding == Understanding.none) ...[
          const SizedBox(height: 10),
          Text(ar ? 'سيناريوهات تجريبية (بيانات اصطناعية)' : 'Demo scenarios (synthetic data)', style: context.tt.labelMedium),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final d in smartPlanDemoScenarios)
              ActionChip(
                key: Key('demo_${d.id}'),
                label: Text(ar ? d.labelAr : d.labelEn),
                onPressed: () {
                  input.text = d.text;
                  c.understand(d.text);
                },
              ),
          ]),
        ],
        if (c.understanding != Understanding.none) ...[
          const SizedBox(height: 10),
          _AiStatus(c: c),
        ] else ...[
          const SizedBox(height: 8),
          Text(
            ar ? 'فلس يحسب كل الأرقام على جهازك من عملياتك المسجلة. لا يتصل ببنكك.' : 'Fils computes every number on this phone from the transactions it has captured. It doesn\'t connect to your bank.',
            style: context.tt.bodySmall?.copyWith(color: p.inkSecondary),
          ),
        ],
      ]),
    );
  }
}

class _AiStatus extends StatelessWidget {
  final SmartPlanController c;
  const _AiStatus({required this.c});
  @override
  Widget build(BuildContext context) {
    final ar = S.of(context).ar;
    final p = context.fp;
    final live = c.understanding == Understanding.liveAi;
    final why = switch (c.aiReason) {
      AiUnavailable.consentOff => ar ? 'الذكاء الاصطناعي السحابي غير مفعّل (الإعدادات ← الخصوصية).' : 'Cloud AI is off (Settings → Privacy).',
      AiUnavailable.notConfigured => ar ? 'لا يوجد خادم مُعدّ في هذا الإصدار.' : 'No server is configured in this build.',
      AiUnavailable.signedOut => ar ? 'سجّل الدخول لاستخدام الذكاء الاصطناعي السحابي.' : 'Sign in to use cloud AI.',
      AiUnavailable.providerOff => ar ? 'خدمة الذكاء الاصطناعي غير متاحة الآن.' : 'The AI service is unavailable right now.',
      AiUnavailable.quota => ar ? 'وصلت لحد الاستخدام الشهري.' : 'Monthly AI limit reached.',
      AiUnavailable.network => ar ? 'لا يوجد اتصال.' : 'No connection.',
      AiUnavailable.invalidOutput => ar ? 'رد الذكاء الاصطناعي لم يجتز التحقق، فاستُخدم المخطط المحلي.' : 'The AI reply failed validation, so the local planner was used.',
      null => null,
    };
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      live
          ? Pill(ar ? 'ذكاء اصطناعي مباشر' : 'Live AI', icon: Icons.auto_awesome, bg: p.positiveBg, fg: p.positive)
          : Pill(ar ? 'مخطط محلي أساسي' : 'Basic local planner', icon: Icons.phone_android_rounded),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          live
              ? (ar ? 'فهم الذكاء الاصطناعي طلبك؛ الأرقام كلها محسوبة على جهازك.' : 'AI understood your request; every number is computed on your phone.')
              : (why ?? (ar ? 'فهم محلي بدون إنترنت.' : 'Understood on this phone, offline.')),
          style: context.tt.bodySmall?.copyWith(color: p.inkSecondary),
        ),
      ),
    ]);
  }
}

class _UnderstoodCard extends ConsumerWidget {
  final SmartPlanController c;
  const _UnderstoodCard({required this.c});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ar = S.of(context).ar;
    final fmt = ref.watch(settingsProvider).fmt;
    final cats = ref.watch(categoryMapProvider);
    final p = c.proposal!;
    final i = p.intent;
    final end = ReportingZone.kuwait.toWall(p.periodEnd.subtract(const Duration(days: 1)));
    final protectable = systemCategories.where((x) => !x.income && x.id != Cat.transfers).toList();
    return FCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(ar ? 'فهمت التالي' : 'What I understood', style: context.tt.titleSmall),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (i.targetMinor != null) Chip(avatar: const Icon(Icons.savings_outlined, size: 18), label: _ltr(Text(fmt.money(i.targetMinor!, p.currency)))),
          if (i.deadline != null)
            Chip(
              avatar: const Icon(Icons.event_outlined, size: 18),
              label: Text(i.deadline == DeadlineKind.thisCycle
                  ? (ar ? 'هذه الدورة · حتى ${fmt.dayMonth(end)}' : 'This cycle · until ${fmt.dayMonth(end)}')
                  : (ar ? 'خلال ${i.months} أشهر' : 'Within ${i.months} months')),
            ),
          if (i.incomeMinor != null) Chip(avatar: const Icon(Icons.payments_outlined, size: 18), label: _ltr(Text(fmt.money(i.incomeMinor!, p.currency)))),
          for (final cm in i.commitments)
            Chip(avatar: const Icon(Icons.lock_clock_outlined, size: 18), label: Text('${_catName(cm.categoryId, cats, ar)} ${fmt.money(cm.amountMinor, p.currency)}')),
        ]),
        const SizedBox(height: 12),
        Text(ar ? 'لا تقلل من' : 'Protected (never cut)', style: context.tt.labelLarge),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final id in i.protectedCategories)
            InputChip(
              key: Key('protected_$id'),
              avatar: Text(_catIcon(id, cats)),
              label: Text(_catName(id, cats, ar)),
              onDeleted: () => c.toggleProtected(id),
              deleteButtonTooltipMessage: ar ? 'إلغاء الحماية' : 'Stop protecting',
            ),
          ActionChip(
            avatar: const Icon(Icons.add, size: 18),
            label: Text(ar ? 'حماية فئة' : 'Protect a category'),
            onPressed: () async {
              final picked = await showFSheet<String>(
                context,
                Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final d in protectable.where((d) => !i.protectedCategories.contains(d.id)))
                    ListTile(leading: Text(d.icon, style: const TextStyle(fontSize: 20)), title: Text(ar ? d.ar : d.en), onTap: () => Navigator.of(context).pop(d.id)),
                ]),
              );
              if (picked != null) await c.toggleProtected(picked);
            },
          ),
        ]),
        for (final e in i.groupedPhrases.entries)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              const _SourcePill(FactSource.assumption),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  ar ? 'فهمت «${e.key}» على أنها: ${e.value.map((x) => _catName(x, cats, ar)).join('، ')}. عدّلها من الأعلى.'
                      : 'I read "${e.key}" as: ${e.value.map((x) => _catName(x, cats, ar)).join(', ')}. Edit above.',
                  style: context.tt.bodySmall,
                ),
              ),
            ]),
          ),
        if (i.protectedCategories.isNotEmpty && !(i.protectedCategories.length == c.remembered.length && i.protectedCategories.containsAll(c.remembered)))
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: c.rememberProtected,
              icon: const Icon(Icons.bookmark_add_outlined, size: 18),
              label: Text(ar ? 'تذكّر هذه الحماية للمرات القادمة' : 'Remember these protections next time'),
            ),
          ),
      ]),
    );
  }
}

class _QuestionsCard extends ConsumerWidget {
  final SmartPlanController c;
  const _QuestionsCard({required this.c});

  Future<int?> _ask(BuildContext context, String title, String currency) async {
    final ctrl = TextEditingController();
    final ar = S.of(context).ar;
    return showFSheet<int>(
      context,
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: context.tt.titleMedium),
          const SizedBox(height: 10),
          TextField(
            key: const Key('plan_answer'),
            controller: ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(suffixText: currency),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: () {
              final m = Money.parse(normalizeDigits(ctrl.text.trim()), currency);
              if (m != null && m.minor > 0) Navigator.of(context).pop(m.minor);
            },
            child: Text(ar ? 'تم' : 'Done'),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ar = S.of(context).ar;
    final p = c.proposal!;
    final pal = context.fp;
    Widget q(String text, String button, Future<void> Function() onTap, {Key? key}) => Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(children: [
            Icon(Icons.help_outline_rounded, color: pal.warning),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: context.tt.bodyMedium)),
            TextButton(key: key, onPressed: onTap, child: Text(button)),
          ]),
        );
    return FCard(
      color: pal.warningBg,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(ar ? 'أحتاج منك معلومة قبل أن أقترح شيئاً' : 'A few details first', style: context.tt.titleSmall),
        for (final question in p.questions)
          switch (question) {
            PlanQuestion.target => q(ar ? 'كم تريد أن توفر؟' : 'How much do you want to save?', ar ? 'إدخال' : 'Enter', () async {
                final v = await _ask(context, ar ? 'المبلغ الذي تريد توفيره' : 'Amount to save', p.currency);
                if (v != null) await c.setTarget(v);
              }),
            PlanQuestion.deadline => Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(ar ? 'متى؟' : 'By when?', style: context.tt.bodyMedium),
                  ActionChip(label: Text(ar ? 'هذه الدورة' : 'This cycle'), onPressed: () => c.setDeadline(DeadlineKind.thisCycle)),
                  ActionChip(label: Text(ar ? 'خلال ٣ أشهر' : 'In 3 months'), onPressed: () => c.setDeadline(DeadlineKind.months, months: 3)),
                  ActionChip(label: Text(ar ? 'خلال ٦ أشهر' : 'In 6 months'), onPressed: () => c.setDeadline(DeadlineKind.months, months: 6)),
                ]),
              ),
            PlanQuestion.income => q(
                ar ? 'كم دخلك المتوقع هذه الدورة؟ لم أجد راتباً مسجلاً في كل الدورات، ولن أفترض أنه صفر.' : 'What income do you expect this cycle? Fils didn\'t find income in every cycle and won\'t assume zero.',
                ar ? 'إدخال' : 'Enter', () async {
                final v = await _ask(context, ar ? 'الدخل المتوقع' : 'Expected income', p.currency);
                if (v != null) await c.setIncome(v);
              }, key: const Key('plan_q_income')),
            PlanQuestion.typicalSpending => q(
                ar ? 'لا يوجد في فلس شهر كامل من عملياتك بعد. كم تصرف عادة في الشهر؟ (لن أعتبر الأيام غير المسجلة صفراً.)' : 'Fils doesn\'t have a full month of your transactions yet. How much do you usually spend per month? (Missing days are never treated as zero.)',
                ar ? 'إدخال' : 'Enter', () async {
                final v = await _ask(context, ar ? 'مصروفك الشهري المعتاد' : 'Usual monthly spending', p.currency);
                if (v != null) await c.setTypicalSpending(v);
              }, key: const Key('plan_q_typical')),
            PlanQuestion.currencyUnsupported => Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  ar ? 'الخطة تعمل بعملتك الأساسية (${p.currency}) فقط. فلس لا يحوّل بين العملات.' : 'Plans work in your base currency (${p.currency}) only. Fils doesn\'t convert between currencies.',
                  style: context.tt.bodyMedium,
                ),
              ),
          },
      ]),
    );
  }
}

/// Now vs with the plan vs the goal, on one scale.
class _SummaryCard extends ConsumerWidget {
  final SmartPlanController c;
  const _SummaryCard({required this.c});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ar = S.of(context).ar;
    final fmt = ref.watch(settingsProvider).fmt;
    final p = c.proposal!;
    final pal = context.fp;
    final primary = Theme.of(context).colorScheme.primary;
    final goal = p.amount(p.targetFactId);
    final base = p.amount(p.baselineSavingsFactId);
    final proj = p.amount(p.projectedSavingsFactId);
    final top = [goal, base, proj, 1].reduce((a, b) => a > b ? a : b).toDouble();
    final headline = switch (p.status) {
      PlanStatus.onTrack => ar ? 'أنت على الطريق بدون تغييرات' : 'You\'re on track without changes',
      PlanStatus.feasible => ar ? 'هدفك ممكن بهذه التعديلات' : 'Your goal works with these changes',
      PlanStatus.infeasible => ar ? 'هدفك أكبر من الممكن هذه الدورة' : 'Your goal is more than this cycle allows',
      PlanStatus.needsInput => '',
    };
    Widget bar(String label, int v, Color color, String factId, {Key? key}) {
      final f = p.facts[factId];
      return Padding(
        key: key,
        padding: const EdgeInsets.only(top: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(label, style: context.tt.bodyMedium)),
            if (f != null) _SourcePill(f.source),
            const SizedBox(width: 6),
            _ltr(Text(fmt.money(v, p.currency), style: context.tt.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]))),
          ]),
          const SizedBox(height: 4),
          LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth;
            return Stack(children: [
              Container(height: 10, decoration: BoxDecoration(color: pal.surfaceMuted, borderRadius: BorderRadius.circular(5))),
              Container(height: 10, width: v <= 0 ? 0 : (w * v / top).clamp(0, w), decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(5))),
              PositionedDirectional(start: (w * goal / top).clamp(0, w - 2), child: Container(width: 2, height: 10, color: pal.ink)),
            ]);
          }),
        ]),
      );
    }

    final expl = c.explanation;
    return FCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(
            p.status == PlanStatus.infeasible ? Icons.report_gmailerrorred_rounded : Icons.check_circle_outline_rounded,
            color: p.status == PlanStatus.infeasible ? pal.warning : pal.positive,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(headline, style: context.tt.titleMedium)),
        ]),
        if (expl != null) ...[
          const SizedBox(height: 8),
          Text(renderNarrative(expl.summary, p.facts, (m) => fmt.money(m.minor, m.currency)), style: context.tt.bodyMedium),
        ],
        bar(ar ? 'التوفير إذا لم يتغير شيء' : 'Savings if nothing changes', base, pal.inkTertiary, 'baseline_savings', key: const Key('bar_baseline')),
        if (p.status != PlanStatus.onTrack) bar(ar ? 'التوفير مع الخطة' : 'Savings with the plan', proj, primary, 'projected_savings', key: const Key('bar_plan')),
        const SizedBox(height: 8),
        Row(children: [
          Container(width: 2, height: 12, color: pal.ink),
          const SizedBox(width: 6),
          Text(ar ? 'الهدف ' : 'Goal ', style: context.tt.bodySmall),
          _ltr(Text(fmt.money(goal, p.currency), style: context.tt.bodySmall?.copyWith(fontWeight: FontWeight.w600))),
        ]),
        const Divider(height: 24),
        _FactRow(p: p, id: p.incomeFactId),
        _FactRow(p: p, id: p.baselineSpendFactId),
        Text(
          ar ? '${p.coveredCycles == 0 ? 'لا توجد دورة كاملة مسجلة' : 'مبني على ${p.coveredCycles} ${p.coveredCycles == 1 ? 'دورة' : 'دورات'} مسجلة'} · الحسابات المسجلة في فلس فقط'
              : '${p.coveredCycles == 0 ? 'No complete cycle captured yet' : 'Based on ${p.coveredCycles} captured cycle${p.coveredCycles == 1 ? '' : 's'}'} · only accounts captured in Fils',
          style: context.tt.bodySmall?.copyWith(color: pal.inkSecondary),
        ),
      ]),
    );
  }
}

class _FactRow extends ConsumerWidget {
  final PlanProposal p;
  final String? id;
  const _FactRow({required this.p, required this.id});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = id == null ? null : p.facts[id];
    if (f == null) return const SizedBox.shrink();
    final ar = S.of(context).ar;
    final fmt = ref.watch(settingsProvider).fmt;
    final basis = ar ? f.basisAr : f.basisEn;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(ar ? f.labelAr : f.labelEn, style: context.tt.bodyMedium)),
          const SizedBox(width: 8),
          _ltr(Text(fmt.money(f.amountMinor, f.currency), style: context.tt.labelLarge)),
        ]),
        const SizedBox(height: 3),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _SourcePill(f.source),
          if (basis.isNotEmpty) ...[
            const SizedBox(width: 6),
            Expanded(child: Text(basis, style: context.tt.bodySmall?.copyWith(color: context.fp.inkSecondary))),
          ],
        ]),
      ]),
    );
  }
}

class _ActionCard extends ConsumerStatefulWidget {
  final SmartPlanController c;
  final PlanAction action;
  const _ActionCard({required this.c, required this.action});
  @override
  ConsumerState<_ActionCard> createState() => _ActionCardState();
}

class _ActionCardState extends ConsumerState<_ActionCard> {
  bool why = false;
  @override
  Widget build(BuildContext context) {
    final ar = S.of(context).ar;
    final fmt = ref.watch(settingsProvider).fmt;
    final cats = ref.watch(categoryMapProvider);
    final c = widget.c;
    final a = widget.action;
    final p = c.proposal!;
    final pal = context.fp;
    final on = c.selected.contains(a.id);
    final base = p.amount(a.baselineFactId);
    final spent = p.amount(a.spentFactId);
    final whyText = c.explanation?.whyByAction[a.id];
    return FCard(
      key: Key('action_${a.categoryId}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(_catIcon(a.categoryId, cats), style: const TextStyle(fontSize: 26)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(ar ? 'قلّل ${_catName(a.categoryId, cats, ar)}' : 'Spend less on ${_catName(a.categoryId, cats, ar)}', style: context.tt.titleSmall),
              _ltr(Text('${fmt.money(base, p.currency)}  →  ${fmt.money(a.limitMinor, p.currency)}', style: context.tt.bodyMedium?.copyWith(color: pal.inkSecondary))),
            ]),
          ),
          Semantics(
            label: ar ? 'تضمين في الخطة' : 'Include in plan',
            child: Checkbox(key: Key('include_${a.categoryId}'), value: on, onChanged: (_) => c.toggleSelected(a.id)),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Pill(ar ? 'أثر الخطة' : 'Impact', bg: pal.positiveBg, fg: pal.positive),
          const SizedBox(width: 6),
          _ltr(Text('+${fmt.money(a.impactMinor, p.currency)}', style: context.tt.titleSmall?.copyWith(color: pal.positive))),
          if (a.userAdjusted) ...[const SizedBox(width: 6), Pill(ar ? 'عدّلته أنت' : 'Your edit')],
          const Spacer(),
          IconButton(
            key: Key('minus_${a.categoryId}'),
            tooltip: ar ? 'حد أقل' : 'Lower limit',
            onPressed: a.limitMinor - limitStepMinor < spent ? null : () => c.adjustLimit(a.categoryId, a.limitMinor - limitStepMinor),
            icon: const Icon(Icons.remove_circle_outline),
          ),
          IconButton(
            key: Key('plus_${a.categoryId}'),
            tooltip: ar ? 'حد أعلى' : 'Raise limit',
            onPressed: a.limitMinor + limitStepMinor > base ? null : () => c.adjustLimit(a.categoryId, a.limitMinor + limitStepMinor),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ]),
        FProgress(value: a.limitMinor == 0 ? 0 : spent / a.limitMinor),
        const SizedBox(height: 4),
        _ltr(Text(
            ar ? 'صرفت ${fmt.money(spent, p.currency)} من ${fmt.money(a.limitMinor, p.currency)}' : '${fmt.money(spent, p.currency)} of ${fmt.money(a.limitMinor, p.currency)} spent so far',
            style: context.tt.bodySmall?.copyWith(color: pal.inkSecondary))),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: Key('why_${a.categoryId}'),
            onPressed: () => setState(() => why = !why),
            icon: Icon(why ? Icons.expand_less : Icons.expand_more),
            label: Text(ar ? 'ليش هذا الاقتراح؟' : 'Why this suggestion?'),
          ),
        ),
        if (why) ...[
          if (whyText != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(renderNarrative(whyText, p.facts, (m) => fmt.money(m.minor, m.currency)), style: context.tt.bodyMedium),
            ),
          for (final id in a.whyFactIds) _FactRow(p: p, id: id),
        ],
      ]),
    );
  }
}

class _AlternativesCard extends ConsumerWidget {
  final SmartPlanController c;
  const _AlternativesCard({required this.c});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ar = S.of(context).ar;
    final fmt = ref.watch(settingsProvider).fmt;
    final cats = ref.watch(categoryMapProvider);
    final p = c.proposal!;
    return FCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(ar ? 'بدائل واقعية (محسوبة، بدون توفير مختلق)' : 'Realistic alternatives (computed, no invented savings)', style: context.tt.titleSmall),
        for (final alt in p.alternatives)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(switch (alt.kind) {
              AlternativeKind.lowerTarget => Icons.south_rounded,
              AlternativeKind.extendDeadline => Icons.date_range_rounded,
              AlternativeKind.relaxProtected => Icons.lock_open_rounded,
            }),
            title: Text(switch (alt.kind) {
              AlternativeKind.lowerTarget => ar ? 'هدف أصغر: ${fmt.money(alt.amountMinor!, p.currency)}' : 'A smaller goal: ${fmt.money(alt.amountMinor!, p.currency)}',
              AlternativeKind.extendDeadline => ar ? 'نفس الهدف خلال ${alt.months} أشهر' : 'The same goal over ${alt.months} months',
              AlternativeKind.relaxProtected => ar
                  ? 'السماح بتخفيض ${_catName(alt.categoryId, cats, ar)} يضيف حتى ${fmt.money(alt.amountMinor!, p.currency)}'
                  : 'Allowing a cut to ${_catName(alt.categoryId, cats, ar)} adds up to ${fmt.money(alt.amountMinor!, p.currency)}',
            }),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              switch (alt.kind) {
                case AlternativeKind.lowerTarget:
                  await c.setTarget(alt.amountMinor!);
                case AlternativeKind.extendDeadline:
                  await c.setDeadline(DeadlineKind.months, months: alt.months!);
                case AlternativeKind.relaxProtected:
                  await c.toggleProtected(alt.categoryId!);
              }
            },
          ),
      ]),
    );
  }
}

class _LimitationsCard extends StatelessWidget {
  final PlanProposal p;
  const _LimitationsCard({required this.p});
  @override
  Widget build(BuildContext context) {
    final ar = S.of(context).ar;
    String text(PlanLimitation l) => switch (l) {
          PlanLimitation.shortHistory => ar ? 'التاريخ المسجل أقل من ٣ دورات، فالمعتاد قد لا يكون دقيقاً.' : 'Less than 3 cycles of history: usual amounts may be off.',
          PlanLimitation.noHistory => ar ? 'لا توجد دورة كاملة من عملياتك بعد.' : 'No complete cycle of your transactions yet.',
          PlanLimitation.irregularIncome => ar ? 'دخلك يتغير؛ استُخدم أقل دخل حديث للأمان.' : 'Your income varies; the lowest recent cycle is used to be safe.',
          PlanLimitation.otherCurrencies => ar ? 'يوجد صرف بعملات أخرى غير مشمول ولا يُحوّل.' : 'Spending in other currencies isn\'t included or converted.',
          PlanLimitation.accountsWithoutActivity => ar ? 'بعض حساباتك بلا عمليات مسجلة؛ أي صرف عليها غير ظاهر.' : 'Some of your accounts have no captured activity; spending there isn\'t visible.',
          PlanLimitation.protectedWithoutSpending => ar ? 'فئة محمية بلا صرف مسجل (ربما تدفعها من فئة أخرى، مثل الجيم).' : 'A protected category has no captured spending (you may pay it under another category, e.g. the gym).',
          PlanLimitation.pendingIncluded => ar ? 'المبالغ المعلقة محسوبة كمصروف.' : 'Pending authorizations are counted as spending.',
        };
    return FCard(
      color: context.fp.surfaceMuted,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(ar ? 'حدود هذه الخطة' : 'What this plan can\'t see', style: context.tt.titleSmall),
        for (final l in p.limitations)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_outline_rounded, size: 16),
              const SizedBox(width: 6),
              Expanded(child: Text(text(l), style: context.tt.bodySmall)),
            ]),
          ),
      ]),
    );
  }
}

/// The accepted plan for this cycle: progress, update offer, undo.
class _ActivePlanCard extends ConsumerWidget {
  final SmartPlanController c;
  const _ActivePlanCard({required this.c});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ar = S.of(context).ar;
    final fmt = ref.watch(settingsProvider).fmt;
    final cats = ref.watch(categoryMapProvider);
    final p = c.activeProposal!;
    final prog = c.progress;
    final pal = context.fp;
    final selected = c.active == null ? <String>{} : PlanService.selectedOf(c.active!);
    final shown = p.actions.where((a) => selected.isEmpty || selected.contains(a.id));
    return FCard(
      key: const Key('active_plan'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.flag_rounded, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(ar ? 'خطتك الحالية: ${fmt.money(p.amount(p.targetFactId), p.currency)}' : 'Your plan: save ${fmt.money(p.amount(p.targetFactId), p.currency)}',
                style: context.tt.titleMedium),
          ),
          if (prog != null) Pill('${(prog.cycleElapsed * 100).round()}% ${ar ? 'من الدورة' : 'of cycle'}'),
        ]),
        for (final a in shown) ...[
          const SizedBox(height: 10),
          Row(children: [
            Text(_catIcon(a.categoryId, cats)),
            const SizedBox(width: 6),
            Expanded(child: Text(_catName(a.categoryId, cats, ar), style: context.tt.bodyMedium)),
            _ltr(Text('${fmt.money(prog?.spentByCategory[a.categoryId] ?? 0, p.currency)} / ${fmt.money(a.limitMinor, p.currency)}', style: context.tt.labelLarge)),
          ]),
          const SizedBox(height: 4),
          FProgress(value: a.limitMinor == 0 ? 0 : (prog?.spentByCategory[a.categoryId] ?? 0) / a.limitMinor),
          if (prog?.overPace.contains(a.categoryId) ?? false)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(ar ? 'أسرع من وتيرة الخطة' : 'Ahead of the plan\'s pace', style: context.tt.bodySmall?.copyWith(color: pal.warning)),
            ),
        ],
        if (c.updated != null) ...[
          const Divider(height: 24),
          Text(ar ? 'خطة محدثة مقترحة — لم يتغير شيء بعد' : 'An updated plan is suggested — nothing has changed yet', style: context.tt.titleSmall),
          for (final r in c.updateReasons)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _reason(r, ar, (v) => fmt.money(v, p.currency), _catName(r.categoryId, cats, ar)),
                style: context.tt.bodySmall,
              ),
            ),
          if (c.updateReasons.isEmpty) Text(ar ? 'نفس الحدود ما زالت مناسبة.' : 'The same limits still fit.', style: context.tt.bodySmall),
          const SizedBox(height: 8),
          if (c.updateReasons.isNotEmpty)
            FilledButton.tonal(onPressed: c.reviewUpdate, child: Text(ar ? 'راجع الخطة المحدثة' : 'Review the updated plan')),
        ],
        const SizedBox(height: 8),
        Row(children: [
          if (c.updated == null && (prog?.needsUpdate ?? false))
            Expanded(child: FilledButton.tonal(key: const Key('plan_offer_update'), onPressed: c.offerUpdate, child: Text(ar ? 'اقترح خطة محدثة' : 'Suggest an updated plan'))),
          if (c.updated == null && !(prog?.needsUpdate ?? false))
            Expanded(child: OutlinedButton(onPressed: c.offerUpdate, child: Text(ar ? 'تحقق إن كانت الخطة ما زالت مناسبة' : 'Check if the plan still fits'))),
          const SizedBox(width: 8),
          TextButton(
            key: const Key('plan_undo'),
            onPressed: () async {
              final r = await c.undo(c.active!.id);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(r.keptUserEdits.isEmpty
                    ? (ar ? 'تم التراجع عن الخطة وإرجاع الميزانيات' : 'Plan undone; budgets restored')
                    : (ar ? 'تم التراجع، مع إبقاء تعديلاتك اليدوية' : 'Plan undone; your manual edits were kept')),
              ));
            },
            child: Text(ar ? 'تراجع عن الخطة' : 'Undo plan'),
          ),
        ]),
      ]),
    );
  }

  static String _reason(PlanChange r, bool ar, String Function(int) money, String cat) {
    if (r.oldLimit != null && r.newLimit == null) {
      return ar ? '$cat: لم يعد ضمن الاقتراحات (المصروف الحالي ${money(r.spentNow ?? 0)}).' : '$cat: no longer suggested (spent so far ${money(r.spentNow ?? 0)}).';
    }
    if (r.oldLimit == null) {
      return ar ? '$cat: اقتراح جديد، حد ${money(r.newLimit!)}.' : '$cat: newly suggested, limit ${money(r.newLimit!)}.';
    }
    return ar
        ? '$cat: الحد من ${money(r.oldLimit!)} إلى ${money(r.newLimit!)} لأنك صرفت حتى الآن ${money(r.spentNow ?? 0)}.'
        : '$cat: limit ${money(r.oldLimit!)} → ${money(r.newLimit!)} because ${money(r.spentNow ?? 0)} is already spent.';
  }
}

/// Home entry point: "خطتي الذكية".
class SmartPlanHomeCard extends ConsumerWidget {
  final VoidCallback onTap;
  const SmartPlanHomeCard({super.key, required this.onTap});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ar = S.of(context).ar;
    final pal = context.fp;
    final primary = Theme.of(context).colorScheme.primary;
    return FCard(
      key: const Key('home_smart_plan'),
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(FilsRadius.md)),
          child: Icon(Icons.flag_circle_rounded, color: primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ar ? 'خطتي الذكية' : 'My Smart Plan', style: context.tt.titleSmall),
            Text(ar ? 'قل هدفك، وفلس يقترح خطة تعدّلها وتؤكدها' : 'Say your goal; Fils proposes a plan you adjust and confirm',
                style: context.tt.bodySmall?.copyWith(color: pal.inkSecondary)),
          ]),
        ),
        Icon(context.isRtl ? Icons.chevron_left : Icons.chevron_right, color: pal.inkTertiary),
      ]),
    );
  }
}
