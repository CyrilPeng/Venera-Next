import 'dart:async';

typedef ReadingDurationWriter = Future<void> Function(Duration duration);
typedef ReadingSessionErrorHandler =
    void Function(Object error, StackTrace stackTrace);

class ReadingSessionTracker {
  ReadingSessionTracker({
    required ReadingDurationWriter onDuration,
    Duration checkpointInterval = const Duration(minutes: 1),
    Duration Function()? elapsedNow,
    ReadingSessionErrorHandler? onError,
  }) : _onDuration = onDuration,
       _checkpointInterval = checkpointInterval,
       _elapsedNow = elapsedNow ?? _defaultElapsedNow,
       _onError = onError;

  static final Stopwatch _clock = Stopwatch()..start();

  static Duration _defaultElapsedNow() => _clock.elapsed;

  final ReadingDurationWriter _onDuration;
  final Duration _checkpointInterval;
  final Duration Function() _elapsedNow;
  final ReadingSessionErrorHandler? _onError;

  Duration? _startedAt;
  Timer? _checkpointTimer;
  Future<void> _writeQueue = Future.value();
  bool _disposed = false;

  bool get isRunning => _startedAt != null;

  void start() {
    if (_disposed || isRunning) return;
    _startedAt = _elapsedNow();
    _checkpointTimer ??= Timer.periodic(_checkpointInterval, (_) {
      unawaited(checkpoint());
    });
  }

  Future<void> checkpoint() => _finishPeriod(restart: true);

  Future<void> pause() {
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    return _finishPeriod(restart: false);
  }

  Future<void> dispose() {
    _disposed = true;
    return pause();
  }

  Future<void> _finishPeriod({required bool restart}) {
    final startedAt = _startedAt;
    if (startedAt == null) return _writeQueue;

    final now = _elapsedNow();
    _startedAt = restart && !_disposed ? now : null;
    final duration = now - startedAt;
    if (duration <= Duration.zero) return _writeQueue;

    _writeQueue = _writeQueue.then((_) => _onDuration(duration)).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      _onError?.call(error, stackTrace);
    });
    return _writeQueue;
  }
}
