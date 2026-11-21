import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../storage.dart';
import '../sync_controller.dart';
import 'theme.dart';
import 'widgets.dart';

enum _Phase { scanning, pairing, success, failed }

/// Full-screen QR scanner for the code in the computer's "Pair a Device"
/// window. Pops with the new PairedPeer once pairing succeeds.
class PairScreen extends StatefulWidget {
  const PairScreen({super.key, required this.controller});

  final SyncController controller;

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> with SingleTickerProviderStateMixin {
  final _scanner = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  late final AnimationController _sweep =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))..repeat(reverse: true);

  _Phase _phase = _Phase.scanning;
  String _status = '';

  @override
  void dispose() {
    _sweep.dispose();
    _scanner.dispose();
    super.dispose();
  }

  Future<void> _pair(String link) async {
    if (_phase == _Phase.pairing || _phase == _Phase.success) return;
    HapticFeedback.mediumImpact();
    String name = 'your computer';
    try {
      name = Uri.parse(link.trim()).queryParameters['name'] ?? name;
    } on FormatException {
      // fall through to the pair() error
    }
    setState(() {
      _phase = _Phase.pairing;
      _status = 'Pairing with $name…';
    });
    await _scanner.stop();
    try {
      final PairedPeer peer = await widget.controller.pair(link);
      HapticFeedback.heavyImpact();
      if (!mounted) return;
      setState(() {
        _phase = _Phase.success;
        _status = 'Paired with ${peer.device.name}';
      });
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      if (mounted) Navigator.of(context).pop(peer);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _status = error is FormatException ? error.message : '$error';
      });
    }
  }

  Future<void> _retry() async {
    setState(() => _phase = _Phase.scanning);
    await _scanner.start();
  }

  Future<void> _pasteLink() async {
    final link = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _PasteLinkSheet(),
    );
    if (link != null && link.trim().isNotEmpty) await _pair(link);
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(builder: (context, constraints) {
          final side = (constraints.maxWidth * 0.68).clamp(200.0, 300.0);
          final window = Rect.fromCenter(
            center: Offset(constraints.maxWidth / 2, constraints.maxHeight * 0.42),
            width: side,
            height: side,
          );
          return Stack(fit: StackFit.expand, children: [
            MobileScanner(
              controller: _scanner,
              scanWindow: window,
              onDetect: (capture) {
                for (final code in capture.barcodes) {
                  final value = code.rawValue;
                  if (value != null && value.startsWith('clipstack://pair')) {
                    _pair(value);
                    return;
                  }
                }
              },
              errorBuilder: (context, error) => _CameraUnavailable(onPaste: _pasteLink),
            ),
            // Dimmed surroundings, the window frame and the sweeping line.
            AnimatedBuilder(
              animation: _sweep,
              builder: (context, _) => CustomPaint(
                painter: _ScannerOverlay(
                  window: window,
                  sweep: _phase == _Phase.scanning ? _sweep.value : null,
                  success: _phase == _Phase.success,
                ),
              ),
            ),
            // Title above the window.
            Positioned(
              left: 24,
              right: 24,
              bottom: constraints.maxHeight - window.top + 28,
              child: Column(children: [
                Text('Scan a pairing code',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white)),
                const SizedBox(height: 6),
                Text('Mac: Settings → Devices → Pair a Device  ·  Phone: Show my code',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70)),
              ]),
            ),
            // Status in the window while pairing / after.
            if (_phase != _Phase.scanning && _phase != _Phase.failed)
              Positioned.fromRect(
                rect: window,
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                    child: _phase == _Phase.success
                        ? Container(
                            key: const ValueKey('ok'),
                            width: 84,
                            height: 84,
                            decoration: const BoxDecoration(shape: BoxShape.circle, color: Brand.success),
                            child: const Icon(Icons.check_rounded, color: Colors.white, size: 52),
                          )
                        : const SizedBox.square(
                            key: ValueKey('busy'),
                            dimension: 56,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                          ),
                  ),
                ),
              ),
            // Top controls.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(children: [
                    _GlassButton(icon: Icons.close_rounded, tooltip: 'Close', onTap: () => Navigator.of(context).pop()),
                    const Spacer(),
                    ValueListenableBuilder<MobileScannerState>(
                      valueListenable: _scanner,
                      builder: (context, state, _) {
                        if (state.torchState == TorchState.unavailable) return const SizedBox.shrink();
                        final on = state.torchState == TorchState.on;
                        return _GlassButton(
                          icon: on ? Icons.flashlight_on_rounded : Icons.flashlight_off_rounded,
                          tooltip: on ? 'Turn off light' : 'Turn on light',
                          highlighted: on,
                          onTap: () {
                            tick();
                            _scanner.toggleTorch();
                          },
                        );
                      },
                    ),
                  ]),
                ),
              ),
            ),
            // Bottom panel.
            Positioned(
              left: 16,
              right: 16,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _BottomPanel(phase: _phase, status: _status, onPaste: _pasteLink, onRetry: _retry),
                ),
              ),
            ),
          ]);
        }),
      ),
    );
  }
}

class _BottomPanel extends StatelessWidget {
  const _BottomPanel({required this.phase, required this.status, required this.onPaste, required this.onRetry});

