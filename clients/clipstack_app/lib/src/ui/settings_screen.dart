import 'package:material_ui/material_ui.dart';

import '../storage.dart';
import '../sync_controller.dart';
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
        content: const Text('Clips will stop syncing with this computer. You can pair it again any time.'),
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
              footer: 'Your computers see this phone by this name.',
              children: [
                ListTile(
                  leading: const IconTile(icon: Icons.smartphone_rounded, gradient: true),
                  title: Text(controller.phoneName),
                  subtitle: const Text('Android'),
                ),
              ],
            ),
            SettingsGroup(
              title: 'Computers',
              children: [
                for (final peer in controller.peers)
                  ListTile(
                    leading: const IconTile(icon: Icons.laptop_mac_rounded),
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
                  title: Text(controller.peers.isEmpty ? 'Pair a computer' : 'Pair another computer'),
                  trailing: Icon(Icons.chevron_right_rounded, color: context.mutedText),
                  onTap: onPair,
                ),
              ],
            ),
            SettingsGroup(
              title: 'Sending',
              footer: 'Android only lets apps read the clipboard while they are open, so phone copies '
                  'need one tap. Copies from your computer arrive on their own.',
              children: [
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
