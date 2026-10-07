import 'package:flutter/services.dart';

import 'reader_controller.dart';
import 'image_picker.dart';

/// Owns the current viewport without retaining a reader State.
class ReaderViewportBinding {
  ReaderImageViewController? _current;
  bool _disposed = false;

  ReaderImageViewController? get current => _current;

  void update(ReaderImageViewController viewport, bool attached) {
    if (_disposed) return;
    if (attached) {
      _current = viewport;
    } else if (identical(_current, viewport)) {
      _current = null;
    }
  }

  void clear() => _current = null;

  void dispose() {
    _disposed = true;
    clear();
  }
}

abstract interface class ReaderImageViewController
    implements ReaderNavigationViewport, ReaderImagePickingViewport {
  void handleDoubleTap(Offset location);

  void handleLongPressDown(Offset location);

  void handleLongPressUp(Offset location);

  void handleKeyEvent(KeyEvent event);

  /// End held keys and repeat work when keyboard ownership leaves this view.
  void cancelKeyboardInput();

  /// Returns true if the event is handled.
  bool handleOnTap(Offset location);

  Future<Uint8List?> getImageByOffset(Offset offset);
}
