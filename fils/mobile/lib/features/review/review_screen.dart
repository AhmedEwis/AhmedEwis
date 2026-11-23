import 'dart:convert';

import 'package:drift/drift.dart' show Value, OrderingTerm, OrderingMode, BooleanExpressionOperators;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/services.dart';
import '../../core/parsing/sanitizer.dart';
import '../../core/time/kuwait_time.dart';
import '../../data/db/database.dart';
import '../../data/ingestion.dart' show kHeld;
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

final _heldProvider = StreamProvider<List<SourceEventRow>>((ref) {
  final db = ref.watch(storeProvider).db;
  return (db.select(db.sourceEvents)
        ..where((s) => s.status.equals(kHeld))
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
    final held = ref.watch(_heldProvider).value ?? const [];
    final txs = ref.watch(_reviewTxProvider).value ?? const [];
    final fmt = ref.watch(settingsProvider).fmt;
    final cats = ref.watch(categoryMapProvider);
    final accts = {for (final a in ref.watch(allAccountsProvider).value ?? const <AccountRow>[]) a.id: a};
    final store = ref.watch(storeProvider);
    return Scaffold(
      appBar: AppBar(title: Text(s.reviewInbox)),
      body: unparsed.isEmpty && txs.isEmpty && held.isEmpty
          ? EmptyState(emoji: '✅', title: s.reviewEmpty)
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (held.isNotEmpty) ...[
                Text(s.ar ? 'تكرار محتمل: غير محتسب حتى تؤكد' : 'Possible duplicates: not counted until you decide', style: context.tt.titleSmall),
                const SizedBox(height: 8),
                for (final e in held) _HeldCard(e: e),
                const SizedBox(height: 20),
              ],
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

/// A held possible duplicate. No transaction exists for it, so it has no effect on
/// balances or spending until the user resolves it.
class _HeldCard extends ConsumerWidget {
  final SourceEventRow e;
  const _HeldCard({required this.e});

  String _summary(SourceEventRow e) {
    final raw = e.rawText;
    if (raw == null) return '';
    if (e.source != 'wallet') return raw;
    try {
      final m = jsonDecode(raw) as Map;
      return [m['merchant'] ?? m['name'], m['amount'], m['card']].where((x) => x != null && '$x'.trim().isNotEmpty).join(' · ');
    } catch (_) {
      return raw;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final p = context.fp;
    final store = ref.watch(storeProvider);
    final ing = ref.watch(ingestionProvider);
    final fmt = ref.watch(settingsProvider).fmt;
    final cats = ref.watch(categoryMapProvider);
    final accts = {for (final a in ref.watch(allAccountsProvider).value ?? const <AccountRow>[]) a.id: a};
    final ids = (e.matchCandidates ?? '').split(',').where((x) => x.isNotEmpty).toList();
    Future<void> run(Future<void> Function() f) async {
      try {
        await f();
      } catch (err) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$err'.replaceFirst('Bad state: ', ''))));
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: FCard(
        child: FutureBuilder<List<TxRow>>(
          future: Future.wait(ids.map(store.transaction)).then((l) => l.whereType<TxRow>().where((t) => t.deletedAt == null).toList()),
          builder: (context, snap) {
            final cands = snap.data ?? const <TxRow>[];
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Pill(e.sender ?? e.source, bg: p.warningBg, fg: p.warning),
                const Spacer(),
                Text('${fmt.dayMonth(ReportingZone.kuwait.toWall(e.receivedAt))} ${fmt.time(ReportingZone.kuwait.toWall(e.receivedAt))}', style: context.tt.bodySmall),
              ]),
              const SizedBox(height: 8),
              Text(_summary(e), style: context.tt.bodyMedium),
              if (e.notes != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(e.notes!, style: context.tt.bodySmall?.copyWith(color: p.inkSecondary))),
              if (cands.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(s.ar ? 'يشبه:' : 'Looks like:', style: context.tt.labelMedium),
                for (final t in cands) TxTile(t: t, cats: cats, accounts: accts, fmt: fmt),
              ],
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: [
                if (cands.isNotEmpty)
                  FilledButton.tonal(
                    onPressed: () => run(() async {
                      var target = cands.length == 1 ? cands.single : null;
                      target ??= await showFSheet<TxRow>(
                        context,
                        Column(mainAxisSize: MainAxisSize.min, children: [
                          for (final t in cands) TxTile(t: t, cats: cats, accounts: accts, fmt: fmt, onTap: () => Navigator.of(context).pop(t)),
                        ]),
                      );
                      if (target != null) await ing.confirmSameTransaction(e.id, target.id);
                    }),
                    child: Text(s.ar ? 'نفس العملية' : 'Same transaction'),
                  ),
                OutlinedButton(
                  onPressed: () => run(() async => ing.confirmSeparate(e.id)),
                  child: Text(s.ar ? 'عملية منفصلة' : 'Separate purchase'),
                ),
                TextButton(
                  onPressed: () => (store.db.update(store.db.sourceEvents)..where((x) => x.id.equals(e.id)))
                      .write(const SourceEventsCompanion(status: Value('ignored'), rawText: Value(null), matchCandidates: Value(null))),
                  child: Text(s.dismiss),
                ),
              ]),
            ]);
          },
        ),
      ),
    );
  }
}
