import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// The app icon, used as the brand mark in headers.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
        'assets/brand/logo.png',
        width: size,
        height: size,
        filterQuality: FilterQuality.medium,
      );
}

/// A status dot that softly pulses while [pulsing] (connected / searching).
class PulseDot extends StatefulWidget {
  const PulseDot({super.key, required this.color, this.pulsing = true, this.size = 8});

  final Color color;
  final bool pulsing;
  final double size;

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void initState() {
    super.initState();
    if (widget.pulsing) _controller.repeat();
  }

  @override
  void didUpdateWidget(PulseDot old) {
    super.didUpdateWidget(old);
    if (widget.pulsing && !_controller.isAnimating) _controller.repeat();
    if (!widget.pulsing) _controller.stop();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s * 2.6,
      height: s * 2.6,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          return Stack(alignment: Alignment.center, children: [
            if (widget.pulsing)
              Container(
                width: s + s * 1.6 * t,
                height: s + s * 1.6 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: 0.35 * (1 - t)),
                ),
              ),
            Container(
              width: s,
              height: s,
              decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
            ),
          ]);
        },
      ),
    );
  }
}

/// A rounded, tinted square holding an icon (device rows, settings rows).
class IconTile extends StatelessWidget {
  const IconTile({super.key, required this.icon, this.color, this.size = 40, this.gradient = false});

  final IconData icon;
  final Color? color;
  final double size;
  final bool gradient;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        gradient: gradient ? Brand.gradient : null,
        color: gradient ? null : tint.withValues(alpha: context.isDark ? 0.18 : 0.12),
      ),
      child: Icon(icon, size: size * 0.52, color: gradient ? Colors.white : tint),
    );
  }
}

/// A grouped-list section: small heading, then rows on one rounded card.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.title, required this.children, this.footer});

  final String title;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(const Divider(indent: 72));
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: context.mutedText,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: context.cardColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: context.cardBorder),
          ),
          child: Column(children: rows),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(footer!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.mutedText)),
          ),
      ]),
    );
  }
}

/// Floating confirmation with an icon, e.g. "Copied to clipboard".
void showToast(BuildContext context, String message, {IconData icon = Icons.check_circle_rounded, Color? iconColor}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 1800),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      content: Row(children: [
        Icon(icon, color: iconColor ?? Brand.success, size: 20),
        const SizedBox(width: 12),
        Expanded(child: Text(message)),
      ]),
    ));
}

/// "just now", "4 min ago", "2 h ago", "3 d ago".
String timeAgo(DateTime at) {
  final d = DateTime.now().difference(at);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

/// Light haptic tick for taps that change something.
void tick() => HapticFeedback.lightImpact();
