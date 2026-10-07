import 'dart:async';

/// A synchronously acquired native lease. Even a failed activation must be
/// released: the platform may have applied it before reporting the failure.
abstract interface class ReaderVolumeConnection {
  Future<void> get ready;
  Future<void> closeAndWait();
}

class ReaderVolumeFailure implements Exception {
  ReaderVolumeFailure(
    Iterable<({Object error, StackTrace stackTrace})> failures,
  ) : failures = List.unmodifiable(failures);

  final List<({Object error, StackTrace stackTrace})> failures;

  @override
  String toString() => failures.map((failure) => failure.error).join('; ');
}

/// Owns acknowledged native activation and release, independently of UI input.
class ReaderVolumeController {
  ReaderVolumeController({
    required this.connect,
    required this.nextPage,
    required this.previousPage,
    required this.nextChapter,
    required this.previousChapter,
    required this.onError,
  });

  final ReaderVolumeConnection Function(void Function(Object?) onEvent) connect;
  final bool Function() nextPage;
  final bool Function() previousPage;
  final void Function() nextChapter;
  final void Function() previousChapter;
  final void Function(Object, StackTrace) onError;
  ReaderVolumeConnection? _connection;
  Future<void> _queue = Future.value();
  Future<void>? _closing;
  bool _enabled = false;
  bool _disposed = false;
  bool _ready = false;
  int _generation = 0;
  int? _connectedGeneration;

  Future<void> setEnabled(bool enabled) {
    if (_disposed) return _closing ?? Future.value();
    if (_enabled != enabled) {
      _enabled = enabled;
      ++_generation;
    }
    return _schedule();
  }

  Future<void> _schedule() {
    final operation = _queue.then((_) async {
      try {
        await _reconcile();
      } catch (error, stack) {
        try {
          onError(error, stack);
        } catch (reportError, reportStack) {
          throw ReaderVolumeFailure([
            (error: error, stackTrace: stack),
            (error: reportError, stackTrace: reportStack),
          ]);
        }
        rethrow;
      }
    });
    // Only the serial tail consumes errors. Each caller gets the actual result.
    _queue = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> _release() async {
    final connection = _connection;
    if (connection == null) return;
    _ready = false;
    await connection.closeAndWait();
    _connection = null;
    _connectedGeneration = null;
  }

  Future<void> _reconcile() async {
    if (_connection != null &&
        (!_enabled ||
            _disposed ||
            !_ready ||
            _connectedGeneration != _generation)) {
      await _release();
    }
    if (_disposed || !_enabled || _connection != null) return;
    final generation = _generation;
    _connectedGeneration = generation;
    final connection = _connection = connect((event) {
      if (!_ready || !_isCurrent(generation)) return;
      try {
        if (event == 1) {
          if (!previousPage()) previousChapter();
        } else if (event == 2) {
          if (!nextPage()) nextChapter();
        }
      } catch (error, stack) {
        onError(error, stack);
      }
    });
    try {
      await connection.ready;
      _ready = true;
    } catch (error, stack) {
      try {
        await _release();
      } catch (releaseError, releaseStack) {
        throw ReaderVolumeFailure([
          (error: error, stackTrace: stack),
          (error: releaseError, stackTrace: releaseStack),
        ]);
      }
      rethrow;
    }
    if (!_isCurrent(generation)) await _release();
  }

  bool _isCurrent(int generation) =>
      !_disposed && _enabled && generation == _generation;

  /// Concurrent close shares one result; a failed close retains the lease so
  /// an explicit later close retries release without replaying activation.
  Future<void> dispose() {
    if (_closing case final closing?) return closing;
    _disposed = true;
    _enabled = false;
    ++_generation;
    final closing = _closing = _schedule();
    unawaited(
      closing.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          _closing = null;
        },
      ),
    );
    return closing;
  }
}
