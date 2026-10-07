import 'package:flutter/widgets.dart';

abstract interface class ReaderGesturePort {
  void ignoreNextTap();
  void clearIgnoreNextTap();
  void cancelPendingTap();
  void addDragListener(ReaderDragListener listener);
  void removeDragListener(ReaderDragListener listener);
}

class ReaderDragListener {
  ReaderDragListener({this.onMove, this.onEnd, this.onStart, this.onCancel});
  final void Function(Offset point)? onStart;
  final void Function(Offset offset)? onMove;
  final VoidCallback? onEnd;
  final VoidCallback? onCancel;
}
