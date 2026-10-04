import 'dart:async';

/// Serializes calls to a native dialog with one active result handler.
/// Acknowledgment is not proof that an external consumer has finished reading.
class PlatformDialogQueue {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) async {
    final previous = _tail;
    final completion = Completer<void>();
    _tail = completion.future;
    await previous;
    try {
      return await action();
    } finally {
      completion.complete();
    }
  }
}
