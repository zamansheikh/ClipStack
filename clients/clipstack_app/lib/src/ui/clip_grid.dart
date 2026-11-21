import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../storage.dart';
import '../sync_controller.dart';
import 'theme.dart';
import 'widgets.dart';

enum ClipFilter {
  all('All', Icons.apps_rounded),
  text('Text', Icons.notes_rounded),
  links('Links', Icons.link_rounded),
  images('Images', Icons.image_outlined);

  const ClipFilter(this.label, this.icon);
  final String label;
  final IconData icon;

  bool matches(HistoryItem item) => switch (this) {
        ClipFilter.all => true,
        ClipFilter.text => item.kind == 'text' || item.kind == 'rtf',
        ClipFilter.links => item.kind == 'url',
        ClipFilter.images => item.kind == 'image',
      };
}

/// Two-column masonry of clips: each card goes into the shorter column, so
/// short texts, links and images pack without gaps.
class ClipGrid extends StatelessWidget {
  const ClipGrid({super.key, required this.items, required this.controller});

  final List<HistoryItem> items;
  final SyncController controller;

  static double _estimatedHeight(HistoryItem item) {
    switch (item.kind) {
      case 'image':
        return 220;
      case 'url':
        return 150;
      default:
        final text = item.text ?? '';
        final lines = (text.length / 22).ceil() + '\n'.allMatches(text).length;
        return 70 + 20.0 * lines.clamp(1, 8);
    }
  }

  @override
  Widget build(BuildContext context) {
    final left = <HistoryItem>[], right = <HistoryItem>[];
    var leftHeight = 0.0, rightHeight = 0.0;
    for (final item in items) {
      final h = _estimatedHeight(item);
      if (leftHeight <= rightHeight) {
        left.add(item);
        leftHeight += h;
      } else {
        right.add(item);
        rightHeight += h;
      }
    }
    Widget column(List<HistoryItem> list) => Expanded(
          child: Column(children: [
            for (final item in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: ClipCard(item: item, controller: controller),
              ),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        column(left),
        const SizedBox(width: 12),
        column(right),
      ]),
    );
  }
}

class ClipCard extends StatelessWidget {
  const ClipCard({super.key, required this.item, required this.controller});

  final HistoryItem item;
  final SyncController controller;

  Future<void> _copy(BuildContext context) async {
    tick();
    await controller.copyToClipboard(item);
    if (context.mounted) showToast(context, item.imagePath != null ? 'Image copied' : 'Copied to clipboard');
  }

  @override
  Widget build(BuildContext context) {
    final body = switch (item.kind) {
      'image' => _ImageBody(item: item),
      'url' => _LinkBody(item: item),
      _ => _TextBody(item: item),
    };
    return Material(
      color: context.cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: context.cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _copy(context),
        onLongPress: () => showClipDetails(context, item, controller),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          body,
          _Footer(item: item),
        ]),
      ),
    );
  }
}

class _TextBody extends StatelessWidget {
  const _TextBody({required this.item});
  final HistoryItem item;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
        child: Text(
          (item.text ?? '').trim(),
          maxLines: 8,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.4),
        ),
      );
}

class _LinkBody extends StatelessWidget {
  const _LinkBody({required this.item});
  final HistoryItem item;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse((item.text ?? '').trim());
    final host = (uri?.host ?? '').replaceFirst('www.', '');
    final rest = uri == null ? item.text ?? '' : '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const IconTile(icon: Icons.link_rounded, size: 34),
        const SizedBox(height: 10),
        Text(host.isEmpty ? 'Link' : host,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
        if (rest.isNotEmpty && rest != '/') ...[
          const SizedBox(height: 2),
          Text(rest,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.primary)),
        ],
      ]),
    );
  }
}

class _ImageBody extends StatelessWidget {
  const _ImageBody({required this.item});
  final HistoryItem item;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: Image.file(
            File(item.imagePath!),
            height: 160,
            fit: BoxFit.cover,
            cacheWidth: 600,
            errorBuilder: (_, _, _) => Container(
              height: 160,
              color: context.cardBorder,
              child: Icon(Icons.broken_image_outlined, color: context.mutedText),
            ),
          ),
        ),
      );
}

class _Footer extends StatelessWidget {
  const _Footer({required this.item});
  final HistoryItem item;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(color: context.mutedText);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      child: Row(children: [
        Icon(
          item.incoming ? deviceIcon(item.devicePlatform) : Icons.arrow_upward_rounded,
          size: 13,
          color: item.incoming ? Theme.of(context).colorScheme.primary : Brand.success,
        ),
        const SizedBox(width: 5),
        Expanded(
          child: Text(item.incoming ? shortDeviceName(item.deviceName) : 'Sent',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
        ),
        Text(timeAgo(item.at), style: style),
      ]),
    );
  }
}

/// "Zaman’s MacBook Air" → "MacBook Air": on your own phone the owner's name
/// is noise, and narrow cards need the room. Details show the full name.
String shortDeviceName(String name) {
  for (final separator in const ['’s ', "'s "]) {
    final i = name.indexOf(separator);
    if (i > 0 && i + separator.length < name.length) return name.substring(i + separator.length);
  }
  return name;
}

/// Long-press sheet: the full clip, where it came from, Copy and Delete.
Future<void> showClipDetails(BuildContext context, HistoryItem item, SyncController controller) {
  tick();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) {
      final text = Theme.of(sheet).textTheme;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                IconTile(icon: item.incoming ? deviceIcon(item.devicePlatform) : Icons.arrow_upward_rounded, size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(item.incoming ? 'From ${item.deviceName}' : 'Sent to ${item.deviceName}',
                        style: text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(timeAgo(item.at), style: text.bodySmall?.copyWith(color: sheet.mutedText)),
                  ]),
                ),
              ]),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: item.imagePath != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.file(File(item.imagePath!), fit: BoxFit.contain),
                        )
                      : Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: sheet.isDark ? Colors.white.withValues(alpha: 0.04) : const Color(0xFFF5F4FA),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: SelectableText(item.text ?? '', style: text.bodyMedium?.copyWith(height: 1.45)),
                        ),
                ),
              ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 52),
                      foregroundColor: Theme.of(sheet).colorScheme.error,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: () async {
                      Navigator.of(sheet).pop();
                      await controller.deleteHistoryItem(item);
                      if (context.mounted) showToast(context, 'Removed from history', icon: Icons.delete_outline_rounded, iconColor: Colors.white70);
                    },
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Delete'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: () async {
                      Navigator.of(sheet).pop();
                      await controller.copyToClipboard(item);
                      if (context.mounted) showToast(context, 'Copied to clipboard');
                    },
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('Copy'),
                  ),
                ),
              ]),
            ]),
          ),
        ),
      );
    },
  );
}
