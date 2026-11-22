import 'package:drift/drift.dart' show Value;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/ledger/ledger.dart';
import '../../core/money/money.dart';
import '../../core/parsing/bank_registry.dart';
import '../../core/time/kuwait_time.dart';
import '../../data/db/database.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/tx_tile.dart';
import 'add_transaction_sheet.dart';

final _txByIdProvider = StreamProvider.family<TxRow?, String>((ref, id) {
  final db = ref.watch(storeProvider).db;
  return (db.select(db.transactions)..where((t) => t.id.equals(id))).watchSingleOrNull();
});

final _sourceEventProvider = StreamProvider.family<SourceEventRow?, String>((ref, id) {
  final db = ref.watch(storeProvider).db;
  return (db.select(db.sourceEvents)..where((t) => t.id.equals(id))).watchSingleOrNull();
});

class TransactionDetailScreen extends ConsumerWidget {
  final String id;
  const TransactionDetailScreen({super.key, required this.id});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final p = context.fp;
    final tx = ref.watch(_txByIdProvider(id));
    final fmt = ref.watch(settingsProvider).fmt;
    final cats = ref.watch(categoryMapProvider);
    final accounts = ref.watch(allAccountsProvider).value ?? const <AccountRow>[];
    final acctMap = {for (final a in accounts) a.id: a};
    final store = ref.watch(storeProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.transactions),
        actions: [
          if (tx.value != null)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: s.edit,
              onPressed: () => showAddTransactionSheet(context, ref, draft: TxDraft.fromTx(tx.value!)),
            ),
        ],
      ),
      body: tx.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(s.genericError)),
        data: (t) {
          if (t == null) return Center(child: Text(s.deleted));
          final v = txVisual(context, t, cats, acctMap, fmt);
          final ev = t.sourceEventId == null ? null : ref.watch(_sourceEventProvider(t.sourceEventId!)).value;
          final occurred = ReportingZone.kuwait.toWall(t.occurredAt);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(child: CategoryTile(emoji: v.emoji, color: v.color, size: 72)),
              const SizedBox(height: 12),
              Center(child: Text(v.title, style: context.tt.titleLarge, textAlign: TextAlign.center)),
              const SizedBox(height: 6),
              Center(
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: Text(v.amountText,
                      style: context.tt.displayMedium?.copyWith(color: v.amountColor, decoration: v.strike ? TextDecoration.lineThrough : null)),
                ),
              ),
              if (v.statusPill != null) Center(child: Padding(padding: const EdgeInsets.only(top: 6), child: Pill(v.statusPill!))),
              if (t.deletedAt != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: FilledButton.icon(onPressed: () => store.restoreTransaction(t.id), icon: const Icon(Icons.restore), label: Text(s.undo)),
                ),
              if (t.needsReview) ...[
                const SizedBox(height: 16),
                FCard(
                  color: p.warningBg,
                  child: Row(children: [
                    Icon(Icons.info_outline, color: p.warning),
                    const SizedBox(width: 10),
                    Expanded(child: Text(ev?.notes ?? s.needsReview, style: context.tt.bodyMedium)),
                    TextButton(
                      onPressed: () => store.updateTransaction(t.id, const TransactionsCompanion(needsReview: Value(false))),
                      child: Text(s.markReviewed),
                    ),
                  ]),
                ),
              ],
              const SizedBox(height: 16),
              FCard(
                padding: EdgeInsets.zero,
                child: Column(children: [
                  _Row(s.category, t.categoryId == null ? '—' : '${cats[t.categoryId]?.icon ?? ''} ${s.ar ? cats[t.categoryId]?.nameAr ?? '' : cats[t.categoryId]?.nameEn ?? ''}',
                      onTap: t.kind == TxKinds.expense || t.kind == TxKinds.income || t.kind == TxKinds.refund ? () => _pickCategory(context, ref, t) : null),
                  _Row(s.account, acctMap[t.accountId]?.name ?? '—'),
                  if (t.counterAccountId != null) _Row(s.toAccount, acctMap[t.counterAccountId]?.name ?? '—'),
                  _Row(s.occurredAt, '${fmt.dayMonthYear(occurred)} · ${fmt.time(occurred)}'),
                  if (t.merchantRaw != null && t.merchantRaw != t.merchant) _Row(s.merchant, t.merchantRaw!),
                  if (t.processor != null) _Row(s.ar ? 'معالج الدفع' : 'Payment processor', t.processor!),
                  if (t.originalAmountMinor != null && t.originalCurrency != null) ...[
                    _Row(s.originalAmount, fmt.money(t.originalAmountMinor!, t.originalCurrency!)),
                    _Row(s.fxRateLabel, t.fxRate ?? (t.fxSource == 'bank_billed' ? s.billedByBank : '—')),
                  ],
                  if (t.note != null) _Row(s.note, t.note!),
                ]),
              ),
              const SizedBox(height: 16),
              Text(s.source, style: context.tt.titleSmall),
              const SizedBox(height: 8),
              FCard(
                padding: EdgeInsets.zero,
                child: Column(children: [
                  _Row(s.source, _sourceLabel(s, t.source)),
                  if (ev?.sender != null) _Row(s.ar ? 'المرسل' : 'Sender', ev!.sender!),
                  if (ev?.bankId != null) _Row(s.bank, bankById(ev!.bankId)?.nameEn ?? ev.bankId!),
                  if (t.receivedAt != null) _Row(s.receivedAt, fmt.time(ReportingZone.kuwait.toWall(t.receivedAt!))),
                  if (t.parserId != null) _Row(s.parser, '${t.parserId} ${t.parserVersion ?? ''}'),
                  if (t.confidence != null) _Row(s.confidence, fmt.percent(t.confidence!)),
                  if (ev?.rawText != null) _Row(s.ar ? 'النص الأصلي (يُحذف تلقائياً)' : 'Original text (auto-deleted)', ev!.rawText!),
                ]),
              ),
              const SizedBox(height: 16),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (t.kind == TxKinds.expense)
                  OutlinedButton.icon(icon: const Icon(Icons.call_split), label: Text(s.split), onPressed: () => _split(context, ref, t)),
                if (t.kind == TxKinds.expense)
                  OutlinedButton.icon(icon: const Icon(Icons.undo), label: Text(s.recordRefund), onPressed: () => _refund(context, ref, t)),
                if (t.kind == TxKinds.expense || t.kind == TxKinds.income)
                  OutlinedButton.icon(icon: const Icon(Icons.swap_horiz), label: Text(s.linkTransfer), onPressed: () => _linkTransfer(context, ref, t)),
                if (t.deletedAt == null)
                  OutlinedButton.icon(
                    icon: Icon(Icons.delete_outline, color: p.negative),
                    label: Text(s.delete, style: TextStyle(color: p.negative)),
                    onPressed: () async {
                      await store.deleteTransaction(t.id);
                      if (context.mounted) {
                        showUndoSnack(context, s.deleted, s.undo, () => store.restoreTransaction(t.id));
                        context.pop();
                      }
                    },
                  ),
              ]),
              const SizedBox(height: 40),
            ],
          );
        },
      ),
    );
  }

  String _sourceLabel(S s, String src) => switch (src) {
        'sms' => s.sourceLabelSms,
        'notification' => s.sourceLabelNotification,
        'shortcut' => s.sourceLabelShortcut,
        'wallet' => s.sourceLabelWallet,
        'voice' => s.sourceLabelVoice,
        'paste' || 'share' => s.sourceLabelPaste,
        'csv' || 'pdf' || 'image' => s.sourceLabelImport,
        _ => s.sourceLabelManual,
      };

  Future<void> _pickCategory(BuildContext context, WidgetRef ref, TxRow t) async {
    final s = S.of(context);
    var remember = false;
    final cats = (ref.read(categoriesProvider).value ?? const <CategoryRow>[])
        .where((c) => t.kind == TxKinds.income ? c.kind == 'income' : c.kind == 'expense')
        .toList();
    final picked = await showFSheet<String>(
      context,
      StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            CategoryGrid(categories: cats, selected: t.categoryId, onSelected: (id) => Navigator.pop(ctx, id)),
            if (t.merchant != null)
              CheckboxListTile(value: remember, onChanged: (v) => set(() => remember = v ?? false), title: Text(s.rememberCategory), contentPadding: EdgeInsets.zero),
          ]),
        ),
      ),
    );
    if (picked != null) await ref.read(storeProvider).setCategory(t.id, picked, remember: remember);
  }

  Future<void> _refund(BuildContext context, WidgetRef ref, TxRow t) async {
    final s = S.of(context);
    final ctrl = TextEditingController(text: Money(t.amountMinor, t.currency).toDecimalString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.recordRefund),
        content: TextField(controller: ctrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: s.amount)),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.save))],
      ),
    );
    if (ok != true) return;
    final m = Money.parse(ctrl.text, t.currency);
    if (m == null || m.minor <= 0) return;
    try {
      await ref.read(storeProvider).recordRefund(t.id, m.minor);
    } on ArgumentError catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${e.message}')));
    }
  }

  Future<void> _split(BuildContext context, WidgetRef ref, TxRow t) async {
    await showFSheet(context, SplitEditor(tx: t));
  }

  Future<void> _linkTransfer(BuildContext context, WidgetRef ref, TxRow t) async {
    final s = S.of(context);
    final store = ref.read(storeProvider);
    final fmt = ref.read(settingsProvider).fmt;
    final all = await store.transactionsBetween(t.occurredAt.subtract(const Duration(days: 3)), t.occurredAt.add(const Duration(days: 3)));
    final wantKind = t.kind == TxKinds.expense ? TxKinds.income : TxKinds.expense;
    final cands = all.where((x) => x.id != t.id && x.kind == wantKind && x.accountId != t.accountId && x.currency == t.currency).toList();
    if (!context.mounted) return;
    final picked = await showFSheet<String>(
      context,
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(s.linkTransferBody, style: context.tt.bodyMedium),
          const SizedBox(height: 8),
          if (cands.isEmpty) EmptyState(emoji: '🔍', title: s.noTransactions),
          for (final c in cands)
            ListTile(
              title: Text(c.merchant ?? c.note ?? '—'),
              subtitle: Text(fmt.dayMonth(ReportingZone.kuwait.toWall(c.occurredAt))),
              trailing: Text(fmt.money(c.amountMinor, c.currency)),
              onTap: () => Navigator.pop(context, c.id),
            ),
        ]),
      ),
    );
    if (picked == null) return;
    if (t.kind == TxKinds.expense) {
      await store.linkAsTransfer(t.id, picked);
    } else {
      await store.linkAsTransfer(picked, t.id);
    }
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onTap;
  const _Row(this.label, this.value, {this.onTap});
  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        title: Text(label, style: context.tt.bodyMedium?.copyWith(color: context.fp.inkSecondary)),
        subtitle: Text(value, style: context.tt.bodyLarge),
        trailing: onTap == null ? null : Icon(context.isRtl ? Icons.chevron_left : Icons.chevron_right),
        onTap: onTap,
      );
}

