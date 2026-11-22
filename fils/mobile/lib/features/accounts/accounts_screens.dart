import 'package:drift/drift.dart' show Value;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money/money.dart';
import '../../core/parsing/bank_registry.dart';
import '../../core/time/kuwait_time.dart';
import '../../data/db/database.dart';
import '../../data/store.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import 'account_widgets.dart';

String accountKindLabel(S s, String k) => switch (k) {
      'card' => s.typeCard,
      'cash' => s.typeCash,
      'savings' => s.typeSavings,
      'wallet' => s.typeWallet,
      'loan' => s.typeLoan,
      _ => s.typeBank,
    };

class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final accounts = ref.watch(allAccountsProvider).value ?? const <AccountRow>[];
    final balances = ref.watch(balancesProvider);
    final fmt = ref.watch(settingsProvider).fmt;
    final active = accounts.where((a) => !a.archived).toList();
    final archived = accounts.where((a) => a.archived).toList();
    Widget tile(AccountRow a) => ListTile(
          leading: accountBadge(a),
          title: Text(a.name),
          subtitle: Text([accountKindLabel(s, a.kind), if (a.maskLast4 != null) '•••• ${a.maskLast4}', if (a.isDefault) s.defaultAccount].join(' · ')),
          trailing: Directionality(textDirection: TextDirection.ltr, child: Text(fmt.money(balances[a.id] ?? 0, a.currency), style: context.tt.titleSmall)),
          onTap: () => context.push('/accounts/${a.id}'),
        );
    return Scaffold(
      appBar: AppBar(title: Text(s.accounts), actions: [IconButton(icon: const Icon(Icons.add), tooltip: s.addAccount, onPressed: () => context.push('/accounts/new'))]),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (active.isEmpty) EmptyState(emoji: '🏦', title: s.obAccountsTitle, body: s.obAccountsBody, action: s.addAccount, onAction: () => context.push('/accounts/new')),
          if (active.isNotEmpty) FCard(padding: EdgeInsets.zero, child: Column(children: [for (final a in active) tile(a)])),
          const SizedBox(height: 8),
          Text(s.calculatedBalanceNote, style: context.tt.bodySmall?.copyWith(color: context.fp.inkSecondary)),
          if (archived.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(s.archive, style: context.tt.titleSmall),
            const SizedBox(height: 8),
            FCard(padding: EdgeInsets.zero, child: Column(children: [for (final a in archived) tile(a)])),
          ],
        ],
      ),
    );
  }
}

