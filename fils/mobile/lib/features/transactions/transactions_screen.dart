import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/time/kuwait_time.dart';
import '../../data/db/database.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/theme/tokens.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/tx_tile.dart';
import 'add_transaction_sheet.dart';

class TxFilter {
  final String search;
  final String? accountId;
  final String? categoryId;
  final bool reviewOnly;
  const TxFilter({this.search = '', this.accountId, this.categoryId, this.reviewOnly = false});
  TxFilter copyWith({String? search, Object? accountId = _k, Object? categoryId = _k, bool? reviewOnly}) => TxFilter(
        search: search ?? this.search,
        accountId: accountId == _k ? this.accountId : accountId as String?,
        categoryId: categoryId == _k ? this.categoryId : categoryId as String?,
        reviewOnly: reviewOnly ?? this.reviewOnly,
      );
  static const _k = Object();
}

class TransactionsScreen extends ConsumerStatefulWidget {
  final bool reviewOnly;
  final String? accountId;
  const TransactionsScreen({super.key, this.reviewOnly = false, this.accountId});
  @override
  ConsumerState<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends ConsumerState<TransactionsScreen> {
  late TxFilter filter = TxFilter(reviewOnly: widget.reviewOnly, accountId: widget.accountId);
  int limit = 60;
  final selected = <String>{};
  final scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    scroll.addListener(() {
      if (scroll.position.pixels > scroll.position.maxScrollExtent - 600) setState(() => limit += 60);
    });
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = context.fp;
    final store = ref.watch(storeProvider);
    final fmt = ref.watch(settingsProvider).fmt;
    final cats = ref.watch(categoryMapProvider);
    final accounts = ref.watch(allAccountsProvider).value ?? const <AccountRow>[];
    final acctMap = {for (final a in accounts) a.id: a};
    final stream = store.watchTransactions(
      limit: limit,
      search: filter.search,
      accountId: filter.accountId,
      categoryId: filter.categoryId,
      needsReview: filter.reviewOnly ? true : null,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(selected.isNotEmpty ? s.nSelected(selected.length) : (widget.reviewOnly ? s.reviewInbox : s.transactions)),
        leading: selected.isNotEmpty ? IconButton(icon: const Icon(Icons.close), tooltip: s.cancel, onPressed: () => setState(selected.clear)) : null,
        actions: [
          if (selected.isNotEmpty) ...[
            IconButton(icon: const Icon(Icons.category_outlined), tooltip: s.changeCategory, onPressed: () => _bulkCategory(context)),
            IconButton(icon: const Icon(Icons.delete_outline), tooltip: s.delete, onPressed: () => _bulkDelete(context)),
          ] else
            IconButton(icon: const Icon(Icons.add), tooltip: s.add, onPressed: () => showAddTransactionSheet(context, ref)),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              decoration: InputDecoration(hintText: s.searchHint, prefixIcon: const Icon(Icons.search)),
              onChanged: (v) => setState(() => filter = filter.copyWith(search: v)),
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                FilterChip(
                  label: Text(s.needsReview),
                  selected: filter.reviewOnly,
                  onSelected: (v) => setState(() => filter = filter.copyWith(reviewOnly: v)),
                ),
                const SizedBox(width: 8),
                _MenuChip(
                  label: filter.accountId == null ? s.account : (acctMap[filter.accountId]?.name ?? s.account),
                  active: filter.accountId != null,
                  options: [(null, s.allAccounts), for (final a in accounts) (a.id, a.name)],
                  onSelected: (v) => setState(() => filter = filter.copyWith(accountId: v)),
                ),
                const SizedBox(width: 8),
                _MenuChip(
                  label: filter.categoryId == null ? s.category : (s.ar ? cats[filter.categoryId]?.nameAr : cats[filter.categoryId]?.nameEn) ?? s.category,
                  active: filter.categoryId != null,
                  options: [(null, s.ar ? 'كل الفئات' : 'All categories'), for (final c in cats.values) (c.id, '${c.icon} ${s.ar ? c.nameAr : c.nameEn}')],
                  onSelected: (v) => setState(() => filter = filter.copyWith(categoryId: v)),
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<TxRow>>(
              stream: stream,
              builder: (context, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final rows = snap.data!;
                if (rows.isEmpty) {
                  return ListView(children: [
                    widget.reviewOnly || filter.reviewOnly
                        ? EmptyState(emoji: '✅', title: s.reviewEmpty)
                        : EmptyState(emoji: '🧾', title: s.noTransactions, body: s.noTransactionsBody),
                  ]);
                }
                final items = <Widget>[];
                String? lastDay;
                for (final t in rows) {
                  final w = ReportingZone.kuwait.toWall(t.occurredAt);
                  final day = fmt.dayMonthYear(w);
                  if (day != lastDay) {
                    lastDay = day;
                    items.add(Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
                      child: Semantics(header: true, child: Text('${fmt.weekdayShort(w)} · $day', style: context.tt.labelMedium?.copyWith(color: p.inkSecondary))),
                    ));
                  }
                  items.add(Padding(
                    padding: const EdgeInsets.symmetric(horizontal: FilsSpace.gutter),
                    child: Container(
                      decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(FilsRadius.md)),
                      margin: const EdgeInsets.only(bottom: 6),
                      clipBehavior: Clip.antiAlias,
                      child: TxTile(
                        t: t,
                        cats: cats,
                        accounts: acctMap,
                        fmt: fmt,
                        selected: selected.contains(t.id),
                        onTap: () => selected.isNotEmpty ? setState(() => selected.contains(t.id) ? selected.remove(t.id) : selected.add(t.id)) : context.push('/transactions/${t.id}'),
                        onLongPress: () => setState(() => selected.add(t.id)),
                      ),
                    ),
                  ));
                }
                items.add(const SizedBox(height: 40));
                return ListView(controller: scroll, children: items);
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _bulkCategory(BuildContext context) async {
    final s = S.of(context);
    final cats = (ref.read(categoriesProvider).value ?? const <CategoryRow>[]).where((c) => c.kind == 'expense').toList();
    final picked = await showFSheet<String>(
      context,
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(s.changeCategory, style: context.tt.titleMedium),
          const SizedBox(height: 12),
          CategoryGrid(categories: cats, selected: null, onSelected: (id) => Navigator.pop(context, id)),
        ]),
      ),
    );
    if (picked == null) return;
    final store = ref.read(storeProvider);
    final ids = [...selected];
    final before = <String, String?>{};
    for (final id in ids) {
      before[id] = (await store.transaction(id))?.categoryId;
      await store.setCategory(id, picked);
    }
    setState(selected.clear);
    if (context.mounted) {
      showUndoSnack(context, s.saved, s.undo, () async {
        for (final e in before.entries) {
          if (e.value != null) await store.setCategory(e.key, e.value!);
        }
      });
    }
  }

  Future<void> _bulkDelete(BuildContext context) async {
    final s = S.of(context);
    final store = ref.read(storeProvider);
    final ids = [...selected];
    for (final id in ids) {
      await store.deleteTransaction(id);
    }
    setState(selected.clear);
    if (context.mounted) {
      showUndoSnack(context, s.deleted, s.undo, () async {
        for (final id in ids) {
          await store.restoreTransaction(id);
        }
      });
    }
  }
}

class _MenuChip extends StatelessWidget {
  final String label;
  final bool active;
  final List<(String?, String)> options;
  final ValueChanged<String?> onSelected;
  const _MenuChip({required this.label, required this.active, required this.options, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String?>(
      itemBuilder: (_) => [for (final o in options) PopupMenuItem(value: o.$1 ?? '__all__', child: Text(o.$2))],
      onSelected: (v) => onSelected(v == '__all__' ? null : v),
      child: Chip(
        label: Text(label),
        avatar: const Icon(Icons.arrow_drop_down, size: 18),
        backgroundColor: active ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12) : null,
      ),
    );
  }
}
