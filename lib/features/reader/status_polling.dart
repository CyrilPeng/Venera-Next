import 'dart:async';

class ReaderBatterySnapshot {
  const ReaderBatterySnapshot(this.level, {required this.charging});
  final int level;
  final bool charging;
}

typedef ReaderBatteryRead = Future<ReaderBatterySnapshot?> Function();

/// One optional telemetry source. Pausing rejects late values without forgetting
/// the actual request; closing stops the clock and drains that same request.
class ReaderStatusPolling {
  ReaderStatusPolling({
    required this.readBattery,
    required DateTime Function() now,
    required void Function() onChanged,
  }) : _now = now,
       _onChanged = onChanged {
    _updateClock();
  }

  final ReaderBatteryRead readBattery;
  DateTime Function() _now;
  void Function()? _onChanged;
  Timer? _timer;
  Completer<void>? _pending;
  bool _active = false;
  bool _closed = false;
  bool _supported = true;
  int _generation = 0;
  String _time = '';
  ReaderBatterySnapshot? _battery;

  String get time => _time;
  ReaderBatterySnapshot? get battery => _battery;

  void setClock(DateTime Function() now) {
    if (_closed) return;
    _now = now;
    _updateClock();
  }

  bool _updateClock() {
    final now = _now();
    final next =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    if (next == _time) return false;
    _time = next;
    return true;
  }

  void setActive(bool active) {
    if (_closed || active == _active) return;
    _active = active;
    if (!active) {
      _generation++;
      _timer?.cancel();
      _timer = null;
      return;
    }
    // Install the timer before invoking callbacks that can reenter close.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _tick();
  }

  void _tick() {
    if (!_active || _closed) return;
    if (_updateClock()) _onChanged?.call();
    _sample();
  }

  void _sample() {
    if (!_active || _closed || _pending != null || !_supported) return;
    final done = _pending = Completer<void>();
    final generation = _generation;
    // Retain the request before calling an adapter that can reenter shutdown.
    unawaited(
      Future<ReaderBatterySnapshot?>.sync(readBattery).then<void>(
        (next) {
          try {
            if (!_active || _closed || generation != _generation) return;
            _supported = next != null;
            if (_battery?.level != next?.level ||
                _battery?.charging != next?.charging) {
              _battery = next;
              _onChanged?.call();
            }
          } finally {
            _pending = null;
            done.complete();
          }
        },
        onError: (Object _, StackTrace _) {
          // Battery failures are optional telemetry, including during shutdown.
          // Transient failures retry on the next active tick.
          _pending = null;
          done.complete();
        },
      ),
    );
  }

  Future<void> drain() => _pending?.future ?? Future<void>.value();

  Future<void> closeAndWait() {
    if (!_closed) {
      setActive(false);
      _closed = true;
      _onChanged = null;
    }
    return drain();
  }
}
