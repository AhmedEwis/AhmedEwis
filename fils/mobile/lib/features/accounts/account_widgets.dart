import 'package:material_ui/material_ui.dart';

import '../../core/parsing/bank_registry.dart';
import '../../data/db/database.dart';
import '../../ui/theme/theme.dart';
import '../../ui/theme/tokens.dart';
import '../../ui/widgets/common.dart';

Widget accountBadge(AccountRow a, {double size = 36}) {
  final bank = bankById(a.institutionId);
  if (bank != null) return BankBadge(code: bank.shortCode, color: Color(bank.brandColor), size: size);
  final emoji = switch (a.kind) {
    'cash' => '💵',
    'card' => '💳',
    'savings' => '🏦',
    'wallet' => '📱',
    'loan' => '📄',
    _ => '🏛️',
  };
  return CategoryTile(emoji: emoji, color: Color(a.color ?? 0xFF0B7A8F), size: size);
}

class AccountMiniCard extends StatelessWidget {
  final String title;
  final String amount;
  final Widget leading;
  final bool emphasized;
  final VoidCallback? onTap;
  const AccountMiniCard({super.key, required this.title, required this.amount, required this.leading, this.emphasized = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 12, bottom: 8, top: 2),
      child: SizedBox(
        width: 232,
        child: FCard(
          onTap: onTap,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          color: emphasized ? null : context.fp.surface.withValues(alpha: Theme.of(context).brightness == Brightness.light ? 0.75 : 1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(children: [
                leading,
                const SizedBox(width: 10),
                Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleSmall?.copyWith(color: emphasized ? null : context.fp.inkSecondary))),
                if (emphasized) Icon(context.isRtl ? Icons.chevron_left : Icons.chevron_right, size: 18, color: Theme.of(context).colorScheme.primary),
              ]),
              if (amount.isNotEmpty)
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Directionality(textDirection: TextDirection.ltr, child: Text(amount, style: context.tt.titleLarge?.copyWith(fontWeight: FontWeight.w700))),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

const accountKinds = ['bank', 'card', 'cash', 'savings', 'wallet', 'loan'];

double get kCardRadius => FilsRadius.lg;
