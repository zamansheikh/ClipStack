import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../storage.dart';
import '../sync_controller.dart';
import 'clip_grid.dart';
import 'my_code_screen.dart';
import 'pair_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final SyncController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  StreamSubscription<String>? _messages;
  StreamSubscription<String>? _navigation;
  bool _settingsOpen = false;
  ClipFilter _filter = ClipFilter.all;
  bool _sending = false;

  SyncController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _navigation = controller.navigation.listen((screen) {
      if (screen == 'settings' && mounted && !_settingsOpen) _openSettings();
    });
    _messages = controller.messages.listen((message) {
      if (mounted) showToast(context, message, icon: Icons.info_outline_rounded, iconColor: Brand.blue);
    });
  }

  @override
  void dispose() {
    _messages?.cancel();
    _navigation?.cancel();
    super.dispose();
  }

  Future<void> _sendClipboard() async {
    tick();
    setState(() => _sending = true);
    final result = await controller.sendClipboard();
    if (!mounted) return;
    setState(() => _sending = false);
    final ok = result.startsWith('Sent');
    showToast(context, result,
        icon: ok ? Icons.check_circle_rounded : Icons.error_outline_rounded, iconColor: ok ? Brand.success : Brand.warning);
  }

  Future<void> _openPairing() async {
    final peer = await Navigator.of(context).push<PairedPeer>(
      MaterialPageRoute(builder: (_) => PairScreen(controller: controller), fullscreenDialog: true),
    );
    if (peer != null && mounted) showToast(context, 'Paired with ${peer.device.name}');
  }

  Future<void> _openMyCode() async {
    final peer = await Navigator.of(context).push<PairedPeer>(
      MaterialPageRoute(builder: (_) => MyCodeScreen(controller: controller)),
    );
    if (peer != null && mounted) showToast(context, 'Paired with ${peer.device.name}');
  }

  Future<void> _openSettings() async {
    _settingsOpen = true;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SettingsScreen(controller: controller, onPair: _openPairing)),
    );
    _settingsOpen = false;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.ready) {
          return const Scaffold(body: Center(child: BrandMark(size: 72)));
        }
        final paired = controller.peers.isNotEmpty;
        final items = controller.history.where(_filter.matches).toList();
        return Scaffold(
          body: CustomScrollView(slivers: [
            SliverSafeArea(
              bottom: false,
              sliver: SliverToBoxAdapter(child: _Header(controller: controller, onSettings: _openSettings)),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: paired
                    ? _ConnectionCard(controller: controller, sending: _sending, onSend: _sendClipboard)
                    : _WelcomeCard(onPair: _openPairing, onShowCode: _openMyCode),
              ),
            ),
            if (!paired) const SliverToBoxAdapter(child: _HowItWorks()),
            if (paired) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
                  child: Row(children: [
                    Text('Clipboard', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(width: 8),
                    if (controller.history.isNotEmpty)
                      Text('${controller.history.length}',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(color: context.mutedText)),
                  ]),
                ),
              ),
              SliverToBoxAdapter(child: _FilterBar(selected: _filter, onSelect: (f) => setState(() => _filter = f))),
              const SliverToBoxAdapter(child: SizedBox(height: 14)),
              SliverToBoxAdapter(
                child: items.isEmpty
                    ? _EmptyClips(filter: _filter, hasAny: controller.history.isNotEmpty)
                    : ClipGrid(items: items, controller: controller),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
            const SliverSafeArea(top: false, sliver: SliverToBoxAdapter(child: SizedBox.shrink())),
          ]),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller, required this.onSettings});

  final SyncController controller;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
      child: Row(children: [
        const BrandMark(size: 38),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('ClipStack', style: Theme.of(context).textTheme.titleLarge),
            Text(controller.phoneName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.mutedText)),
          ]),
        ),
        IconButton.filledTonal(
          tooltip: 'Settings',
          onPressed: onSettings,
          icon: const Icon(Icons.tune_rounded),
        ),
      ]),
    );
  }
}

