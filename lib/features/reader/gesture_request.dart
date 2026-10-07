import 'package:flutter/foundation.dart' show Listenable;
import 'package:venera_next/foundation/reader_settings.dart';
import 'reader_viewport.dart';

/// Captured capabilities for one pointer sequence or context-menu request.
/// Widgets do not look up the reader again when a delayed action completes.
class ReaderGestureRequest {
  const ReaderGestureRequest({
    required this.identity,
    required this.isCurrent,
    bool Function()? isTargetCurrent,
    this.targetChanges,
    required this.viewport,
    required this.preferences,
    required this.vertical,
    required this.reversed,
    required this.onCommentsPage,
    required this.canUseImage,
    required this.turnPage,
    required this.turnWheel,
    required this.toggleAutomaticReading,
    required this.stopAutomaticReading,
    required this.acquirePause,
    required this.fullscreen,
    required this.exit,
  }) : isTargetCurrent = isTargetCurrent ?? isCurrent;
  final Object identity;
  final bool Function() isCurrent;

  /// Target validity while its own context menu covers the reader route.
  final bool Function() isTargetCurrent;

  /// Publications from the original target owner, in addition to UI changes.
  final Listenable? targetChanges;
  final ReaderImageViewController? viewport;
  final ReaderSettings preferences;
  final bool vertical, reversed, onCommentsPage, canUseImage;
  final void Function(bool forward) turnPage, turnWheel;
  final void Function() toggleAutomaticReading,
      stopAutomaticReading,
      fullscreen;
  final void Function() Function() acquirePause;
  final Future<void> Function() exit;
}
