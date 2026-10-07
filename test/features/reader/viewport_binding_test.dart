import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/reader_viewport.dart';

class _Viewport implements ReaderImageViewController {
  @override
  (int, int)? get currentImageRange => null;
  @override
  void toPage(int page) {}
  @override
  Future<void> animateToPage(int page) async {}
  @override
  bool toChapter(int chapter, {bool toLastPage = false}) => false;
  @override
  void handleDoubleTap(Offset location) {}
  @override
  void handleLongPressDown(Offset location) {}
  @override
  void handleLongPressUp(Offset location) {}
  @override
  void handleKeyEvent(KeyEvent event) {}
  @override
  void cancelKeyboardInput() {}
  @override
  bool handleOnTap(Offset location) => false;
  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async => null;
  @override
  int? getImageIndexByOffset(Offset offset) => null;
}

void main() {
  test('late detach cannot clear a replacement viewport', () {
    final binding = ReaderViewportBinding();
    final old = _Viewport();
    final current = _Viewport();
    binding.update(old, true);
    binding.update(current, true);
    binding.update(old, false);
    expect(binding.current, same(current));
    binding.update(current, false);
    expect(binding.current, isNull);
  });

  test('clear permits a new mode while disposal rejects late attachments', () {
    final binding = ReaderViewportBinding();
    final viewport = _Viewport();
    binding.update(viewport, true);
    binding.clear();
    expect(binding.current, isNull);
    binding.update(viewport, true);
    expect(binding.current, same(viewport));
    binding.dispose();
    binding.update(viewport, true);
    expect(binding.current, isNull);
    binding.update(viewport, false);
    binding.dispose();
    expect(binding.current, isNull);
  });
}
