import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/domain/categories.dart';
import '../../core/ledger/ledger.dart';
import '../../core/money/money.dart';
import '../../core/time/kuwait_time.dart';
import '../../data/db/database.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/theme/tokens.dart';
import '../../ui/widgets/common.dart';
import '../accounts/account_widgets.dart';

/// Prefill data (from voice, a review item, or an existing transaction).
class TxDraft {
  final String kind; // expense|income|transfer
  final int? amountMinor;
  final String? currency;
  final String? merchant;
  final String? categoryId;
  final String? accountId;
  final String? counterAccountId;
  final DateTime? occurredAt;
  final String? note;
  final String source;
  final String? editId;
  const TxDraft({
    this.kind = TxKinds.expense,
    this.amountMinor,
    this.currency,
    this.merchant,
    this.categoryId,
    this.accountId,
    this.counterAccountId,
    this.occurredAt,
    this.note,
    this.source = 'manual',
    this.editId,
  });

  factory TxDraft.fromTx(TxRow t) => TxDraft(
        kind: t.kind,
        amountMinor: t.amountMinor,
        currency: t.currency,
        merchant: t.merchant,
        categoryId: t.categoryId,
        accountId: t.accountId,
        counterAccountId: t.counterAccountId,
        occurredAt: t.occurredAt,
        note: t.note,
        source: t.source,
        editId: t.id,
      );
}

Future<String?> showAddTransactionSheet(BuildContext context, WidgetRef ref, {TxDraft draft = const TxDraft()}) =>
    showFSheet<String>(context, AddTransactionForm(draft: draft));

class AddTransactionForm extends ConsumerStatefulWidget {
  final TxDraft draft;
  const AddTransactionForm({super.key, required this.draft});
  @override
  ConsumerState<AddTransactionForm> createState() => _AddTransactionFormState();
}

class _AddTransactionFormState extends ConsumerState<AddTransactionForm> {
  late String kind = widget.draft.kind == TxKinds.refund ? TxKinds.income : widget.draft.kind;
  late final TextEditingController amount;
  late final TextEditingController merchant = TextEditingController(text: widget.draft.merchant ?? '');
  late final TextEditingController note = TextEditingController(text: widget.draft.note ?? '');
  String? categoryId;
  String? accountId;
  String? counterId;
  late DateTime occurred = widget.draft.occurredAt ?? DateTime.now().toUtc();
  String? error;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    categoryId = widget.draft.categoryId;
    accountId = widget.draft.accountId;
    counterId = widget.draft.counterAccountId;
    final cur = widget.draft.currency ?? 'KWD';
    amount = TextEditingController(text: widget.draft.amountMinor == null ? '' : Money(widget.draft.amountMinor!, cur).toDecimalString());
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = context.fp;
    final accounts = ref.watch(accountsProvider).value ?? const <AccountRow>[];
    final cats = (ref.watch(categoriesProvider).value ?? const <CategoryRow>[])
        .where((c) => kind == TxKinds.income ? c.kind == 'income' : c.kind == 'expense')
        .toList();
    accountId ??= accounts.where((a) => a.isDefault).firstOrNull?.id ?? accounts.firstOrNull?.id;
    final acct = accounts.where((a) => a.id == accountId).firstOrNull;
    final currency = acct?.currency ?? widget.draft.currency ?? ref.watch(settingsProvider).baseCurrency;
    final fmt = ref.watch(settingsProvider).fmt;
    final wall = ReportingZone.kuwait.toWall(occurred);

