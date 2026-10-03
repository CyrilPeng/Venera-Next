import 'dart:ui';

/// The selection capabilities shared by gallery and continuous viewports.
abstract interface class ReaderImagePickingViewport {
  /// Zero-based, end-exclusive source images represented by the current page.
  (int start, int end)? get currentImageRange;
  String? getImageKeyByOffset(Offset offset);
}

class ReaderImagePickContext {
  const ReaderImagePickContext({
    required this.viewport,
    required this.images,
    required this.chapter,
  });

  final ReaderImagePickingViewport viewport;
  final List<String> images;
  final int chapter;

  bool matches(ReaderImagePickContext? other) =>
      other != null &&
      identical(viewport, other.viewport) &&
      identical(images, other.images) &&
      chapter == other.chapter;
}

class ReaderImagePick {
  const ReaderImagePick._(this.context, this.index);
  final ReaderImagePickContext context;
  final int index;

  bool isCurrent(ReaderImagePickContext? current) => context.matches(current);
}

/// Owns selection attempts; the shell supplies content and overlay adapters.
class ReaderImagePicker {
  ReaderImagePicker({required this.current, required this.selectPosition});

  final ReaderImagePickContext? Function() current;
  final Future<Offset?> Function() selectPosition;
  int _generation = 0;
  bool _disposed = false;

  Future<ReaderImagePick?> pick() async {
    if (_disposed) return null;
    final generation = ++_generation;
    final context = current();
    if (context == null || context.images.isEmpty) return null;
    final range = context.viewport.currentImageRange;
    if (range != null && range.$2 - range.$1 == 1) {
      return range.$1 >= 0 && range.$2 <= context.images.length
          ? ReaderImagePick._(context, range.$1)
          : null;
    }

    final position = await selectPosition();
    if (_disposed ||
        generation != _generation ||
        position == null ||
        !context.matches(current())) {
      return null;
    }
    final key = context.viewport.getImageKeyByOffset(position);
    final index = key == null ? -1 : context.images.indexOf(key);
    return index < 0 ? null : ReaderImagePick._(context, index);
  }

  void dispose() {
    _disposed = true;
    _generation++;
  }
}
