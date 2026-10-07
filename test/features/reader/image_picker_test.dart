import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/image_picker.dart';

class _Viewport implements ReaderImagePickingViewport {
  @override
  (int, int)? currentImageRange;
  int? index;
  Offset? lastPosition;

  @override
  int? getImageIndexByOffset(Offset position) {
    lastPosition = position;
    return index;
  }
}

void main() {
  late _Viewport viewport;
  late ReaderImagePickContext? current;
  late ReaderImagePicker picker;
  late List<Completer<Offset?>> positions;
  setUp(() {
    viewport = _Viewport();
    current = ReaderImagePickContext(
      viewport: viewport,
      images: const ['a', 'b', 'c'],
      chapter: 1,
    );
    positions = [];
    picker = ReaderImagePicker(
      current: () => current,
      selectPosition: () {
        final position = Completer<Offset?>();
        positions.add(position);
        return position.future;
      },
    );
  });
  tearDown(() => picker.dispose());

  test('one visible source image is selected without an overlay', () async {
    viewport.currentImageRange = (1, 2);
    final result = await picker.pick();
    expect(result?.index, 1);
    expect(result?.isCurrent(current), isTrue);
    expect(positions, isEmpty);
    for (final range in [(-1, 0), (3, 4)]) {
      viewport.currentImageRange = range;
      expect(await picker.pick(), isNull);
    }
    expect(positions, isEmpty);
  });

  test('empty or detached content never opens selection', () async {
    current = ReaderImagePickContext(
      viewport: viewport,
      images: const [],
      chapter: 1,
    );
    expect(await picker.pick(), isNull);
    current = null;
    expect(await picker.pick(), isNull);
    expect(positions, isEmpty);
  });

  test(
    'multiple images use the viewport source index at the global position',
    () async {
      viewport.currentImageRange = (0, 2);
      viewport.index = 1;
      final result = picker.pick();
      positions.single.complete(const Offset(10, 20));
      expect((await result)?.index, 1);
      expect(viewport.lastPosition, const Offset(10, 20));
    },
  );

  test(
    'out-of-range index, absent hit and dismissed overlay produce no selection',
    () async {
      for (final index in [-1, 3, null]) {
        viewport.index = index;
        final result = picker.pick();
        positions.last.complete(Offset.zero);
        expect(await result, isNull);
      }
      final cancelled = picker.pick();
      positions.last.complete(null);
      expect(await cancelled, isNull);
    },
  );

  for (final change in ['viewport', 'images', 'chapter', 'unmount']) {
    test(
      '$change invalidates a pending selection before hit testing',
      () async {
        viewport.index = 0;
        final result = picker.pick();
        final original = current!;
        current = change == 'unmount'
            ? null
            : ReaderImagePickContext(
                viewport: change == 'viewport' ? _Viewport() : viewport,
                images: change == 'images'
                    ? List.of(original.images)
                    : original.images,
                chapter: change == 'chapter' ? 2 : 1,
              );
        positions.single.complete(Offset.zero);
        expect(await result, isNull);
        expect(viewport.lastPosition, isNull);
      },
    );
  }

  test(
    'new attempt owns the result even when the old overlay completes later',
    () async {
      viewport.index = 2;
      final old = picker.pick();
      final next = picker.pick();
      positions.last.complete(Offset.zero);
      expect((await next)?.index, 2);
      positions.first.complete(Offset.zero);
      expect(await old, isNull);
    },
  );

  test('disposal invalidates pending and future selections', () async {
    final pending = picker.pick();
    picker.dispose();
    positions.single.complete(Offset.zero);
    expect(await pending, isNull);
    expect(await picker.pick(), isNull);
    expect(positions, hasLength(1));
  });

  test(
    'consumer can reject an immediate result after an await boundary',
    () async {
      viewport.currentImageRange = (0, 1);
      final pending = picker.pick();
      current = ReaderImagePickContext(
        viewport: viewport,
        images: current!.images,
        chapter: 2,
      );
      final result = await pending;
      expect(result, isNotNull);
      expect(result!.isCurrent(current), isFalse);
    },
  );

  test('overlay failures propagate and a later attempt can retry', () async {
    final failed = picker.pick();
    final check = expectLater(failed, throwsStateError);
    positions.single.completeError(StateError('overlay unavailable'));
    await check;
    viewport.currentImageRange = (0, 1);
    expect((await picker.pick())?.index, 0);
  });
}
