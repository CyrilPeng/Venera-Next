import 'dart:async';

import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/foundation/persistence_failure.dart';

typedef ReadingDurationWriter = Future<void> Function(Duration duration);
typedef ReadingSessionErrorHandler =
    void Function(Object error, StackTrace stackTrace);

/// An unsuccessful write or error report, associated with its reading period.
class ReadingDurationWriteFailure {
  const ReadingDurationWriteFailure({
    required this.duration,
    required this.cause,
    required this.stackTrace,
    this.reportingError = false,
  });

  final Duration duration;
  final Object cause;
  final StackTrace stackTrace;
  final bool reportingError;
}

class ReadingDurationFailure implements FailureDetails {
  ReadingDurationFailure(Iterable<ReadingDurationWriteFailure> failures)
    : failures = List.unmodifiable(failures);

  final List<ReadingDurationWriteFailure> failures;

  @override
  FailureKind get kind => FailureKind.failed;

  @override
  String get message =>
      'Reading duration has ${failures.length} pending errors';

  @override
  Object? get cause => failures.firstOrNull?.cause;

  @override
  StackTrace? get stackTrace => failures.firstOrNull?.stackTrace;

  @override
  String toString() => message;
}

class _FailedDuration {
  _FailedDuration(this.duration);

  final Duration duration;
  final List<ReadingDurationWriteFailure> failures = [];

  bool get canRetry {
    final error = failures.last.cause;
    return error is PersistenceFailure &&
        error.commitState == PersistenceCommitState.notCommitted;
  }
}

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
  final List<_FailedDuration> _failedDurations = [];
  final List<ReadingDurationWriteFailure> _reportingFailures = [];
  Future<void>? _flushing;
  Future<void>? _closing;
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
    if (_closing != null) return _closing!;
    _disposed = true;
    return _closing = pause().then((_) => flush());
  }

  /// Drain submitted periods, retrying each definitively uncommitted period
  /// once. An unknown or already committed result must never be replayed: the
  /// writer accumulates durations rather than replacing a progress snapshot.
  Future<void> flush() {
    if (_flushing != null) return _flushing!;
    late final Future<void> flushing;
    flushing = _flush().whenComplete(() {
      if (identical(_flushing, flushing)) _flushing = null;
    });
    return _flushing = flushing;
  }

  Future<void> _flush() async {
    final retried = <_FailedDuration>{};
    while (true) {
      final queued = _writeQueue;
      await queued;
      final retries = _failedDurations
          .where((period) => period.canRetry && !retried.contains(period))
          .toList();
      if (retries.isNotEmpty) {
        retried.addAll(retries);
        _writeQueue = _writeQueue.then((_) async {
          for (final period in retries) {
            await _writeDuration(period.duration, retry: period);
          }
        });
        continue;
      }
      // Periods recorded while the preceding write was pending belong to this
      // drain too. All writes, including retries, use the same serial queue.
      if (!identical(queued, _writeQueue)) continue;
      final failures = [
        for (final period in _failedDurations) ...period.failures,
        ..._reportingFailures,
      ];
      if (failures.isNotEmpty) throw ReadingDurationFailure(failures);
      return;
    }
  }

  Future<void> _finishPeriod({required bool restart}) {
    final startedAt = _startedAt;
    if (startedAt == null) return _writeQueue;

    final now = _elapsedNow();
    _startedAt = restart && !_disposed ? now : null;
    final duration = now - startedAt;
    if (duration <= Duration.zero) return _writeQueue;

    _writeQueue = _writeQueue.then((_) => _writeDuration(duration));
    return _writeQueue;
  }

  Future<void> _writeDuration(
    Duration duration, {
    _FailedDuration? retry,
  }) async {
    try {
      await _onDuration(duration);
      if (retry != null) _failedDurations.remove(retry);
    } catch (error, stackTrace) {
      final period = retry ?? _FailedDuration(duration);
      period.failures.add(
        ReadingDurationWriteFailure(
          duration: duration,
          cause: error,
          stackTrace: stackTrace,
        ),
      );
      if (retry == null) _failedDurations.add(period);
      try {
        _onError?.call(error, stackTrace);
      } catch (reportingError, reportingStackTrace) {
        _reportingFailures.add(
          ReadingDurationWriteFailure(
            duration: duration,
            cause: reportingError,
            stackTrace: reportingStackTrace,
            reportingError: true,
          ),
        );
      }
    }
  }
}
