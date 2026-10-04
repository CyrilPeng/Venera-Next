import 'dart:async';

import 'package:flutter/services.dart';

/// One native watchdog registration for one interactive mount. Native owner
/// ids isolate late responses and stops from a replacement mount.
class WindowsHeartbeat {
  WindowsHeartbeat({
    this.channel = const MethodChannel('venera/method_channel'),
  });

  final MethodChannel channel;
  final _pending = <Future<void>>{};
  Future<int>? _registration;
  int? _owner;
  bool _closed = false;
  Future<void>? _closure;

  Future<void> send() {
    if (_closed) return Future.error(StateError('Heartbeat is closed'));
    final done = Completer<void>();
    _pending.add(done.future);
    return _send(done);
  }

  Future<int> _register() async {
    try {
      final owner = await channel.invokeMethod<int>('startHeartbeat');
      if (owner == null || owner < 0) {
        throw StateError('Native heartbeat registration returned no owner');
      }
      _owner = owner;
      return owner;
    } catch (_) {
      _registration = null;
      rethrow;
    }
  }

  Future<void> _send(Completer<void> done) async {
    try {
      final owner = await (_registration ??= _register());
      if (!_closed) await channel.invokeMethod<void>('heartBeat', owner);
    } finally {
      _pending.remove(done.future);
      done.complete();
    }
  }

  Future<void> close() {
    _closed = true;
    return _closure ??= _close();
  }

  Future<void> _close() async {
    await Future.wait(_pending);
    final owner = _owner;
    if (owner != null) {
      await channel.invokeMethod<void>('stopHeartbeat', owner);
    }
  }
}
