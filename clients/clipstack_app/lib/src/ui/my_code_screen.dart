import 'dart:async';

import 'package:clipstack_sync/clipstack_sync.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../storage.dart';
import '../sync_controller.dart';
import 'theme.dart';

/// "Show my pairing code": this phone opens a pairing window and shows a QR
/// code for another phone to scan. Pops with the new PairedPeer on success.
class MyCodeScreen extends StatefulWidget {
  const MyCodeScreen({super.key, required this.controller});

  final SyncController controller;

  @override
  State<MyCodeScreen> createState() => _MyCodeScreenState();
}

class _MyCodeScreenState extends State<MyCodeScreen> {
  PairingLink? _link;
  String? _error;
  PairedPeer? _paired;
  Duration _left = SyncController.pairingCodeLifetime;
  Timer? _ticker;
  StreamSubscription<PairedPeer>? _pairedSub;

  SyncController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _pairedSub = controller.pairedByCode.listen(_onPaired);
    _open();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pairedSub?.cancel();
    if (_paired == null) controller.closePairingCode();
    super.dispose();
  }

  Future<void> _open() async {
    setState(() {
      _error = null;
      _link = null;
    });
    try {
      final link = await controller.openPairingCode();
      // Debug builds only: lets a test rig pair without a camera.
      if (kDebugMode) debugPrint('ClipStack: pairing link ${link.toUri()}');
      if (!mounted) return;
      setState(() => _link = link);
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      _tick();
    } on StateError catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  void _tick() {
    final left = controller.pairingCodeExpires.difference(DateTime.now());
    setState(() => _left = left.isNegative ? Duration.zero : left);
    if (left.isNegative) _ticker?.cancel();
  }

  Future<void> _onPaired(PairedPeer peer) async {
    HapticFeedback.heavyImpact();
    _ticker?.cancel();
    if (!mounted) return;
    setState(() => _paired = peer);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted) Navigator.of(context).pop(peer);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final expired = _link != null && _left == Duration.zero && _paired == null;
    return Scaffold(
      appBar: AppBar(title: const Text('Pair another phone')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          children: [
            Text(
              _paired != null ? 'Paired!' : 'Scan this code with the other phone',
              textAlign: TextAlign.center,
              style: text.titleLarge,
            ),
            const SizedBox(height: 6),
            Text(
              _paired != null
                  ? 'Clips now sync between this phone and ${_paired!.device.name}.'
                  : 'On the other phone: ClipStack → Pair with your computer (or Settings → Scan a pairing code).',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: context.mutedText, height: 1.4),
            ),
            const SizedBox(height: 28),
            Center(child: _codeCard(context, expired)),
            const SizedBox(height: 20),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.smartphone_rounded, size: 16, color: context.mutedText),
              const SizedBox(width: 6),
              Text(controller.phoneName, style: text.titleSmall),
            ]),
            const SizedBox(height: 24),
            _status(context, expired),
          ],
        ),
      ),
    );
  }

  Widget _codeCard(BuildContext context, bool expired) {
    const size = 236.0;
    final Widget inner;
    if (_paired != null) {
      inner = const SizedBox.square(
        dimension: size,
        child: Center(
          child: CircleAvatar(
            radius: 46,
            backgroundColor: Brand.success,
            child: Icon(Icons.check_rounded, color: Colors.white, size: 56),
          ),
        ),
      );
    } else if (_error != null) {
      inner = SizedBox.square(
        dimension: size,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.wifi_off_rounded, size: 44, color: Colors.black45),
            const SizedBox(height: 10),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black87)),
          ]),
        ),
      );
    } else if (_link == null) {
      inner = const SizedBox.square(
        dimension: size,
        child: Center(child: CircularProgressIndicator(color: Brand.seed)),
      );
    } else {
      inner = Opacity(
        opacity: expired ? 0.15 : 1,
        child: QrImageView(
          data: _link!.toUri(),
          size: size,
          padding: EdgeInsets.zero,
          backgroundColor: Colors.white,
          eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF16152A)),
          dataModuleStyle:
              const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF16152A)),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: context.heroShadow,
        border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
      ),
      child: inner,
    );
  }

  Widget _status(BuildContext context, bool expired) {
    final text = Theme.of(context).textTheme;
    if (_paired != null) return const SizedBox.shrink();
    if (_error != null || expired) {
      return Center(
        child: FilledButton.icon(
          onPressed: _open,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(expired ? 'Show a new code' : 'Try again'),
        ),
      );
    }
    if (_link == null) return const SizedBox.shrink();
    final minutes = _left.inMinutes, seconds = (_left.inSeconds % 60).toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.cardBorder),
      ),
      child: Row(children: [
        const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2.2)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Waiting for the other phone…', style: text.titleSmall),
            Text('Code expires in $minutes:$seconds · keep both on the same Wi-Fi',
                style: text.bodySmall?.copyWith(color: context.mutedText)),
          ]),
        ),
      ]),
    );
  }
}
