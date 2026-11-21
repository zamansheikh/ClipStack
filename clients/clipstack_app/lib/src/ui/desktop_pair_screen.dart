import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../storage.dart';
import '../sync_controller.dart';
import 'my_code_screen.dart';
import 'theme.dart';
import 'widgets.dart';

/// Pairing on a PC, which has no camera to scan with: show this PC's code
/// for a phone to scan, or paste a pairing link copied from a Mac (or from
/// another PC's code screen). Pops with the new PairedPeer.
class DesktopPairScreen extends StatefulWidget {
  const DesktopPairScreen({super.key, required this.controller});

  final SyncController controller;

  @override
  State<DesktopPairScreen> createState() => _DesktopPairScreenState();
}

class _DesktopPairScreenState extends State<DesktopPairScreen> {
  final _link = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _showCode() async {
    final peer = await Navigator.of(context).push<PairedPeer>(
      MaterialPageRoute(builder: (_) => MyCodeScreen(controller: widget.controller)),
    );
    if (peer != null && mounted) Navigator.of(context).pop(peer);
  }

  Future<void> _pairWithLink() async {
    final link = _link.text.trim();
    if (link.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final peer = await widget.controller.pair(link);
      if (mounted) Navigator.of(context).pop(peer);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget card({required IconData icon, required String title, required String body, required List<Widget> children}) =>
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: context.cardColor,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: context.cardBorder),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              IconTile(icon: icon, gradient: true),
              const SizedBox(width: 14),
              Expanded(child: Text(title, style: text.titleMedium)),
            ]),
            const SizedBox(height: 12),
            Text(body, style: text.bodySmall?.copyWith(color: context.mutedText, height: 1.45)),
            const SizedBox(height: 16),
            ...children,
          ]),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Pair a device')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          card(
            icon: Icons.smartphone_rounded,
            title: 'Pair a phone',
            body: 'On your phone, open ClipStack, tap Pair with your computer, and scan the code this PC shows.',
            children: [
              FilledButton.icon(
                onPressed: _showCode,
                icon: const Icon(Icons.qr_code_2_rounded),
                label: const Text('Show pairing code'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              ),
            ],
          ),
          card(
            icon: Icons.laptop_mac_rounded,
            title: 'Pair with a Mac',
            body: 'On the Mac: ClipStack → Settings → Devices → Pair a Device, then "Can\'t scan? Copy pairing link". '
                'Get that link to this PC and paste it here.',
            children: [
              TextField(
                controller: _link,
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
                      final value = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
                      if (value != null) _link.text = value;
                    },
                  ),
                ),
                onSubmitted: (_) => _pairWithLink(),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : _pairWithLink,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                child: _busy
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Pair'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
