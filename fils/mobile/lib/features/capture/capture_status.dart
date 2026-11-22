import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/services.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';

/// Shows each pipeline stage separately so a queued capture is never mistaken for an
/// updated balance: Securely queued → Posted to ledger / Awaiting review / Ignored.
class CapturePipelineStatus extends ConsumerWidget {
  const CapturePipelineStatus({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final p = context.fp;
    final queued = ref.watch(queuedCountProvider).value ?? 0;
    final c = ref.watch(captureCountsProvider).value ?? const CaptureCounts(0, 0, 0, 0);
    Widget stage(IconData icon, Color color, String label, int n, String hint) => Expanded(
          child: Semantics(
            label: '$label: $n. $hint',
            excludeSemantics: true,
            child: Column(children: [
              Icon(icon, color: color),
              const SizedBox(height: 4),
              Text('$n', style: context.tt.titleMedium),
              Text(label, textAlign: TextAlign.center, style: context.tt.labelSmall?.copyWith(color: p.inkSecondary, letterSpacing: 0)),
            ]),
          ),
        );
    return FCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(s.ar ? 'حالة الالتقاط (آخر ٢٤ ساعة)' : 'Capture pipeline (last 24 h)', style: context.tt.titleSmall),
        const SizedBox(height: 10),
        Row(children: [
          stage(Icons.lock_clock_outlined, queued > 0 ? p.warning : p.inkTertiary, s.ar ? 'في الانتظار' : 'Securely queued', queued, s.ar ? 'لم تُضف للأرصدة بعد' : 'not in balances yet'),
          stage(Icons.check_circle_outline, p.positive, s.ar ? 'أضيفت' : 'Posted', c.posted + c.merged, ''),
          stage(Icons.rate_review_outlined, c.review > 0 ? p.warning : p.inkTertiary, s.ar ? 'للمراجعة' : 'Awaiting review', c.review, s.ar ? 'لا تُحسب حتى تؤكدها' : 'not counted until confirmed'),
          stage(Icons.block, p.inkTertiary, s.ar ? 'متجاهلة' : 'Ignored', c.ignored, s.ar ? 'رموز تحقق أو عروض أو مكررة' : 'OTPs, promos, duplicates'),
        ]),
        if (queued > 0) ...[
          const SizedBox(height: 8),
          Text(
            s.ar
                ? 'رسائل محفوظة بأمان ولم تُعالج بعد. لا تؤثر على الأرصدة حتى تُضاف. تتم معالجتها عند فتح التطبيق أو تلقائياً عند الإمكان.'
                : 'Messages saved securely but not processed yet. They do not affect balances until posted. Processing runs when you open Fils, or automatically when possible.',
            style: context.tt.bodySmall?.copyWith(color: p.warning),
          ),
        ],
      ]),
    );
  }
}
