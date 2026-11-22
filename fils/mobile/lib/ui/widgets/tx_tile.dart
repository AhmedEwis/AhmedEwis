import 'package:material_ui/material_ui.dart';

import '../../core/domain/categories.dart';
import '../../core/ledger/ledger.dart';
import '../../core/time/kuwait_time.dart';
import '../../data/db/database.dart';
import '../../l10n/strings.dart';
import '../format.dart';
import '../theme/theme.dart';
import 'common.dart';

class TxVisual {
  final String title;
  final String subtitle;
  final String emoji;
  final Color color;
  final String amountText;
  final Color? amountColor;
  final bool strike;
  final String? statusPill;
  const TxVisual(this.title, this.subtitle, this.emoji, this.color, this.amountText, this.amountColor, this.strike, this.statusPill);
}

TxVisual txVisual(BuildContext context, TxRow t, Map<String, CategoryRow> cats, Map<String, AccountRow> accounts, Fmt fmt) {
  final s = S.of(context);
  final p = context.fp;
  final cat = t.categoryId == null ? null : cats[t.categoryId];
  final catName = cat == null ? null : (s.ar ? cat.nameAr : cat.nameEn);
  String title;
  String emoji;
  Color color;
  switch (t.kind) {
    case TxKinds.transfer:
      final to = accounts[t.counterAccountId]?.name ?? '—';
      title = s.ar ? 'تحويل إلى $to' : 'Transfer to $to';
      emoji = to == 'Cash' || accounts[t.counterAccountId]?.kind == 'cash' ? '🏧' : '🔄';
      color = const Color(0xFF0891B2);
    case TxKinds.adjustUp:
    case TxKinds.adjustDown:
      title = s.adjustment;
      emoji = '⚖️';
      color = const Color(0xFF64748B);
    default:
      title = t.merchant ?? t.merchantRaw ?? catName ?? (t.kind == TxKinds.income ? s.incomeKind : s.expense);
      emoji = cat?.icon ?? categoryDef(t.categoryId)?.icon ?? (t.kind == TxKinds.income ? '💸' : '📦');
      color = Color(cat?.color ?? categoryDef(t.categoryId)?.color ?? 0xFF94A3B8);
  }
  final subtitle = switch (t.kind) {
    TxKinds.transfer => accounts[t.accountId]?.name ?? '',
    TxKinds.refund => '${s.refund}${catName != null ? ' · $catName' : ''}',
    _ => catName ?? '',
  };
  final positive = t.kind == TxKinds.income || t.kind == TxKinds.refund || t.kind == TxKinds.adjustUp;
  final neutral = t.kind == TxKinds.transfer;
  final amountText = fmt.money(positive ? t.amountMinor : t.amountMinor, t.currency, signed: positive);
  final strike = t.status == TxStatuses.declined || t.status == TxStatuses.voided;
  final pill = switch (t.status) {
    TxStatuses.pending => s.pending,
    TxStatuses.declined => s.declined,
    TxStatuses.voided => s.voided,
    _ => t.needsReview ? s.needsReview : null,
  };
  return TxVisual(title, subtitle, emoji, color, amountText, positive ? p.positive : (neutral ? p.inkSecondary : null), strike, pill);
}

class TxTile extends StatelessWidget {
  final TxRow t;
  final Map<String, CategoryRow> cats;
  final Map<String, AccountRow> accounts;
  final Fmt fmt;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  const TxTile({super.key, required this.t, required this.cats, required this.accounts, required this.fmt, this.onTap, this.onLongPress, this.selected = false});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = context.fp;
    final v = txVisual(context, t, cats, accounts, fmt);
    final wall = ReportingZone.kuwait.toWall(t.occurredAt);
    final nowWall = ReportingZone.kuwait.toWall(DateTime.now().toUtc());
    final sameDay = wall.year == nowWall.year && wall.month == nowWall.month && wall.day == nowWall.day;
    final yest = nowWall.subtract(const Duration(days: 1));
    final isYest = wall.year == yest.year && wall.month == yest.month && wall.day == yest.day;
    final when = '${sameDay ? s.today : (isYest ? s.yesterday : fmt.dayMonth(wall))}, ${fmt.time(wall)}';
    final acct = accounts[t.kind == TxKinds.transfer ? t.counterAccountId : t.accountId];
    return Semantics(
      button: onTap != null,
      selected: selected,
      label: '${v.title}, ${v.amountText}, ${v.subtitle}, $when${v.statusPill != null ? ', ${v.statusPill}' : ''}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          color: selected ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08) : null,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              selected
                  ? Container(width: 48, height: 48, alignment: Alignment.center, child: Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary, size: 30))
                  : CategoryTile(emoji: v.emoji, color: v.color),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleMedium),
                    const SizedBox(height: 2),
                    Row(children: [
                      Flexible(child: Text(v.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodyMedium?.copyWith(color: p.inkSecondary))),
                      if (v.statusPill != null) ...[const SizedBox(width: 6), Pill(v.statusPill!, bg: t.needsReview ? p.warningBg : null, fg: t.needsReview ? p.warning : null)],
                    ]),
                    if (acct != null) ...[
                      const SizedBox(height: 2),
                      Row(children: [
                        Container(width: 7, height: 7, decoration: BoxDecoration(color: Color(acct.color ?? 0xFF0B7A8F), shape: BoxShape.circle)),
                        const SizedBox(width: 5),
                        Flexible(child: Text(acct.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall?.copyWith(color: p.inkSecondary, fontWeight: FontWeight.w500))),
                      ]),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(v.amountText,
                        style: context.tt.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: v.amountColor,
                          decoration: v.strike ? TextDecoration.lineThrough : null,
                        )),
                  ),
                  const SizedBox(height: 4),
                  Text(when, style: context.tt.bodySmall?.copyWith(color: p.inkSecondary)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
