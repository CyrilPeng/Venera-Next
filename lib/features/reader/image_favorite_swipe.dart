import 'gesture_port.dart';

/// Owns exactly one cross-axis collection subscription for a reader shell.
class ImageFavoriteSwipeBinding {
  ImageFavoriteSwipeBinding({required this.isVertical, required this.collect});
  final bool Function() isVertical;
  final void Function() collect;
  ReaderGesturePort? _port;
  bool _enabled = false;
  bool _disposed = false;
  double _distance = 0;
  late final _listener = ReaderDragListener(
    onStart: (_) => _distance = 0,
    onMove: (offset) {
      if (_enabled && !_disposed) {
        _distance += isVertical() ? offset.dx : offset.dy;
      }
    },
    onEnd: () {
      final shouldCollect = _enabled && !_disposed && _distance.abs() > 150;
      _distance = 0;
      if (shouldCollect) collect();
    },
    onCancel: () => _distance = 0,
  );

  void attach(ReaderGesturePort? port) {
    if (_disposed || identical(port, _port)) return;
    if (_enabled) _port?.removeDragListener(_listener);
    _distance = 0;
    _port = port;
    if (_enabled) _port?.addDragListener(_listener);
  }

  void setEnabled(bool enabled) {
    if (_disposed || enabled == _enabled) return;
    _distance = 0;
    _enabled = enabled;
    if (enabled) {
      _port?.addDragListener(_listener);
    } else {
      _port?.removeDragListener(_listener);
    }
  }

  void dispose() {
    if (_disposed) return;
    if (_enabled) _port?.removeDragListener(_listener);
    _port = null;
    _distance = 0;
    _disposed = true;
  }
}
