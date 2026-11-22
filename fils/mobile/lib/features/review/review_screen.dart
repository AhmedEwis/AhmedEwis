import 'package:drift/drift.dart' show Value, OrderingTerm, OrderingMode, BooleanExpressionOperators;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/services.dart';
import '../../core/parsing/sanitizer.dart';
import '../../core/time/kuwait_time.dart';
import '../../data/db/database.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/tx_tile.dart';
import '../transactions/add_transaction_sheet.dart';

final _unparsedProvider = StreamProvider<List<SourceEventRow>>((ref) {
  final db = ref.watch(storeProvider).db;
  return (db.select(db.sourceEvents)
        ..where((s) => s.status.equals('review') & s.transactionId.isNull())
        ..orderBy([(s) => OrderingTerm(expression: s.receivedAt, mode: OrderingMode.desc)]))
      .watch();
});

final _reviewTxProvider = StreamProvider<List<TxRow>>((ref) => ref.watch(storeProvider).watchTransactions(needsReview: true, limit: 200));

class ReviewScreen extends ConsumerWidget {
  const ReviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final p = context.fp;
    final unparsed = ref.watch(_unparsedProvider).value ?? const [];
    final txs = ref.watch(_reviewTxProvider).value ?? const [];
    final fmt = ref.watch(settingsProvider).fmt;
    final cats = ref.watch(categoryMapProvider);
    final accts = {for (final a in ref.watch(allAccountsProvider).value ?? const <AccountRow>[]) a.id: a};
    final store = ref.watch(storeProvider);
    return Scaffold(
      appBar: AppBar(title: Text(s.reviewInbox)),
      body: unparsed.isEmpty && txs.isEmpty
          ? EmptyState(emoji: '✅', title: s.reviewEmpty)
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (txs.isNotEmpty) ...[
                Text(s.ar ? 'عمليات بحاجة لتأكيد' : 'Transactions to confirm', style: context.tt.titleSmall),
                const SizedBox(height: 8),
                FCard(
                  padding: EdgeInsets.zero,
                  child: Column(children: [
                    for (final t in txs)
                      Dismissible(
                        key: ValueKey(t.id),
                        background: Container(color: p.positiveBg, alignment: AlignmentDirectional.centerStart, padding: const EdgeInsets.all(20), child: Icon(Icons.check, color: p.positive)),
                        secondaryBackground: Container(color: p.negativeBg, alignment: AlignmentDirectional.centerEnd, padding: const EdgeInsets.all(20), child: Icon(Icons.delete, color: p.negative)),
                        onDismissed: (dir) async {
                          if (dir == DismissDirection.startToEnd) {
                            await store.updateTransaction(t.id, const TransactionsCompanion(needsReview: Value(false)));
                          } else {
                            await store.deleteTransaction(t.id);
                            if (context.mounted) showUndoSnack(context, s.deleted, s.undo, () => store.restoreTransaction(t.id));
                          }
                        },
                        child: TxTile(t: t, cats: cats, accounts: accts, fmt: fmt, onTap: () => context.push('/transactions/${t.id}')),
                      ),
                  ]),
                ),
                const SizedBox(height: 6),
                Text(s.ar ? 'اسحب لليمين للتأكيد، ولليسار للحذف.' : 'Swipe right to confirm, left to delete.', style: context.tt.bodySmall?.copyWith(color: p.inkSecondary)),
                const SizedBox(height: 20),
              ],
              if (unparsed.isNotEmpty) ...[
                Text(s.ar ? 'رسائل لم نتمكن من قراءتها' : "Messages we couldn't read", style: context.tt.titleSmall),
                const SizedBox(height: 8),
                for (final e in unparsed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: FCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          Pill(e.sender ?? e.source),
                          const Spacer(),
                          Text(fmt.dayMonth(ReportingZone.kuwait.toWall(e.receivedAt)) + ' ' + fmt.time(ReportingZone.kuwait.toWall(e.receivedAt)), style: context.tt.bodySmall),
                        ]),
                        const SizedBox(height: 8),
                        Text(e.rawText ?? (s.ar ? '(تم حذف النص بعد انتهاء مدة الاحتفاظ)' : '(text deleted after retention period)'), style: context.tt.bodyMedium),
                        if (e.notes != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(e.notes!, style: context.tt.bodySmall?.copyWith(color: p.inkSecondary))),
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, children: [
                          FilledButton.tonal(
                            onPressed: () async {
                              final id = await showAddTransactionSheet(context, ref, draft: TxDraft(note: e.rawText, source: e.source == 'shortcut' ? 'shortcut' : (e.source == 'notification' ? 'notification' : 'sms')));
                              if (id != null) {
                                await (store.db.update(store.db.sourceEvents)..where((x) => x.id.equals(e.id))).write(SourceEventsCompanion(status: const Value('posted'), transactionId: Value(id), rawText: const Value(null)));
                              }
                            },
                            child: Text(s.add),
                          ),
                          OutlinedButton(
                            onPressed: () => (store.db.update(store.db.sourceEvents)..where((x) => x.id.equals(e.id))).write(const SourceEventsCompanion(status: Value('ignored'), rawText: Value(null))),
                            child: Text(s.dismiss),
                          ),
                          if (e.rawText != null) TextButton(onPressed: () => _submitSample(context, ref, e), child: Text(s.sampleSubmitTitle)),
                        ]),
                      ]),
                    ),
                  ),
              ],
            ]),
    );
  }

  Future<void> _submitSample(BuildContext context, WidgetRef ref, SourceEventRow e) async {
    final s = S.of(context);
    final api = ref.read(apiProvider);
    final store = ref.read(storeProvider);
    final clean = sanitizeMessage(e.rawText!);
    final consent = await store.getSetting('consent_sample_submission') == 'true';
    if (!context.mounted) return;
    final ok = await showFSheet<bool>(
      context,
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(s.sampleSubmitTitle, style: context.tt.titleLarge),
          Text(s.sampleSubmitBody, style: context.tt.bodySmall),
          const SizedBox(height: 12),
          Text(s.sanitizedPreview, style: context.tt.labelMedium),
          const SizedBox(height: 6),
          FCard(color: context.fp.surfaceMuted, child: SelectableText(clean.text)),
          if (clean.removed.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('${s.ar ? 'تمت إزالة' : 'Removed'}: ${clean.removed.join(', ')}', style: context.tt.bodySmall)),
          const SizedBox(height: 12),
          if (!api.configured) Text(s.backendNotConfigured, style: TextStyle(color: context.fp.warning)),
          FilledButton(onPressed: api.configured && ref.read(sessionProvider).value != null ? () => Navigator.pop(context, true) : null, child: Text(s.send)),
        ]),
      ),
    );
    if (ok != true) return;
    try {
      if (!consent) {
        await api.recordConsent('sample_submission', true, '2026-11-22');
        await store.setSetting('consent_sample_submission', 'true');
      }
      await api.submitSample({'bank_id': e.bankId, 'sender': e.sender, 'sanitized_text': clean.text, 'app_version': '0.1.0'});
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.saved)));
    } catch (err) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.genericError)));
    }
  }
}