class AccountDetailScreen extends ConsumerWidget {
  final String id;
  const AccountDetailScreen({super.key, required this.id});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final p = context.fp;
    final accounts = ref.watch(allAccountsProvider).value ?? const <AccountRow>[];
    final a = accounts.where((x) => x.id == id).firstOrNull;
    if (a == null) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    final fmt = ref.watch(settingsProvider).fmt;
    final bal = ref.watch(balancesProvider)[a.id] ?? 0;
    final payer = ref.watch(settingsProvider).raw[SettingKeys.defaultPayerAccount];
    final store = ref.watch(storeProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(a.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'edit':
                  context.push('/accounts/${a.id}/edit');
                case 'archive':
                  await store.archiveAccount(a.id, !a.archived);
                case 'default':
                  for (final o in accounts) {
                    if (o.isDefault && o.id != a.id) await store.updateAccount(o.id, const AccountsCompanion(isDefault: Value(false)));
                  }
                  await store.updateAccount(a.id, const AccountsCompanion(isDefault: Value(true)));
                case 'payer':
                  await store.setSetting(SettingKeys.defaultPayerAccount, a.id);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'edit', child: Text(s.edit)),
              PopupMenuItem(value: 'default', child: Text(s.defaultAccount)),
              if (!a.isLiability && a.kind != 'cash') PopupMenuItem(value: 'payer', child: Text(s.setAsPayer)),
              PopupMenuItem(value: 'archive', child: Text(a.archived ? s.unarchive : s.archive)),
            ],
          ),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: FCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  accountBadge(a, size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(a.name, style: context.tt.titleMedium),
                      Text([accountKindLabel(s, a.kind), if (a.maskLast4 != null) '•••• ${a.maskLast4}', if (payer == a.id) s.setAsPayer].join(' · '),
                          style: context.tt.bodySmall?.copyWith(color: p.inkSecondary)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 16),
                Text(s.calculatedBalance, style: context.tt.labelMedium?.copyWith(color: p.inkSecondary)),
                Directionality(textDirection: TextDirection.ltr, child: Text(fmt.money(bal, a.currency), style: context.tt.headlineMedium)),
                Text(s.calculatedBalanceNote, style: context.tt.bodySmall?.copyWith(color: p.inkSecondary)),
                if (a.reportedBalanceAt != null) ...[
                  const SizedBox(height: 12),
                  Text(s.lastBankBalance, style: context.tt.labelMedium?.copyWith(color: p.inkSecondary)),
                  Text(
                    [
                      if (a.reportedBalanceMinor != null) fmt.money(a.reportedBalanceMinor!, a.currency),
                      if (a.reportedAvailableMinor != null) '${s.availableBalance}: ${fmt.money(a.reportedAvailableMinor!, a.currency)}',
                    ].join(' · '),
                    style: context.tt.titleSmall,
                  ),
                  Text(fmt.dayMonthYear(ReportingZone.kuwait.toWall(a.reportedBalanceAt!)) + ' ' + fmt.time(ReportingZone.kuwait.toWall(a.reportedBalanceAt!)),
                      style: context.tt.bodySmall?.copyWith(color: p.inkSecondary)),
                ],
                const SizedBox(height: 12),
                OutlinedButton.icon(icon: const Icon(Icons.balance), label: Text(s.reconcile), onPressed: () => _reconcile(context, ref, a)),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FCard(
              padding: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: Text(s.transactions),
                trailing: Icon(context.isRtl ? Icons.chevron_left : Icons.chevron_right),
                onTap: () => context.push('/accounts/${a.id}/transactions'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _reconcile(BuildContext context, WidgetRef ref, AccountRow a) async {
    final s = S.of(context);
    final ctrl = TextEditingController(text: a.reportedBalanceMinor == null ? '' : Money(a.reportedBalanceMinor!, a.currency).toDecimalString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.reconcile),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(s.reconcileBody),
          const SizedBox(height: 12),
          TextField(controller: ctrl, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: InputDecoration(labelText: s.actualBalance)),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.save))],
      ),
    );
    if (ok != true) return;
    final m = Money.parse(ctrl.text, a.currency);
    if (m == null) return;
    await ref.read(storeProvider).reconcile(a.id, m.minor);
  }
}

class AccountFormScreen extends ConsumerStatefulWidget {
  final String? editId;
  const AccountFormScreen({super.key, this.editId});
  @override
  ConsumerState<AccountFormScreen> createState() => _AccountFormScreenState();
}

