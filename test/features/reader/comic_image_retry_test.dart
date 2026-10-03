import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/reader_tap_scope.dart';

class _FailedImage extends ImageProvider<_FailedImage> {
  int resolutions = 0;

  @override
  Future<_FailedImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    _FailedImage key,
    ImageErrorListener handleError,
  ) {
    resolutions++;
    stream.setCompleter(
      OneFrameImageStreamCompleter(
        Future<ImageInfo>.error(StateError('image failed')),
      ),
    );
  }
}

void main() {
  testWidgets('image retries without a reader or global gesture state', (
    tester,
  ) async {
    final image = _FailedImage();
    await tester.pumpWidget(MaterialApp(home: ComicImage(image: image)));
    await tester.pumpAndSettle();
    final before = image.resolutions;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(image.resolutions, greaterThan(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry targets the nearest reader and follows a replaced owner', (
    tester,
  ) async {
    var outer = 0;
    var first = 0;
    var second = 0;
    final ancestorObservations = <int>[];
    final image = _FailedImage();
    Future<void> show(VoidCallback callback) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderTapScope(
            ignoreNextTap: () => outer++,
            child: ReaderTapScope(
              ignoreNextTap: callback,
              child: Listener(
                onPointerDown: (_) => ancestorObservations.add(first + second),
                child: ComicImage(image: image),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show(() => first++);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(first, 1);
    expect(outer, 0);
    expect(ancestorObservations, [1]);
    await show(() => second++);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(first, 1);
    expect(second, 1);
    expect(outer, 0);
    expect(ancestorObservations, [1, 2]);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
