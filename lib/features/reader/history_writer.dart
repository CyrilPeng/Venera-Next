import 'dart:async';

/// Owns delayed progress saves for one reader, without storage or UI access.
///
/// The adapter supplies the current history item at write time. A pending save
/// is submitted immediately on exit. Disposal waits for all accepted writes,
/// including an asynchronous exit flush, before the session can notify sync.
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
  final Set<Future<void>> _pending = {};
  Future<void>? _closing;

  void schedule() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(_delay, () {
      _timer = null;
      _submit(_write);
    });
  }

  void _submit(FutureOr<void> Function() write) {
    late final Future<void> pending;
    pending = Future<void>.sync(write).catchError(_onError).whenComplete(() {
      _pending.remove(pending);
    });
    _pending.add(pending);
  }

  Future<void> dispose() {
    if (_closing != null) return _closing!;
    _disposed = true;
    final pending = _timer;
    _timer = null;
    if (pending != null) {
      pending.cancel();
      _submit(_write);
    }
    return _closing = Future.wait(_pending.toList()).then((_) {});
  }
}
