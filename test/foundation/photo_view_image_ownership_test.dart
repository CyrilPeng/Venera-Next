import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';

class _Completer extends ImageStreamCompleter {
  void emit(ImageInfo image) => setImage(image);
}

class _Provider extends ImageProvider<_Provider> {
  final completer = _Completer();

  @override
  Future<_Provider> obtainKey(ImageConfiguration configuration) async => this;

  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    _Provider key,
    ImageErrorListener handleError,
  ) => stream.setCompleter(completer);
}

class _TrackedInfo extends ImageInfo {
  _TrackedInfo(ui.Image image) : super(image: image);

  final delivered = <ImageInfo>[];

  @override
  ImageInfo clone() {
    final copy = super.clone();
    delivered.add(copy);
    return copy;
  }
}

Future<ui.Image> _image() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const Color(0xff4488aa), ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(200, 100);
  } finally {
    picture.dispose();
  }
}

void main() {
  for (final cached in [false, true]) {
    testWidgets(
      'PhotoView releases each size-probe clone and all frames on unmount; cached=$cached',
      (tester) async {
        final created = <ui.Image>[];
        final previousOnCreate = ui.Image.onCreate;
        ui.Image.onCreate = (image) {
          created.add(image);
          previousOnCreate?.call(image);
        };
        final controller = PhotoViewController();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          controller.dispose();
          ui.Image.onCreate = previousOnCreate;
          // Also release leaked handles when this regression fails upstream.
          for (final image in created) {
            if (!image.debugDisposed) image.dispose();
          }
        });
        final firstImage = (await tester.runAsync(_image))!;
        final secondImage = (await tester.runAsync(_image))!;
        final first = _TrackedInfo(firstImage);
        final second = _TrackedInfo(secondImage);
        final provider = _Provider();
        if (cached) provider.completer.emit(first);
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 400,
                height: 300,
                child: PhotoView(
                  imageProvider: provider,
                  controller: controller,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
          ),
        );
        if (!cached) provider.completer.emit(first);
        await tester.pumpAndSettle();
        // The first clone only supplies ImageWrapper's dimensions. The second
        // belongs to PhotoViewImage and remains alive while it paints.
        expect(first.delivered, hasLength(2));
        expect(first.delivered.first.image.debugDisposed, isTrue);
        expect(first.delivered.last.image.debugDisposed, isFalse);
        expect(controller.getInitialScale!(), closeTo(2, 0.001));
        expect(tester.getSize(find.byType(RawImage)), const Size(400, 200));

        provider.completer.emit(second);
        expect(second.delivered, hasLength(2));
        expect(second.delivered.first.image.debugDisposed, isTrue);
        await tester.pumpAndSettle();
        expect(firstImage.debugGetOpenHandleStackTraces(), isEmpty);
        expect(second.delivered.last.image.debugDisposed, isFalse);
        controller.animateScale!(4);
        await tester.pumpAndSettle();
        expect(controller.scale, closeTo(4, 0.001));
        expect(tester.getSize(find.byType(RawImage)), const Size(800, 400));
        expect(controller.getInitialScale!(), closeTo(2, 0.001));

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(provider.completer.hasListeners, isFalse);
        expect(firstImage.debugGetOpenHandleStackTraces(), isEmpty);
        expect(secondImage.debugGetOpenHandleStackTraces(), isEmpty);
        expect(created.every((image) => image.debugDisposed), isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
