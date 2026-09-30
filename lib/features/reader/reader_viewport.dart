import 'package:flutter/services.dart';

import 'reader_controller.dart';

abstract interface class ReaderImageViewController
    implements ReaderNavigationViewport {
  /// Zero-based, end-exclusive source images represented by the current page.
  (int start, int end)? get currentImageRange;

  void handleDoubleTap(Offset location);

  void handleLongPressDown(Offset location);

  void handleLongPressUp(Offset location);

  void handleKeyEvent(KeyEvent event);

  /// Returns true if the event is handled.
  bool handleOnTap(Offset location);

  Future<Uint8List?> getImageByOffset(Offset offset);

  String? getImageKeyByOffset(Offset offset);
}