/// Paired: which computer, live status, and the Send button.
class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.controller, required this.sending, required this.onSend});

  final SyncController controller;
  final bool sending;
  final VoidCallback onSend;

  /// Laptop for computers, phone for phones, both when it's a mix.
  IconData _cardIcon() {
    final relevant = controller.state == LinkState.connected
        ? controller.peers.where(controller.isConnected)
        : controller.peers;
    final computers = relevant.where(controller.isComputer).length;
    if (computers == relevant.length) return Icons.laptop_mac_rounded;
    return computers == 0 ? Icons.smartphone_rounded : Icons.devices_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final connected = controller.state == LinkState.connected;
    final names = connected ? controller.connectedNames : controller.peers.map((p) => p.device.name).join(', ');
    final text = Theme.of(context).textTheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: connected ? context.heroGradient : null,
        color: connected ? null : context.cardColor,
        border: connected ? context.heroBorder : Border.all(color: context.cardBorder),
        boxShadow: connected ? context.heroShadow : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        if (connected)
          Positioned(
            right: -26,
            bottom: -44,
            child: Icon(Icons.copy_all_rounded, size: 150, color: Colors.white.withValues(alpha: context.isDark ? 0.04 : 0.07)),
          ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(15),
                  color: connected
                      ? Colors.white.withValues(alpha: context.isDark ? 0.1 : 0.2)
                      : Brand.warning.withValues(alpha: 0.14),
                ),
                child: Icon(_cardIcon(), color: connected ? Colors.white : Brand.warning),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(names,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleMedium?.copyWith(color: connected ? Colors.white : null)),
                  const SizedBox(height: 2),
                  Row(children: [
                    PulseDot(color: connected ? const Color(0xFF7CFFB2) : Brand.warning, size: 7),
                    Text(
                      connected ? 'Connected · end-to-end encrypted' : 'Looking for your devices…',
                      style: text.bodySmall?.copyWith(
                        color: connected ? Colors.white.withValues(alpha: 0.85) : context.mutedText,
                      ),
                    ),
                  ]),
                ]),
              ),
            ]),
            if (!connected) ...[
              const SizedBox(height: 12),
              Text(
                'Keep both on the same Wi-Fi. On a Mac, sharing must be on in ClipStack → Settings → Devices.',
                style: text.bodySmall?.copyWith(color: context.mutedText, height: 1.4),
              ),
            ],
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  style: connected
                      ? FilledButton.styleFrom(
                          backgroundColor: context.heroButton,
                          foregroundColor: context.heroButtonText,
                        )
                      : null,
                  onPressed: sending ? null : onSend,
                  icon: sending
                      ? SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: connected ? context.heroButtonText : null,
                          ),
                        )
                      : const Icon(Icons.north_east_rounded, size: 20),
                  label: const Text('Send clipboard'),
                ),
              ),
              if (!connected) ...[
                const SizedBox(width: 10),
                IconButton.filledTonal(
                  tooltip: 'Try again now',
                  onPressed: () {
                    tick();
                    controller.retryNow();
                  },
                  style: IconButton.styleFrom(minimumSize: const Size(52, 52)),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ]),
          ]),
        ),
      ]),
    );
  }
}

/// Not paired yet: what ClipStack does and the one button to start.
class _WelcomeCard extends StatelessWidget {
  const _WelcomeCard({required this.onPair, required this.onShowCode});

  final VoidCallback onPair;
  final VoidCallback onShowCode;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: context.heroGradient,
        border: context.heroBorder,
        boxShadow: context.heroShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        Positioned(
          right: -36,
          bottom: -30,
          child: Icon(Icons.copy_all_rounded, size: 190, color: Colors.white.withValues(alpha: context.isDark ? 0.04 : 0.08)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: context.isDark ? 0.1 : 0.18),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(Icons.devices_rounded, color: Colors.white, size: 30),
            ),
            const SizedBox(height: 18),
            Text('Your clipboard,\non every device',
                style: text.headlineSmall?.copyWith(color: Colors.white, height: 1.15)),
            const SizedBox(height: 10),
            Text(
              'Copy on your Mac, paste on your phone — and back. Clips travel over your Wi-Fi, end-to-end encrypted. No account, no cloud.',
              style: text.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.88), height: 1.45),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: context.heroButton,
                foregroundColor: context.heroButtonText,
                minimumSize: const Size.fromHeight(54),
              ),
              onPressed: onPair,
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: const Text('Pair with your computer'),
            ),
            const SizedBox(height: 6),
            Center(
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                onPressed: onShowCode,
                icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                label: const Text('Pairing two phones? Show my code'),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    Widget step(int n, String title, String detail) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, color: Brand.violet.withValues(alpha: 0.15)),
              child: Text('$n',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(detail, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.mutedText, height: 1.4)),
              ]),
            ),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('How it works', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 16),
        step(1, 'Open ClipStack on your Mac', 'Settings → Devices → Pair a Device shows a QR code. '
            'Pairing two phones? One shows its code, the other scans it.'),
        step(2, 'Scan it with this phone', 'Tap Pair with your computer and point the camera at the code.'),
        step(3, 'Copy anywhere', 'Mac copies land on this phone automatically. To send from the phone, tap Send clipboard or use Share → ClipStack.'),
      ]),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.selected, required this.onSelect});

  final ClipFilter selected;
  final ValueChanged<ClipFilter> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: ClipFilter.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final filter = ClipFilter.values[i];
          final active = filter == selected;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: active ? context.heroGradient : null,
              color: active ? null : context.cardColor,
              border: active ? null : Border.all(color: context.cardBorder),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                tick();
                onSelect(filter);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(children: [
                  Icon(filter.icon, size: 16, color: active ? Colors.white : scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text(filter.label,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: active ? Colors.white : scheme.onSurface,
                            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                          )),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EmptyClips extends StatelessWidget {
  const _EmptyClips({required this.filter, required this.hasAny});

  final ClipFilter filter;
  final bool hasAny;

  @override
  Widget build(BuildContext context) {
    final title = hasAny ? 'No ${filter.label.toLowerCase()} yet' : 'Nothing copied yet';
    final detail = hasAny
        ? 'Try another filter.'
        : 'Copy something on a paired device — it shows up here and on this phone\'s clipboard.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 36, 32, 0),
      child: Column(children: [
        IconTile(icon: hasAny ? filter.icon : Icons.content_paste_rounded, size: 64),
        const SizedBox(height: 16),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(detail,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.mutedText, height: 1.4)),
      ]),
    );
  }
}