    return Padding(
      padding: const EdgeInsets.fromLTRB(FilsSpace.gutter, 0, FilsSpace.gutter, FilsSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Segmented<String>(
            items: [(TxKinds.expense, s.expense), (TxKinds.income, s.incomeKind), (TxKinds.transfer, s.transfer)],
            value: kind == TxKinds.adjustUp || kind == TxKinds.adjustDown ? TxKinds.expense : kind,
            onChanged: (v) => setState(() {
              kind = v;
              categoryId = null;
            }),
          ),
          const SizedBox(height: 20),
          Center(
            child: IntrinsicWidth(
              child: TextField(
                controller: amount,
                autofocus: widget.draft.amountMinor == null,
                textAlign: TextAlign.center,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9٠-٩.,٫]'))],
                style: context.tt.displayMedium,
                decoration: InputDecoration(
                  filled: false,
                  hintText: Money(0, currency).toDecimalString(),
                  suffixText: ' ${fmt.symbol(currency)}',
                  border: InputBorder.none,
                ),
                onChanged: (_) => setState(() => error = null),
              ),
            ),
          ),
          if (error != null) Text(error!, textAlign: TextAlign.center, style: TextStyle(color: p.negative)),
          const SizedBox(height: 12),
          if (kind != TxKinds.transfer)
            TextField(controller: merchant, decoration: InputDecoration(hintText: s.merchant, prefixIcon: const Icon(Icons.storefront_outlined))),
          const SizedBox(height: 12),
          _AccountPicker(label: s.account, accounts: accounts, value: accountId, onChanged: (v) => setState(() => accountId = v)),
          if (kind == TxKinds.transfer) ...[
            const SizedBox(height: 12),
            _AccountPicker(label: s.toAccount, accounts: accounts.where((a) => a.id != accountId).toList(), value: counterId, onChanged: (v) => setState(() => counterId = v)),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today_outlined, size: 18),
                label: Text('${fmt.dayMonthYear(wall)}  ${fmt.time(wall)}'),
                onPressed: () async {
                  final d = await showDatePicker(context: context, initialDate: wall, firstDate: DateTime(2015), lastDate: DateTime(2100));
                  if (d == null || !context.mounted) return;
                  final tm = await showTimePicker(context: context, initialTime: TimeOfDay(hour: wall.hour, minute: wall.minute));
                  setState(() => occurred = ReportingZone.kuwait.fromWall(d.year, d.month, d.day, tm?.hour ?? wall.hour, tm?.minute ?? wall.minute));
                },
              ),
            ),
          ]),
          if (kind != TxKinds.transfer) ...[
            const SizedBox(height: 16),
            Text(s.category, style: context.tt.titleSmall),
            const SizedBox(height: 8),
            CategoryGrid(categories: cats, selected: categoryId, onSelected: (id) => setState(() => categoryId = id)),
          ],
          const SizedBox(height: 12),
          TextField(controller: note, decoration: InputDecoration(hintText: s.note, prefixIcon: const Icon(Icons.notes_rounded))),
          const SizedBox(height: 20),
          FilledButton(onPressed: saving ? null : () => _save(context, currency), child: Text(s.save)),
        ],
      ),
    );
  }

  Future<void> _save(BuildContext context, String currency) async {
    final s = S.of(context);
    final minor = Money.parseMinor(amount.text, Currency.of(currency).exponent);
    if (minor == null || minor <= 0) {
      setState(() => error = s.invalidAmount);
      return;
    }
    if (accountId == null || (kind == TxKinds.transfer && counterId == null)) {
      setState(() => error = s.required);
      return;
    }
    setState(() => saving = true);
    final store = ref.read(storeProvider);
    final cat = kind == TxKinds.transfer ? null : (categoryId ?? (kind == TxKinds.income ? Cat.otherIncome : Cat.other));
    String id;
    if (widget.draft.editId != null) {
      id = widget.draft.editId!;
      await store.updateTransaction(
        id,
        TransactionsCompanion(
          kind: Value(kind),
          amountMinor: Value(minor),
          currency: Value(currency),
          accountId: Value(accountId!),
          counterAccountId: Value(kind == TxKinds.transfer ? counterId : null),
          merchant: Value(merchant.text.trim().isEmpty ? null : merchant.text.trim()),
          categoryId: Value(cat),
          occurredAt: Value(occurred),
          note: Value(note.text.trim().isEmpty ? null : note.text.trim()),
          needsReview: const Value(false),
        ),
      );
    } else {
      final t = await store.addTransaction(
        accountId: accountId!,
        kind: kind,
        amountMinor: minor,
        currency: currency,
        counterAccountId: kind == TxKinds.transfer ? counterId : null,
        occurredAt: occurred,
        source: widget.draft.source,
        merchant: merchant.text.trim().isEmpty ? null : merchant.text.trim(),
        categoryId: cat,
        note: note.text.trim().isEmpty ? null : note.text.trim(),
      );
      id = t.id;
    }
    if (context.mounted) Navigator.of(context).pop(id);
  }
}

class _AccountPicker extends StatelessWidget {
  final String label;
  final List<AccountRow> accounts;
  final String? value;
  final ValueChanged<String?> onChanged;
  const _AccountPicker({required this.label, required this.accounts, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: accounts.any((a) => a.id == value) ? value : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final a in accounts)
          DropdownMenuItem(
            value: a.id,
            child: Row(children: [accountBadge(a, size: 26), const SizedBox(width: 10), Expanded(child: Text(a.name, overflow: TextOverflow.ellipsis))]),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

class CategoryGrid extends StatelessWidget {
  final List<CategoryRow> categories;
  final String? selected;
  final ValueChanged<String> onSelected;
  const CategoryGrid({super.key, required this.categories, required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = context.fp;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in categories)
          Semantics(
            selected: c.id == selected,
            button: true,
            label: s.ar ? c.nameAr : c.nameEn,
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(FilsRadius.md),
              onTap: () => onSelected(c.id),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 104,
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                decoration: BoxDecoration(
                  color: c.id == selected ? Color(c.color).withValues(alpha: 0.16) : p.surface,
                  borderRadius: BorderRadius.circular(FilsRadius.md),
                  border: Border.all(color: c.id == selected ? Color(c.color) : p.border, width: c.id == selected ? 1.5 : 1),
                ),
                child: Column(children: [
                  Text(c.icon, style: const TextStyle(fontSize: 22)),
                  const SizedBox(height: 4),
                  Text(s.ar ? c.nameAr : c.nameEn, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.labelMedium),
                ]),
              ),
            ),
          ),
      ],
    );
  }
}
