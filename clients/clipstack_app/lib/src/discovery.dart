import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:clipstack_sync/clipstack_sync.dart';
import 'package:flutter/foundation.dart';

typedef PeerAddress = ({String host, int port});

/// Watches the network for ClipStack listeners (`_clipstack._tcp`) and
/// remembers where each device id currently is.
class PeerDiscovery {
  final _addresses = <String, PeerAddress>{};
  final _found = StreamController<String>.broadcast();
  BonsoirDiscovery? _discovery;

  /// This device's id: its own advertisement is not a peer.
  String? ownId;

  /// Emits a device id whenever that device is found or moves.
  Stream<String> get found => _found.stream;

  PeerAddress? lookup(String deviceId) => _addresses[deviceId];

  Future<void> start() async {
    if (_discovery != null) return;
    final discovery = BonsoirDiscovery(type: serviceType);
    _discovery = discovery;
    await discovery.initialize();
    discovery.eventStream?.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          discovery.serviceResolver.resolveService(event.service);
        case BonsoirDiscoveryServiceResolvedEvent():
          _record(event.service);
        case BonsoirDiscoveryServiceUpdatedEvent():
          _record(event.service);
        case BonsoirDiscoveryServiceLostEvent():
          final id = event.service.attributes['id'];
          if (id != null) _addresses.remove(id);
        default:
          break;
      }
    });
    await discovery.start();
  }

  void _record(BonsoirService service) {
    final id = service.attributes['id'];
    final addresses = service.hostAddresses;
    if (id == null || id == ownId || addresses.isEmpty) return;
    // Prefer IPv4: link-local IPv6 needs a scope id that sockets often lack.
    final host = addresses.firstWhere((a) => !a.contains(':'), orElse: () => addresses.first);
    final address = (host: host, port: service.port);
    if (_addresses[id] != address) {
      _addresses[id] = address;
      debugPrint('ClipStack: found $id at $host:${service.port}');
      _found.add(id);
    }
  }

  Future<void> stop() async {
    await _discovery?.stop();
    _discovery = null;
  }
}