class _AccountFormScreenState extends ConsumerState<AccountFormScreen> {
  final name = TextEditingController();
  final last4 = TextEditingController();
  final opening = TextEditingController();
  final limit = TextEditingController();
  String kind = 'bank';
  String? bankId;
  String currency = 'KWD';
  bool liability = false;
  DateTime openingDate = DateTime.now().toUtc();
  String? error;
  bool loaded = false;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    if (widget.editId != null && !loaded) {
      final a = (ref.watch(allAccountsProvider).value ?? const <AccountRow>[]).where((x) => x.id == widget.editId).firstOrNull;
      if (a != null) {
        loaded = true;
        name.text = a.name;
        last4.text = a.maskLast4 ?? '';
        kind = a.kind;
        bankId = a.institutionId;
        currency = a.currency;
        liability = a.isLiability;
        opening.text = Money(a.openingBalanceMinor.abs(), a.currency).toDecimalString();
        openingDate = a.openingBalanceDate;
        if (a.creditLimitMinor != null) limit.text = Money(a.creditLimitMinor!, a.currency).toDecimalString();
      }
    }
    final fmt = ref.watch(settingsProvider).fmt;
    return Scaffold(
      appBar: AppBar(title: Text(widget.editId == null ? s.addAccount : s.edit)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(s.bank, style: context.tt.titleSmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final b in kuwaitBanks)
              ChoiceChip(
                avatar: BankBadge(code: b.shortCode, color: Color(b.brandColor), size: 22),
                label: Text(s.ar ? b.nameAr : b.nameEn),
                selected: bankId == b.id,
                onSelected: (_) => setState(() {
                  bankId = b.id;
                  if (name.text.isEmpty) name.text = b.nameEn;
                }),
              ),
            ChoiceChip(label: Text(s.otherBank), selected: bankId == null, onSelected: (_) => setState(() => bankId = null)),
          ]),
          const SizedBox(height: 16),
          TextField(controller: name, decoration: InputDecoration(labelText: s.accountName)),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: kind,
            decoration: InputDecoration(labelText: s.accountType),
            items: [for (final k in accountKinds) DropdownMenuItem(value: k, child: Text(accountKindLabel(s, k)))],
            onChanged: (v) => setState(() {
              kind = v!;
              liability = kind == 'loan' || (kind == 'card' && liability);
            }),
          ),
          if (kind == 'card')
            SwitchListTile(value: liability, onChanged: (v) => setState(() => liability = v), title: Text(s.creditCardLiability), contentPadding: EdgeInsets.zero),
          const SizedBox(height: 12),
          TextField(
            controller: last4,
            keyboardType: TextInputType.number,
            maxLength: 4,
            decoration: InputDecoration(labelText: s.last4, helperText: s.last4Help, helperMaxLines: 2),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: currency,
            decoration: InputDecoration(labelText: s.currency),
            items: [for (final c in Currency.all) DropdownMenuItem(value: c.code, child: Text('${c.code} · ${s.ar ? c.symbolAr : c.symbolEn}'))],
            onChanged: widget.editId != null ? null : (v) => setState(() => currency = v!),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: opening,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: liability ? (s.ar ? 'المبلغ المستحق حالياً' : 'Amount currently owed') : s.openingBalance),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.event),
            label: Text('${s.openingBalanceDate}: ${fmt.dayMonthYear(ReportingZone.kuwait.toWall(openingDate))}'),
            onPressed: () async {
              final w = ReportingZone.kuwait.toWall(openingDate);
              final d = await showDatePicker(context: context, initialDate: w, firstDate: DateTime(2010), lastDate: DateTime(2100));
              if (d != null) setState(() => openingDate = ReportingZone.kuwait.fromWall(d.year, d.month, d.day));
            },
          ),
          if (liability && kind == 'card') ...[
            const SizedBox(height: 12),
            TextField(controller: limit, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: s.creditLimit)),
          ],
          if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: context.fp.negative))),
          const SizedBox(height: 20),
          FilledButton(onPressed: _save, child: Text(s.save)),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final s = S.of(context);
    if (name.text.trim().isEmpty) return setState(() => error = s.required);
    final l4 = last4.text.trim();
    if (l4.isNotEmpty && !RegExp(r'^\d{4}$').hasMatch(l4)) return setState(() => error = s.last4);
    final ob = opening.text.trim().isEmpty ? 0 : Money.parseMinor(opening.text, Currency.of(currency).exponent);
    if (ob == null) return setState(() => error = s.invalidAmount);
    final lim = limit.text.trim().isEmpty ? null : Money.parseMinor(limit.text, Currency.of(currency).exponent);
    final signedOpening = liability ? -ob.abs() : ob;
    final store = ref.read(storeProvider);
    if (widget.editId == null) {
      await store.createAccount(
        name: name.text.trim(),
        kind: kind,
        currency: currency,
        institutionId: bankId,
        maskLast4: l4.isEmpty ? null : l4,
        openingBalanceMinor: signedOpening,
        openingBalanceDate: openingDate,
        isLiability: liability,
        creditLimitMinor: lim,
        color: bankById(bankId)?.brandColor,
      );
    } else {
      await store.updateAccount(
        widget.editId!,
        AccountsCompanion(
          name: Value(name.text.trim()),
          kind: Value(kind),
          institutionId: Value(bankId),
          maskLast4: Value(l4.isEmpty ? null : l4),
          openingBalanceMinor: Value(signedOpening),
          openingBalanceDate: Value(openingDate),
          isLiability: Value(liability),
          creditLimitMinor: Value(lim),
        ),
      );
    }
    if (mounted) context.pop();
  }
}
