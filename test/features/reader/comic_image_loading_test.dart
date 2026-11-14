import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/comic_image.dart';

class _ProgressStream extends ImageStreamCompleter {
  void progress(int bytes) => reportImageChunkEvent(
    ImageChunkEvent(cumulativeBytesLoaded: bytes, expectedTotalBytes: 1000),
  );

  void complete() {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(Colors.grey, ui.BlendMode.src);
    final picture = recorder.endRecording();
    setImage(ImageInfo(image: picture.toImageSync(20, 20)));
    picture.dispose();
  }

  void fail() => reportError(exception: StateError('controlled failure'));
}

class _Provider extends ImageProvider<_Provider> {
  final stream = _ProgressStream();

  @override
  Future<_Provider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    _Provider key,
    ImageErrorListener handleError,
  ) {
    stream.setCompleter(this.stream);
  }
}

Widget _host(_Provider image) => MaterialApp(home: ComicImage(image: image));

void main() {
  testWidgets(
    'bursty progress presents the latest value and cannot overwrite completion',
    (tester) async {
      final image = _Provider();
      await tester.pumpWidget(_host(image));
      for (var value = 10; value <= 800; value += 10) {
        image.stream.progress(value);
      }
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        0,
      );
      await tester.pump();
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        0.8,
      );
      image.stream.progress(900);
      image.stream.complete();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failure, replacement and disposal retire queued progress', (
    tester,
  ) async {
    final first = _Provider();
    final second = _Provider();
    await tester.pumpWidget(_host(first));
    first.stream.progress(800);
    first.stream.fail();
    await tester.pump();
    expect(find.textContaining('controlled failure'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.pumpWidget(_host(second));
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .value,
      0,
    );
    second.stream.progress(200);
    await tester.pump();
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .value,
      0.2,
    );
    second.stream.progress(400);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