class SplitEditor extends ConsumerStatefulWidget {
  final TxRow tx;
  const SplitEditor({super.key, required this.tx});
  @override
  ConsumerState<SplitEditor> createState() => _SplitEditorState();
}

class _SplitEditorState extends ConsumerState<SplitEditor> {
  final rows = <(String?, TextEditingController)>[];
  String? error;

  @override
  void initState() {
    super.initState();
    ref.read(storeProvider).splitsFor(widget.tx.id).then((existing) {
      setState(() {
        if (existing.isEmpty) {
          rows.add((widget.tx.categoryId, TextEditingController(text: Money(widget.tx.amountMinor, widget.tx.currency).toDecimalString())));
          rows.add((null, TextEditingController()));
        } else {
          for (final e in existing) {
            rows.add((e.categoryId, TextEditingController(text: Money(e.amountMinor, widget.tx.currency).toDecimalString())));
          }
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final cats = (ref.watch(categoriesProvider).value ?? const <CategoryRow>[]).where((c) => c.kind == 'expense').toList();
    final fmt = ref.watch(settingsProvider).fmt;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${s.splitTransaction} · ${fmt.money(widget.tx.amountMinor, widget.tx.currency)}', style: context.tt.titleMedium),
        const SizedBox(height: 12),
        for (var i = 0; i < rows.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String>(
                  initialValue: rows[i].$1,
                  isExpanded: true,
                  items: [for (final c in cats) DropdownMenuItem(value: c.id, child: Text('${c.icon} ${s.ar ? c.nameAr : c.nameEn}', overflow: TextOverflow.ellipsis))],
                  onChanged: (v) => setState(() => rows[i] = (v, rows[i].$2)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: TextField(controller: rows[i].$2, keyboardType: const TextInputType.numberWithOptions(decimal: true))),
            ]),
          ),
        TextButton.icon(onPressed: () => setState(() => rows.add((null, TextEditingController()))), icon: const Icon(Icons.add), label: Text(s.add)),
        if (error != null) Text(error!, style: TextStyle(color: context.fp.negative)),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: () async {
            final parts = <({String categoryId, int amountMinor, String? note})>[];
            for (final r in rows) {
              if (r.$1 == null || r.$2.text.trim().isEmpty) continue;
              final m = Money.parse(r.$2.text, widget.tx.currency);
              if (m == null) {
                setState(() => error = s.invalidAmount);
                return;
              }
              parts.add((categoryId: r.$1!, amountMinor: m.minor, note: null));
            }
            try {
              await ref.read(storeProvider).replaceSplits(widget.tx.id, parts.length <= 1 ? [] : parts);
              if (context.mounted) Navigator.pop(context);
            } on ArgumentError {
              setState(() => error = s.splitsMustMatch);
            }
          },
          child: Text(s.save),
        ),
      ]),
    );
  }
}
