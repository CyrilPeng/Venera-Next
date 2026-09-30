import 'dart:async';

/// Serial event handling with an explicit lifetime, including awaited handlers.
class EventSubscription<T> {
  EventSubscription({
    required this.events,
    required this.handle,
    required this.onError,
  });
  final Stream<T> events;
  final Future<void> Function(T event, bool Function() isActive) handle;
  final void Function(Object error, StackTrace stack) onError;
  StreamSubscription<void>? _subscription;
  Future<void>? _disposal;
  bool _disposed = false;

  void start() {
    if (_disposed) throw StateError('Event subscription is disposed');
    if (_subscription != null) return;
    _subscription = events
        .asyncMap((event) async {
          if (!_disposed) await handle(event, () => !_disposed);
        })
        .listen(
          (_) {},
          onError: (Object error, StackTrace stack) {
            if (!_disposed) onError(error, stack);
          },
        );
  }

  Future<void> dispose() {
    _disposed = true;
    return _disposal ??= _subscription?.cancel() ?? Future<void>.value();
  }
}
