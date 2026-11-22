import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../theme/tokens.dart';

/// White rounded card used across screens.
class FCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  final double radius;
  const FCard({super.key, required this.child, this.padding = const EdgeInsets.all(FilsSpace.lg), this.onTap, this.color, this.radius = FilsRadius.lg});

  @override
  Widget build(BuildContext context) {
    final p = context.fp;
    final body = Padding(padding: padding, child: child);
    return Container(
      decoration: BoxDecoration(
        color: color ?? p.surface,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: Theme.of(context).brightness == Brightness.light ? FilsShadow.card : null,
        border: Theme.of(context).brightness == Brightness.dark ? Border.all(color: p.border) : null,
      ),
      child: onTap == null
          ? body
          : Material(
              color: Colors.transparent,
              child: InkWell(borderRadius: BorderRadius.circular(radius), onTap: onTap, child: body),
            ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  const SectionHeader(this.title, {super.key, this.action, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(FilsSpace.gutter, FilsSpace.xxl, FilsSpace.sm, FilsSpace.sm),
      child: Row(
        children: [
          Expanded(child: Semantics(header: true, child: Text(title, style: context.tt.titleLarge))),
          if (action != null)
            TextButton(
              onPressed: onAction,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(action!),
                Icon(context.isRtl ? Icons.chevron_left : Icons.chevron_right, size: 20),
              ]),
            ),
        ],
      ),
    );
  }
}

/// Emoji-in-tinted-tile category icon (reference style: soft pastel square).
class CategoryTile extends StatelessWidget {
  final String emoji;
  final Color color;
  final double size;
  const CategoryTile({super.key, required this.emoji, required this.color, this.size = 48});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: dark ? 0.22 : 0.13),
          borderRadius: BorderRadius.circular(size * 0.3),
        ),
        child: Text(emoji, style: TextStyle(fontSize: size * 0.48, fontFamilyFallback: const ['Apple Color Emoji', 'Noto Color Emoji'])),
      ),
    );
  }
}

/// Bank badge: our own neutral monogram on the bank's color. Not an official logo.
class BankBadge extends StatelessWidget {
  final String code;
  final Color color;
  final double size;
  const BankBadge({super.key, required this.code, required this.color, this.size = 36});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(size * 0.28)),
          child: Text(code, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * (code.length > 2 ? 0.3 : 0.38))),
        ),
      );
}

class EmptyState extends StatelessWidget {
  final String emoji;
  final String title;
  final String? body;
  final String? action;
  final VoidCallback? onAction;
  const EmptyState({super.key, required this.emoji, required this.title, this.body, this.action, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: FilsSpace.xxl, vertical: FilsSpace.xxxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(child: Text(emoji, style: const TextStyle(fontSize: 44))),
          const SizedBox(height: FilsSpace.md),
          Text(title, style: context.tt.titleMedium, textAlign: TextAlign.center),
          if (body != null) ...[
            const SizedBox(height: FilsSpace.xs),
            Text(body!, style: context.tt.bodyMedium?.copyWith(color: context.fp.inkSecondary), textAlign: TextAlign.center),
          ],
          if (action != null) ...[
            const SizedBox(height: FilsSpace.lg),
            FilledButton(onPressed: onAction, child: Text(action!)),
          ],
        ],
      ),
    );
  }
}

/// Round translucent action button with a label (Add / Voice / Import / More).
class CircleAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool onHero;
  final String? badge;
  const CircleAction({super.key, required this.icon, required this.label, this.onTap, this.onHero = true, this.badge});

  @override
  Widget build(BuildContext context) {
    final fg = onHero ? Colors.white : context.fp.ink;
    final bg = onHero ? Colors.white.withValues(alpha: 0.22) : context.fp.surfaceMuted;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 76,
          child: Column(
            children: [
              Stack(clipBehavior: Clip.none, children: [
                Container(
                  width: 62,
                  height: 62,
                  decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
                  child: Icon(icon, color: fg, size: 28),
                ),
                if (badge != null)
                  PositionedDirectional(
                    top: -6,
                    end: -6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(color: context.fp.negative, borderRadius: BorderRadius.circular(10)),
                      child: Text(badge!, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                    ),
                  ),
              ]),
              const SizedBox(height: 8),
              ExcludeSemantics(child: Text(label, style: context.tt.labelMedium?.copyWith(color: fg), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  final String text;
  final Color? bg;
  final Color? fg;
  final IconData? icon;
  const Pill(this.text, {super.key, this.bg, this.fg, this.icon});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: bg ?? context.fp.surfaceMuted, borderRadius: BorderRadius.circular(FilsRadius.pill)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 12, color: fg ?? context.fp.inkSecondary), const SizedBox(width: 3)],
          Text(text, style: context.tt.labelSmall?.copyWith(color: fg ?? context.fp.inkSecondary, letterSpacing: 0.2)),
        ]),
      );
}

