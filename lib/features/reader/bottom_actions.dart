import 'package:flutter/material.dart';
import 'package:venera_next/foundation/translations.dart';
import 'platform_effects_controller.dart';
import 'image_favorite_controller.dart';

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
  required ReaderImageFavoriteStatus imageFavoriteStatus,
  required VoidCallback? onCollect,
  VoidCallback? onRetryImageStatus,
  bool imageCollecting = false,
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
    Semantics(
      toggled: switch (imageFavoriteStatus) {
        ReaderImageFavoriteStatus.collected => true,
        ReaderImageFavoriteStatus.uncollected => false,
        _ => null,
      },
      child: Tooltip(
        message: imageCollecting
            ? 'Saving image collection'.tl
            : switch (imageFavoriteStatus) {
                ReaderImageFavoriteStatus.loading =>
                  'Loading image collection'.tl,
                ReaderImageFavoriteStatus.failed =>
                  'Unable to load image collection. Retry'.tl,
                ReaderImageFavoriteStatus.collected => 'Uncollect the image'.tl,
                ReaderImageFavoriteStatus.selectImage =>
                  'Select an image to collect'.tl,
                _ => 'Collect the image'.tl,
              },
        child: IconButton(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon:
              imageCollecting ||
                  imageFavoriteStatus == ReaderImageFavoriteStatus.loading
              ? SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: MediaQuery.disableAnimationsOf(context) ? 0.5 : null,
                  ),
                )
              : Icon(switch (imageFavoriteStatus) {
                  ReaderImageFavoriteStatus.collected => Icons.favorite,
                  ReaderImageFavoriteStatus.failed => Icons.error_outline,
                  ReaderImageFavoriteStatus.selectImage =>
                    Icons.add_photo_alternate_outlined,
                  _ => Icons.favorite_border,
                }),
          onPressed: imageCollecting
              ? null
              : imageFavoriteStatus == ReaderImageFavoriteStatus.failed
              ? onRetryImageStatus
              : imageFavoriteStatus == ReaderImageFavoriteStatus.collected ||
                    imageFavoriteStatus ==
                        ReaderImageFavoriteStatus.uncollected ||
                    imageFavoriteStatus == ReaderImageFavoriteStatus.selectImage
              ? onCollect
              : null,
        ),
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
