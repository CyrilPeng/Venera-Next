import 'dart:async';

/// Serializes desktop window transitions and owns the reader close listener.
/// Native calls already in flight finish before exit restores windowed mode.
class ReaderWindowController {
  ReaderWindowController({
    required this.hide,
    required this.show,
    required this.setFullscreen,
    required this.setFrameVisible,
    required this.addCloseListener,
    required this.removeCloseListener,
    required this.canPop,
    required this.pop,
    required this.onError,
  });

  final Future<void> Function() hide, show;
  final Future<void> Function(bool) setFullscreen;
  final void Function(bool) setFrameVisible;
  final void Function(bool Function()) addCloseListener, removeCloseListener;
  final bool Function() canPop;
  final void Function() pop;
  final void Function(Object, StackTrace) onError;
  bool _attached = false;
  bool _disposed = false;
  bool _fullscreen = false;
  bool _requestedFullscreen = false;
  bool _restoreNeeded = false;
  Future<void> _queue = Future.value();

  void attach() {
    if (_disposed || _attached) return;
    addCloseListener(_onClose);
    _attached = true;
  }

  bool _onClose() {
    if (_disposed || !canPop()) return true;
    pop();
    return false;
  }

  Future<void> toggle() {
    if (_disposed) return _queue;
    _requestedFullscreen = !_requestedFullscreen;
    return _schedule();
  }

  Future<void> _schedule() =>
      _queue = _queue.then((_) => _reconcile()).catchError(onError);

  Future<void> _reconcile() async {
    final target = _requestedFullscreen;
    if (target == _fullscreen && !(_disposed && _restoreNeeded)) return;
    // A failed platform call can still have partially applied. On exit, issue
    // an explicit windowed request after every attempted fullscreen entry.
    if (target) _restoreNeeded = true;
    try {
      await hide();
      await setFullscreen(target);
      _fullscreen = target;
      if (!target) _restoreNeeded = false;
    } finally {
      try {
        await show();
      } finally {
        setFrameVisible(!_fullscreen);
      }
    }
  }

  Future<void> dispose() {
    if (_disposed) return _queue;
    _disposed = true;
    _requestedFullscreen = false;
    if (_attached) {
      removeCloseListener(_onClose);
      _attached = false;
    }
    return _schedule();
  }
}
