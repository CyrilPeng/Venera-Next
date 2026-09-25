import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

enum AutoReadingStatus { stopped, running, paused, waiting }

enum AutoReadingStep { advanced, waiting, finished }

class AutoReadingSettings {
  const AutoReadingSettings({
    this.gallery = false,
    this.pageInterval = 5,
    this.pixelsPerSecond = 80,
    this.stepped = false,
    this.stepsPerSecond = 2,
    this.pixelsPerStep = 40,
  });

  final bool gallery, stepped;
  final double pageInterval, pixelsPerSecond, stepsPerSecond, pixelsPerStep;
}

/// Drives reading from frame timestamps, without accumulating work while paused.
class AutoReadingController extends ChangeNotifier {
  AutoReadingController({
    required this.settings,
    required this.advance,
    required this.canAdvance,
  }) {
    _ticker = Ticker(_tick);
  }

  final AutoReadingSettings Function() settings;
  final AutoReadingStep Function(double distance) advance;
  final bool Function() canAdvance;
  late final Ticker _ticker;
  final _pauses = <Object>{};
  AutoReadingStatus _status = AutoReadingStatus.stopped;
  Duration? _previous;
  double _accumulated = 0;

  AutoReadingStatus get status => _status;
  bool get isActive => status != AutoReadingStatus.stopped;

  void _setStatus(AutoReadingStatus value) {
    if (_status == value) return;
    _status = value;
    notifyListeners();
  }

  void start() {
    if (isActive) return;
    _previous = null;
    _accumulated = 0;
    _setStatus(
      _pauses.isEmpty ? AutoReadingStatus.running : AutoReadingStatus.paused,
    );
    if (_pauses.isEmpty) _ticker.start();
  }

  void stop() {
    _ticker.stop();
    _previous = null;
    _accumulated = 0;
    _setStatus(AutoReadingStatus.stopped);
  }

  void toggle() => isActive ? stop() : start();

  void pause(Object reason, bool paused) {
    if (paused) {
      _pauses.add(reason);
    } else {
      _pauses.remove(reason);
    }
    _previous = null;
    _accumulated = 0;
    if (isActive) {
      if (_pauses.isEmpty && !_ticker.isActive) {
        _ticker.start();
      } else if (_pauses.isNotEmpty) {
        _ticker.stop();
      }
      _setStatus(
        _pauses.isEmpty ? AutoReadingStatus.running : AutoReadingStatus.paused,
      );
    }
  }

  void _tick(Duration elapsed) {
    final previous = _previous;
    _previous = elapsed;
    if (_pauses.isNotEmpty) return;
    if (!canAdvance()) {
      _accumulated = 0;
      _setStatus(AutoReadingStatus.waiting);
      return;
    }
    if (previous == null) return;
    final config = settings();
    final seconds =
        (elapsed - previous).inMicroseconds / Duration.microsecondsPerSecond;
    // A stalled frame must not jump over content when rendering resumes.
    final delta = seconds.clamp(0.0, 0.1);
    _accumulated += delta;
    double distance;
    if (config.gallery || config.stepped) {
      final interval = config.gallery
          ? config.pageInterval.clamp(1.0, 60.0)
          : 1 / config.stepsPerSecond.clamp(1.0, 10.0);
      if (_accumulated + 0.000001 < interval) {
        _setStatus(AutoReadingStatus.running);
        return;
      }
      _accumulated = (_accumulated - interval).clamp(0.0, interval);
      distance = config.gallery ? 0 : config.pixelsPerStep.clamp(1.0, 500.0);
    } else {
      distance = config.pixelsPerSecond.clamp(10.0, 1000.0) * delta;
    }
    switch (advance(distance)) {
      case AutoReadingStep.advanced:
        _setStatus(AutoReadingStatus.running);
      case AutoReadingStep.waiting:
        _accumulated = 0;
        _setStatus(AutoReadingStatus.waiting);
      case AutoReadingStep.finished:
        stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

abstract interface class AutoReadingViewport {
  bool get autoReadingReady;
  AutoReadingStep autoScroll(double distance, {required bool acrossChapters});
}
