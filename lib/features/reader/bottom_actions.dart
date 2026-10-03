import 'package:flutter/material.dart';
import 'package:venera_next/foundation/translations.dart';
import 'orientation_controller.dart';

/// Snapshot of the automatic-reading action, independent of its controller.
class ReaderAutomaticReadingAction {
  const ReaderAutomaticReadingAction({
    required this.tooltip,
    required this.active,
    required this.playing,
    required this.onPressed,
  });
  final String tooltip;
  final bool active;
  final bool playing;
  final VoidCallback onPressed;
}

/// Presentation only. Optional callbacks express host/platform capabilities.
List<Widget> buildReaderBottomActions(
  BuildContext context, {
  required bool imageCollected,
  required VoidCallback onCollect,
  VoidCallback? onFullscreen,
  required ReaderOrientation orientation,
  VoidCallback? onRotate,
  required bool brightnessEnabled,
  required VoidCallback onBrightness,
  required ReaderAutomaticReadingAction automaticReading,
  VoidCallback? onChapters,
  required VoidCallback onSave,
  required VoidCallback onShare,
}) {
  return [
    Tooltip(
      message: "Collect the image".tl,
      child: IconButton(
        icon: Icon(imageCollected ? Icons.favorite : Icons.favorite_border),
        onPressed: onCollect,
      ),
    ),
    if (onFullscreen != null)
      Tooltip(
        message: "${"Full Screen".tl}(F12)",
        child: IconButton(
          icon: const Icon(Icons.fullscreen),
          onPressed: onFullscreen,
        ),
      ),
    if (onRotate != null)
      Tooltip(
        message: "Screen Rotation".tl,
        child: IconButton(
          icon: Icon(switch (orientation) {
            ReaderOrientation.system => Icons.screen_rotation,
            ReaderOrientation.portrait => Icons.screen_lock_portrait,
            ReaderOrientation.landscape => Icons.screen_lock_landscape,
          }),
          onPressed: onRotate,
        ),
      ),
    Tooltip(
      message: 'Reader brightness'.tl,
      child: IconButton(
        icon: Icon(brightnessEnabled ? Icons.brightness_4 : Icons.brightness_6),
        color: brightnessEnabled ? Theme.of(context).colorScheme.primary : null,
        onPressed: onBrightness,
      ),
    ),
    Tooltip(
      message: automaticReading.tooltip,
      child: IconButton(
        icon: Icon(
          automaticReading.playing
              ? Icons.pause_circle_outline
              : Icons.play_circle_outline,
        ),
        color: automaticReading.active
            ? Theme.of(context).colorScheme.primary
            : null,
        onPressed: automaticReading.onPressed,
      ),
    ),
    if (onChapters != null)
      Tooltip(
        message: "Chapters".tl,
        child: IconButton(
          icon: const Icon(Icons.library_books),
          onPressed: onChapters,
        ),
      ),
    Tooltip(
      message: "Save Image".tl,
      child: IconButton(icon: const Icon(Icons.download), onPressed: onSave),
    ),
    Tooltip(
      message: "Share".tl,
      child: IconButton(icon: const Icon(Icons.share), onPressed: onShare),
    ),
  ];
}
