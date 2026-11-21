import 'package:material_ui/material_ui.dart';

import '../storage.dart';
import '../sync_controller.dart';
import 'my_code_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller, required this.onPair});

  final SyncController controller;
  final Future<void> Function() onPair;

  Future<void> _remove(BuildContext context, PairedPeer peer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Remove ${peer.device.name}?'),
        content: const Text('Clips will stop syncing with this device. You can pair it again any time.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('Cancel')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(dialog).colorScheme.error),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.unpair(peer);
    if (context.mounted) showToast(context, 'Removed ${peer.device.name}');
  }

  Future<void> _clearHistory(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Clear history on this phone?'),
        content: const Text('Your computers keep their own history.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('Cancel')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(dialog).colorScheme.error),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.clearHistory();
    if (context.mounted) showToast(context, 'History cleared');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 32),
          children: [
            SettingsGroup(
              title: 'This phone',
              footer: 'Other devices see this phone by this name.',
              children: [
                ListTile(
                  leading: const IconTile(icon: Icons.smartphone_rounded, gradient: true),
                  title: Text(controller.phoneName),
                  subtitle: const Text('Android'),
                ),
              ],
            ),
            SettingsGroup(
              title: 'Devices',
              footer: 'Pair your Mac, or phones with each other. Clips go to every paired device that is connected.',
              children: [
                for (final peer in controller.peers)
                  ListTile(
                    leading: IconTile(icon: deviceIcon(peer.device.platform)),
                    title: Text(peer.device.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Row(children: [
                      PulseDot(
                        color: controller.isConnected(peer) ? Brand.success : Brand.warning,
                        pulsing: controller.isConnected(peer),
                        size: 6,
                      ),
                      Text(controller.isConnected(peer) ? 'Connected' : 'Not reachable right now'),
                    ]),
                    trailing: TextButton(
                      style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                      onPressed: () => _remove(context, peer),
                      child: const Text('Remove'),
                    ),
                  ),
                ListTile(
                  leading: const IconTile(icon: Icons.qr_code_scanner_rounded),
                  title: const Text('Scan a pairing code'),
                  subtitle: const Text('From your Mac or another phone'),
                  trailing: Icon(Icons.chevron_right_rounded, color: context.mutedText),
                  onTap: onPair,
                ),
                ListTile(
                  leading: const IconTile(icon: Icons.qr_code_2_rounded),
                  title: const Text('Show my pairing code'),
                  subtitle: const Text('Let another phone scan this one'),
                  trailing: Icon(Icons.chevron_right_rounded, color: context.mutedText),
                  onTap: () async {
                    final peer = await Navigator.of(context).push<PairedPeer>(
                      MaterialPageRoute(builder: (_) => MyCodeScreen(controller: controller)),
                    );
                    if (peer != null && context.mounted) showToast(context, 'Paired with ${peer.device.name}');
                  },
                ),
              ],
            ),
            SettingsGroup(
              title: 'Sending',
              footer: 'Android only lets apps read the clipboard while they are open, so phone copies '
                  'need one tap: the bubble, the Quick Settings tile, the "Send clipboard" button on '
                  'the ClipStack notification, or Share. Copies from your computer arrive on their own.',
              children: [
                SwitchListTile(
                  secondary: const IconTile(icon: Icons.bubble_chart_rounded, gradient: true),
                  title: const Text('Floating bubble'),
                  subtitle: const Text('Tap it to send or paste from any app. Drag it onto the ✕ to hide it.'),
                  value: controller.bubbleEnabled,
                  onChanged: (value) {
                    tick();
                    controller.setBubbleEnabled(value);
                  },
                ),
                ListTile(
                  leading: const IconTile(icon: Icons.content_paste_go_rounded),
                  title: const Text('One-tap paste'),
                  subtitle: Text(controller.pasteServiceEnabled
                      ? 'On: the bubble\'s Paste pastes into the field you\'re typing in'
                      : 'Lets the bubble\'s Paste type into any app. Turn on "ClipStack paste" in Accessibility.'),
                  trailing: controller.pasteServiceEnabled
                      ? const Icon(Icons.check_circle_rounded, color: Brand.success)
                      : TextButton(onPressed: controller.openPasteServiceSettings, child: const Text('Turn on')),
                  onTap: controller.openPasteServiceSettings,
                ),
                const ListTile(
                  leading: IconTile(icon: Icons.dashboard_customize_outlined),
                  title: Text('Quick Settings tile'),
                  subtitle: Text('Edit your Quick Settings and add "Send clipboard"'),
                ),
                SwitchListTile(
                  secondary: const IconTile(icon: Icons.bolt_rounded),
                  title: const Text('Send when I open ClipStack'),
                  subtitle: const Text('Opening the app sends a new copy'),
                  value: controller.autoSendOnOpen,
                  onChanged: (value) {
                    tick();
                    controller.setAutoSendOnOpen(value);
                  },
                ),
                const ListTile(
                  leading: IconTile(icon: Icons.ios_share_rounded),
                  title: Text('Share from any app'),
                  subtitle: Text('Share → ClipStack sends text or an image'),
                ),
              ],
            ),
            SettingsGroup(
              title: 'History',
              children: [
                ListTile(
                  leading: IconTile(icon: Icons.delete_sweep_outlined, color: Theme.of(context).colorScheme.error),
                  title: const Text('Clear history on this phone'),
                  subtitle: Text('${controller.history.length} clips'),
                  enabled: controller.history.isNotEmpty,
                  onTap: () => _clearHistory(context),
                ),
              ],
            ),
            const SettingsGroup(
              title: 'Privacy',
              children: [
                ListTile(
                  leading: IconTile(icon: Icons.lock_outline_rounded),
                  title: Text('End-to-end encrypted'),
                  subtitle: Text('Clips go straight between your devices on your Wi-Fi. Nothing is uploaded.'),
                ),
              ],
            ),
            Center(
              child: Column(children: [
                const BrandMark(size: 44),
                const SizedBox(height: 8),
                Text('ClipStack ${SyncController.appVersion}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.mutedText)),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}
