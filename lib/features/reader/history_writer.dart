import 'dart:async';

/// Owns delayed progress saves for one reader, without storage or UI access.
///
/// The adapter supplies the current history item at write time. A pending save
/// is flushed synchronously on exit, preserving the existing reader contract.
/// Writes already accepted by storage remain owned by its operation queue.
class ReaderHistoryWriter {
  ReaderHistoryWriter({
    required Future<void> Function() write,
    required void Function() flush,
    required void Function(Object, StackTrace) onError,
    Duration delay = const Duration(seconds: 1),
  }) : _write = write,
       _flush = flush,
       _onError = onError,
       _delay = delay;

  final Future<void> Function() _write;
  final void Function() _flush;
  final void Function(Object, StackTrace) _onError;
  final Duration _delay;
  Timer? _timer;
  bool _disposed = false;

  void schedule() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(_delay, () {
      _timer = null;
      unawaited(Future<void>.sync(_write).catchError(_onError));
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final pending = _timer;
    _timer = null;
    if (pending == null) return;
    pending.cancel();
    try {
      _flush();
    } catch (error, stack) {
      _onError(error, stack);
    }
  }
}