/// Linear progress used by budgets and goals. Turns warning/negative past thresholds.
class FProgress extends StatelessWidget {
  final double value; // may exceed 1
  final Color? color;
  final double height;
  const FProgress({super.key, required this.value, this.color, this.height = 8});

  @override
  Widget build(BuildContext context) {
    final p = context.fp;
    final c = color ?? (value >= 1 ? p.negative : (value >= 0.8 ? p.warning : Theme.of(context).colorScheme.primary));
    return Semantics(
      value: '${(value * 100).round()}%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: LinearProgressIndicator(value: value.clamp(0, 1).toDouble(), minHeight: height, color: c, backgroundColor: p.surfaceMuted),
      ),
    );
  }
}

class NavItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const NavItem(this.icon, this.selectedIcon, this.label);
}

/// Floating frosted bottom navigation (reference: rounded glass bar with a highlighted
/// pill behind the selected tab).
class GlassNavBar extends StatelessWidget {
  final List<NavItem> items;
  final int index;
  final ValueChanged<int> onTap;
  const GlassNavBar({super.key, required this.items, required this.index, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = context.fp;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(FilsRadius.pill),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            height: 70,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: (dark ? p.surface : Colors.white).withValues(alpha: dark ? 0.85 : 0.82),
              borderRadius: BorderRadius.circular(FilsRadius.pill),
              border: Border.all(color: p.border.withValues(alpha: 0.7)),
              boxShadow: FilsShadow.floating,
            ),
            child: Row(
              children: [
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    child: Semantics(
                      selected: i == index,
                      button: true,
                      label: items[i].label,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onTap(i),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          decoration: BoxDecoration(
                            color: i == index ? p.surfaceMuted : Colors.transparent,
                            borderRadius: BorderRadius.circular(FilsRadius.pill),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(i == index ? items[i].selectedIcon : items[i].icon,
                                  color: i == index ? Theme.of(context).colorScheme.primary : p.ink, size: 25),
                              const SizedBox(height: 2),
                              ExcludeSemantics(
                                child: Text(items[i].label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: context.tt.labelSmall?.copyWith(
                                        letterSpacing: 0,
                                        fontSize: 12,
                                        color: i == index ? Theme.of(context).colorScheme.primary : p.ink)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// iOS-style segmented control (Net worth / Assets / Debt; 1M / 3M / 1Y / All).
class Segmented<T> extends StatelessWidget {
  final List<(T, String)> items;
  final T value;
  final ValueChanged<T> onChanged;
  const Segmented({super.key, required this.items, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = context.fp;
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: p.surfaceMuted, borderRadius: BorderRadius.circular(FilsRadius.pill)),
      child: Row(children: [
        for (final it in items)
          Expanded(
            child: Semantics(
              selected: it.$1 == value,
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(it.$1),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: it.$1 == value ? p.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(FilsRadius.pill),
                    boxShadow: it.$1 == value && Theme.of(context).brightness == Brightness.light ? FilsShadow.card : null,
                  ),
                  child: Text(it.$2, style: context.tt.labelLarge?.copyWith(fontWeight: it.$1 == value ? FontWeight.w600 : FontWeight.w500)),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

Future<T?> showFSheet<T>(BuildContext context, Widget child, {bool scroll = true}) => showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: scroll ? SingleChildScrollView(child: child) : child,
      ),
    );

void showUndoSnack(BuildContext context, String message, String undoLabel, VoidCallback onUndo) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), action: SnackBarAction(label: undoLabel, onPressed: onUndo), duration: const Duration(seconds: 5)));
}
