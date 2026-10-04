import 'dart:async';

import 'package:venera_next/foundation/operation_failure.dart';

/// An unsuccessful progress write or error report, in submission order.
class ReaderProgressWriteFailure {
  const ReaderProgressWriteFailure({
    required this.revision,
    required this.cause,
    required this.stackTrace,
    this.reportingError = false,
  });

  final int revision;
  final Object cause;
  final StackTrace stackTrace;
  final bool reportingError;
}

class ReaderProgressFailure implements FailureDetails {
  ReaderProgressFailure(Iterable<ReaderProgressWriteFailure> failures)
    : failures = List.unmodifiable(failures);

  final List<ReaderProgressWriteFailure> failures;

  @override
  FailureKind get kind => FailureKind.failed;

  @override
  String get message =>
      'Reading progress has ${failures.length} pending errors';

  @override
  Object? get cause => failures.firstOrNull?.cause;

  @override
  StackTrace? get stackTrace => failures.firstOrNull?.stackTrace;

  @override
  String toString() => message;
}

/// Owns delayed progress saves for one reader, without storage or UI access.
///
/// Writes replace a complete progress snapshot supplied by the adapter at
/// submission time. A newer successful snapshot repairs older write failures,
/// regardless of the order in which their futures complete.
class ReaderHistoryWriter {
  ReaderHistoryWriter({
    required Future<void> Function() write,
    required void Function(Object, StackTrace) onError,
    Duration delay = const Duration(seconds: 1),
  }) : _write = write,
       _onError = onError,
       _delay = delay;

  final Future<void> Function() _write;
  final void Function(Object, StackTrace) _onError;
  final Duration _delay;
  Timer? _timer;
  bool _disposed = false;
  int _submittedRevision = 0;
  int _savedRevision = 0;
  final Set<Future<void>> _pending = {};
  final Map<int, ReaderProgressWriteFailure> _failures = {};
  final List<ReaderProgressWriteFailure> _reportingFailures = [];
  Future<void>? _flushing;
  Future<void>? _closing;

  void schedule() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(_delay, () {
      _timer = null;
      _submit();
    });
  }

  void _submit() {
    final revision = ++_submittedRevision;
    final completed = Completer<void>();
    // Register before calling the adapter: a synchronous callback can request
    // another flush or dispose, which must already include this write.
    _pending.add(completed.future);
    unawaited(
      Future<void>.sync(_write).then(
        (_) {
          if (revision > _savedRevision) _savedRevision = revision;
          _failures.removeWhere((revision, _) => revision <= _savedRevision);
          _pending.remove(completed.future);
          completed.complete();
        },
        onError: (Object error, StackTrace stackTrace) {
          if (revision > _savedRevision) {
            _failures[revision] = ReaderProgressWriteFailure(
              revision: revision,
              cause: error,
              stackTrace: stackTrace,
            );
          }
          try {
            _onError(error, stackTrace);
          } catch (reportingError, reportingStackTrace) {
            _reportingFailures.add(
              ReaderProgressWriteFailure(
                revision: revision,
                cause: reportingError,
                stackTrace: reportingStackTrace,
                reportingError: true,
              ),
            );
          }
          _pending.remove(completed.future);
          completed.complete();
        },
      ),
    );
  }

  void _submitTimer() {
    final timer = _timer;
    if (timer == null) return;
    _timer = null;
    timer.cancel();
    _submit();
  }

  /// Immediately submits delayed progress and drains all accepted writes,
  /// including progress scheduled while this flush is waiting.
  ///
  /// An existing failure gets at most one newer snapshot attempt. A pending or
  /// newly scheduled newer write can serve as that attempt. Failures first
  /// encountered during this flush remain observable until a subsequent flush
  /// or a newer successful save; they cannot cause an unbounded retry loop.
  Future<void> flush() {
    if (_closing != null) return _closing!;
    if (_flushing != null) return _flushing!;
    final completed = Completer<void>();
    _flushing = completed.future;
    final retryRevision = _failures.keys.fold(
      0,
      (latest, revision) => revision > latest ? revision : latest,
    );
    unawaited(_drain(completed, retryRevision));
    return completed.future;
  }

  Future<void> _drain(Completer<void> completed, int retryRevision) async {
    while (true) {
      _submitTimer();
      if (_pending.isNotEmpty) {
        await Future.wait(_pending.toList());
        continue;
      }
      if (retryRevision > _savedRevision &&
          _submittedRevision <= retryRevision) {
        _submit();
        continue;
      }
      final failures = [..._failures.values, ..._reportingFailures]
        ..sort((a, b) {
          final order = a.revision.compareTo(b.revision);
          if (order != 0 || a.reportingError == b.reportingError) return order;
          return a.reportingError ? 1 : -1;
        });
      // End the admission window in the same turn as completing the result,
      // so a later schedule cannot sneak in between drain and completion.
      _flushing = null;
      if (failures.isEmpty) {
        completed.complete();
      } else {
        final failure = ReaderProgressFailure(failures);
        completed.completeError(failure, failure.stackTrace);
      }
      return;
    }
  }

  /// Permanently rejects new progress and shares the final drain result,
  /// including failure, with every subsequent dispose or flush call.
  Future<void> dispose() {
    if (_closing != null) return _closing!;
    _disposed = true;
    return _closing = flush();
  }
}
