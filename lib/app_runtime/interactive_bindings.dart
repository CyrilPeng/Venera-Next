import 'dart:async';
import 'package:flutter/services.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/event_subscription.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/routing/app_links.dart';
import 'package:venera_next/routing/handle_text_share.dart';

/// Platform listeners and heartbeat belong to the mounted interactive app.
class InteractiveBindings {
  InteractiveBindings({
    required this.android,
    required this.windows,
    required this.links,
    required this.shares,
    required this.heartbeat,
  });

  factory InteractiveBindings.platform() => InteractiveBindings(
    android: App.isAndroid,
    windows: App.isWindows,
    links: createAppLinkSubscription,
    shares: createTextShareSubscription,
    heartbeat: () async {
      try {
        await const MethodChannel(
          'venera/method_channel',
        ).invokeMethod<void>('heartBeat');
      } catch (error, stack) {
        Log.error('Heartbeat', error, stack);
      }
    },
  );

  final bool android;
  final bool windows;
  final EventSubscription<Uri> Function() links;
  final EventSubscription<Object?> Function() shares;
  final Future<void> Function() heartbeat;
  EventSubscription<Uri>? _links;
  EventSubscription<Object?>? _shares;
  Timer? _heartbeat;
  bool _started = false;
  bool _disposed = false;
  Future<void>? _disposal;

  void start() {
    if (_disposed) throw StateError('Interactive bindings are disposed');
    if (_started) return;
    _started = true;
    try {
      if (android) {
        _links = links();
        _links!.start();
        _shares = shares();
        _shares!.start();
      }
      if (windows) {
        _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!_disposed) unawaited(heartbeat());
        });
      }
    } catch (_) {
      unawaited(dispose());
      rethrow;
    }
  }

  Future<void> dispose() {
    _disposed = true;
    _heartbeat?.cancel();
    return _disposal ??= Future.wait([
      if (_links != null) _links!.dispose(),
      if (_shares != null) _shares!.dispose(),
    ]).then((_) {});
  }
}