  final _Phase phase;
  final String status;
  final VoidCallback onPaste;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final Widget content = switch (phase) {
      _Phase.failed => Column(key: const ValueKey('failed'), children: [
          Row(children: [
            const Icon(Icons.error_outline_rounded, color: Color(0xFFFF6B6B)),
            const SizedBox(width: 12),
            Expanded(child: Text(status, style: text.bodyMedium?.copyWith(color: Colors.white))),
          ]),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Brand.seed),
              onPressed: onRetry,
              child: const Text('Scan again'),
            ),
          ),
        ]),
      _Phase.pairing || _Phase.success => Padding(
          key: const ValueKey('status'),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(status, textAlign: TextAlign.center, style: text.titleSmall?.copyWith(color: Colors.white)),
        ),
      _Phase.scanning => Row(key: const ValueKey('scan'), children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.wifi_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text('Keep your phone and computer on the same Wi-Fi.',
                style: text.bodySmall?.copyWith(color: Colors.white.withValues(alpha: 0.85), height: 1.35)),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            onPressed: onPaste,
            child: const Text('Paste link'),
          ),
        ]),
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: content),
        ),
      ),
    );
  }
}

class _GlassButton extends StatelessWidget {
  const _GlassButton({required this.icon, required this.tooltip, required this.onTap, this.highlighted = false});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: ClipOval(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Material(
              color: highlighted ? Colors.white : Colors.black.withValues(alpha: 0.35),
              child: InkWell(
                onTap: onTap,
                child: SizedBox.square(
                  dimension: 46,
                  child: Icon(icon, color: highlighted ? Colors.black : Colors.white),
                ),
              ),
            ),
          ),
        ),
      );
}

/// Darkens everything outside the scan window, draws rounded corner
/// brackets and a soft sweeping line inside it.
class _ScannerOverlay extends CustomPainter {
  _ScannerOverlay({required this.window, required this.sweep, required this.success});

  final Rect window;
  final double? sweep;
  final bool success;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(window, const Radius.circular(28));
    // Dim layer with the window erased. (An even-odd path hole rendered with
    // square corners under Impeller; clearing inside a layer is exact.)
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black.withValues(alpha: 0.58));
    canvas.drawRRect(rrect, Paint()..blendMode = BlendMode.clear);
    canvas.restore();

    // Corner brackets.
    final color = success ? Brand.success : Colors.white;
    final bracket = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    const len = 34.0, r = 28.0;
    final l = window.left, t = window.top, rt = window.right, b = window.bottom;
    for (final corner in [
      Path()
        ..moveTo(l, t + len)
        ..lineTo(l, t + r)
        ..arcToPoint(Offset(l + r, t), radius: const Radius.circular(r))
        ..lineTo(l + len, t),
      Path()
        ..moveTo(rt - len, t)
        ..lineTo(rt - r, t)
        ..arcToPoint(Offset(rt, t + r), radius: const Radius.circular(r))
        ..lineTo(rt, t + len),
      Path()
        ..moveTo(rt, b - len)
        ..lineTo(rt, b - r)
        ..arcToPoint(Offset(rt - r, b), radius: const Radius.circular(r))
        ..lineTo(rt - len, b),
      Path()
        ..moveTo(l + len, b)
        ..lineTo(l + r, b)
        ..arcToPoint(Offset(l, b - r), radius: const Radius.circular(r))
        ..lineTo(l, b - len),
    ]) {
      canvas.drawPath(corner, bracket);
    }

    // Sweeping line with a fading glow trail.
    final s = sweep;
    if (s != null) {
      final y = window.top + 18 + (window.height - 36) * Curves.easeInOut.transform(s);
      final line = Rect.fromLTWH(window.left + 18, y - 1.5, window.width - 36, 3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(line, const Radius.circular(2)),
        Paint()
          ..shader = const LinearGradient(colors: [Colors.transparent, Brand.blue, Brand.purple, Colors.transparent])
              .createShader(line),
      );
      final glow = Rect.fromLTWH(window.left + 18, y - 28, window.width - 36, 28);
      canvas.drawRect(
        glow,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Brand.violet.withValues(alpha: 0.28), Brand.violet.withValues(alpha: 0)],
          ).createShader(glow),
      );
    }
  }

  @override
  bool shouldRepaint(_ScannerOverlay old) => old.sweep != sweep || old.success != success || old.window != window;
}

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({required this.onPaste});

  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: const Color(0xFF0F0F16),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.no_photography_outlined, color: Colors.white54, size: 48),
              const SizedBox(height: 12),
              Text('Camera unavailable',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white)),
              const SizedBox(height: 6),
              Text('Allow camera access in Settings, or paste the pairing link instead.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white60)),
              const SizedBox(height: 16),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                onPressed: onPaste,
                child: const Text('Paste link'),
              ),
            ]),
          ),
        ),
      );
}

class _PasteLinkSheet extends StatefulWidget {
  const _PasteLinkSheet();

  @override
  State<_PasteLinkSheet> createState() => _PasteLinkSheetState();
}

class _PasteLinkSheetState extends State<_PasteLinkSheet> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Paste pairing link', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text('On your computer, use "Can\'t scan? Copy pairing link" in the Pair a Device window.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.mutedText)),
        const SizedBox(height: 16),
        TextField(
          controller: _field,
          autofocus: true,
          minLines: 1,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: 'clipstack://pair?…',
            filled: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            suffixIcon: IconButton(
              tooltip: 'Paste',
              icon: const Icon(Icons.content_paste_rounded),
              onPressed: () async {
                final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
                if (text != null) _field.text = text;
              },
            ),
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: () => Navigator.of(context).pop(_field.text), child: const Text('Pair')),
      ]),
    );
  }
}
