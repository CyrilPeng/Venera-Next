import 'dart:async';

/// Owns a volume subscription and navigation policy. The adapter supplies the
/// platform stream; cancellation completion is defined by that stream.
class ReaderVolumeController {
  ReaderVolumeController({
    required this.events,
    required this.nextPage,
    required this.previousPage,
    required this.nextChapter,
    required this.previousChapter,
    required this.onError,
  });

  final Stream<Object?> Function() events;
  final bool Function() nextPage;
  final bool Function() previousPage;
  final void Function() nextChapter;
  final void Function() previousChapter;
  final void Function(Object, StackTrace) onError;
  StreamSubscription<Object?>? _subscription;
  Future<void> _queue = Future.value();
  bool _enabled = false;
  bool _disposed = false;
  int _generation = 0;
  int? _subscribedGeneration;

  Future<void> setEnabled(bool enabled) {
    if (_disposed) return _queue;
    if (_enabled != enabled) {
      _enabled = enabled;
      ++_generation;
    }
    return _schedule();
  }

  Future<void> _schedule() {
    return _queue = _queue.then((_) => _reconcile()).catchError(onError);
  }

  Future<void> _reconcile() async {
    if (_subscription != null &&
        (!_enabled || _disposed || _subscribedGeneration != _generation)) {
      final subscription = _subscription!;
      _subscription = null;
      _subscribedGeneration = null;
      await subscription.cancel();
    }
    if (_disposed || !_enabled || _subscription != null) return;
    final generation = _generation;
    _subscribedGeneration = generation;
    _subscription = events().listen(
      (event) {
        if (!_isCurrent(generation)) return;
        try {
          if (event == 1) {
            if (!previousPage()) previousChapter();
          } else if (event == 2) {
            if (!nextPage()) nextChapter();
          }
        } catch (error, stack) {
          onError(error, stack);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (_isCurrent(generation)) onError(error, stack);
      },
      onDone: () {
        if (_subscribedGeneration == generation) {
          _subscription = null;
          _subscribedGeneration = null;
        }
      },
    );
  }

  bool _isCurrent(int generation) =>
      !_disposed && _enabled && generation == _generation;

  Future<void> dispose() {
    if (_disposed) return _queue;
    _disposed = true;
    _enabled = false;
    ++_generation;
    return _schedule();
  }
}
