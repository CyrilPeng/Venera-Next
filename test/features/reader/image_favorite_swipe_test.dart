import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/gesture_port.dart';
import 'package:venera_next/features/reader/image_favorite_swipe.dart';

class _Port implements ReaderGesturePort {
  final listeners = <ReaderDragListener>[];
  int added = 0;
  int removed = 0;
  @override
  void addDragListener(ReaderDragListener listener) {
    added++;
    listeners.add(listener);
  }

  @override
  void removeDragListener(ReaderDragListener listener) {
    removed++;
    listeners.remove(listener);
  }

  @override
  void ignoreNextTap() {}
  @override
  void clearIgnoreNextTap() {}
  @override
  void cancelPendingTap() {}
  void drag(Offset offset) {
    for (final listener in List.of(listeners)) {
      listener.onStart?.call(Offset.zero);
      listener.onMove?.call(offset);
      listener.onEnd?.call();
    }
  }
}

void main() {
  for (final vertical in [false, true]) {
    test(
      'collects across reading axis beyond the existing threshold; vertical=$vertical',
      () {
        final port = _Port();
        var collected = 0;
        final binding = ImageFavoriteSwipeBinding(
          isVertical: () => vertical,
          collect: () => collected++,
        );
        binding.setEnabled(true);
        binding.attach(port);
        port.drag(vertical ? const Offset(150, 500) : const Offset(500, 150));
        expect(collected, 0);
        port.drag(vertical ? const Offset(-151, 0) : const Offset(0, -151));
        expect(collected, 1);
        binding.dispose();
        expect(port.listeners, isEmpty);
      },
    );
  }
  test(
    'repeated settings and same-host attachment never duplicate subscriptions',
    () {
      final port = _Port();
      var collected = 0;
      final binding = ImageFavoriteSwipeBinding(
        isVertical: () => true,
        collect: () => collected++,
      );
      for (var i = 0; i < 3; i++) {
        binding.attach(port);
        binding.setEnabled(true);
      }
      expect(port.added, 1);
      port.drag(const Offset(200, 0));
      expect(collected, 1);
      binding.setEnabled(false);
      binding.setEnabled(false);
      expect(port.removed, 1);
      binding.setEnabled(true);
      expect(port.listeners, hasLength(1));
      binding.dispose();
    },
  );
  test(
    'host transfer clears partial distance and releases the previous host',
    () {
      final old = _Port();
      final next = _Port();
      var collected = 0;
      final binding = ImageFavoriteSwipeBinding(
        isVertical: () => true,
        collect: () => collected++,
      );
      binding.attach(old);
      binding.setEnabled(true);
      old.listeners.single.onMove!(const Offset(100, 0));
      binding.attach(next);
      expect(old.listeners, isEmpty);
      next.listeners.single.onMove!(const Offset(100, 0));
      next.listeners.single.onEnd!();
      expect(collected, 0);
      next.drag(const Offset(200, 0));
      expect(collected, 1);
      binding.attach(null);
      expect(next.listeners, isEmpty);
      binding.dispose();
    },
  );
  test(
    'disabling or disposal prevents an already captured callback from collecting',
    () {
      final port = _Port();
      var collected = 0;
      final binding = ImageFavoriteSwipeBinding(
        isVertical: () => true,
        collect: () => collected++,
      );
      binding.attach(port);
      binding.setEnabled(true);
      final listener = port.listeners.single;
      listener.onMove!(const Offset(200, 0));
      binding.setEnabled(false);
      listener.onEnd!();
      binding.setEnabled(true);
      binding.dispose();
      binding.dispose();
      listener.onMove!(const Offset(200, 0));
      listener.onEnd!();
      binding.attach(port);
      binding.setEnabled(true);
      expect(collected, 0);
      expect(port.listeners, isEmpty);
    },
  );
}
