import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:photo_view/src/core/photo_view_core.dart';

class _Controller extends PhotoViewController {
  int listeners = 0;
  int disposals = 0;
  @override
  void addIgnorableListener(VoidCallback callback) {
    listeners++;
    super.addIgnorableListener(callback);
  }

  @override
  void removeIgnorableListener(VoidCallback callback) {
    listeners--;
    super.removeIgnorableListener(callback);
  }

  @override
  void dispose() {
    disposals++;
    super.dispose();
  }
}

class _ScaleController extends PhotoViewScaleStateController {
  int listeners = 0;
  int disposals = 0;
  @override
  void addIgnorableListener(VoidCallback callback) {
    listeners++;
    super.addIgnorableListener(callback);
  }

  @override
  void removeIgnorableListener(VoidCallback callback) {
    listeners--;
    super.removeIgnorableListener(callback);
  }

  @override
  void dispose() {
    disposals++;
    super.dispose();
  }
}

Widget _view({
  PhotoViewController? controller,
  PhotoViewScaleStateController? scale,
  ValueChanged<PhotoViewScaleState>? onScale,
  PhotoViewImageScaleEndCallback? onEnd,
}) =>
    MaterialApp(
      home: PhotoView.customChild(
        controller: controller,
        scaleStateController: scale,
        scaleStateChangedCallback: onScale,
        onScaleEnd: onEnd,
        childSize: const Size(400, 300),
        initialScale: 1.0,
        minScale: .5,
        maxScale: 4.0,
        enablePanAlways: true,
        child: const ColoredBox(color: Colors.blue),
      ),
    );

void main() {
  testWidgets('owned replacement waits for the old offstage subtree to unmount',
      (tester) async {
    final borrowed = _Controller();
    Widget host(bool hidden, PhotoViewController? controller) => MaterialApp(
            home: Offstage(
          offstage: hidden,
          child: PhotoView.customChild(
              controller: controller, child: const SizedBox()),
        ));
    await tester.pumpWidget(host(false, null));
    final old =
        tester.widget<PhotoViewCore>(find.byType(PhotoViewCore)).controller;
    var closed = false;
    old.outputStateStream.listen((_) {}, onDone: () => closed = true);
    await tester.pumpWidget(host(true, borrowed));
    await tester.pump();
    expect(closed, true);
    expect(borrowed.listeners, 1);
    borrowed.scale = 2;
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(borrowed.listeners, 0);
    expect(borrowed.disposals, 0);
    borrowed.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a newer gesture retires the delayed end of the previous one',
      (tester) async {
    final controller = _Controller();
    var ends = 0;
    await tester.pumpWidget(_view(
        controller: controller,
        onEnd: (context, details, value) {
          ends++;
          return false;
        }));
    await tester.pumpAndSettle();
    final first = await tester.startGesture(const Offset(300, 250));
    await first.moveBy(const Offset(70, 10));
    await tester.pump();
    controller.updateState!(null);
    await first.up();
    final second = await tester.startGesture(const Offset(300, 250));
    await second.moveBy(const Offset(80, 10));
    await tester.pump(const Duration(milliseconds: 250));
    expect(ends, 0);
    await second.up();
    await tester.pumpAndSettle();
    expect(ends, 1);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'gallery releases fallback and borrows replacement page controller',
      (tester) async {
    final borrowed = PageController();
    Widget gallery(PageController? controller) => MaterialApp(
            home: PhotoViewGallery.builder(
          pageController: controller,
          itemCount: 3,
          builder: (context, index) => PhotoViewGalleryPageOptions.customChild(
              child: Text('Page $index')),
        ));
    await tester.pumpWidget(gallery(null));
    final owned = tester.widget<PageView>(find.byType(PageView)).controller!;
    await tester.pumpWidget(gallery(borrowed));
    expect(tester.widget<PageView>(find.byType(PageView)).controller,
        same(borrowed));
    expect(() => owned.addListener(() {}), throwsFlutterError);
    await tester.pumpWidget(gallery(null));
    final current = tester.widget<PageView>(find.byType(PageView)).controller!;
    await tester.pumpWidget(const SizedBox());
    expect(() => current.addListener(() {}), throwsFlutterError);
    borrowed.addListener(() {});
    borrowed.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'disposing one view does not clear another view controller callbacks',
      (tester) async {
    final controller = _Controller();
    final first = GlobalKey();
    final second = GlobalKey();
    Widget host(bool both) => MaterialApp(
            home: Column(children: [
          if (both)
            Expanded(
                child: PhotoView.customChild(
                    key: first,
                    controller: controller,
                    child: const SizedBox())),
          Expanded(
              child: PhotoView.customChild(
                  key: second,
                  controller: controller,
                  child: const SizedBox())),
        ]));
    await tester.pumpWidget(host(true));
    await tester.pumpAndSettle();
    expect(controller.listeners, 2);
    await tester.pumpWidget(host(false));
    await tester.pumpAndSettle();
    expect(controller.listeners, 1);
    expect(controller.onDoubleClick, isNotNull);
    controller.onDoubleClick!();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    expect(controller.listeners, 0);
    expect(controller.onDoubleClick, isNull);
    controller.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('borrowed controllers lose listeners and callbacks on unmount', (
    tester,
  ) async {
    final controller = _Controller();
    final scale = _ScaleController();
    final reports = <PhotoViewScaleState>[];
    await tester.pumpWidget(
      _view(controller: controller, scale: scale, onScale: reports.add),
    );
    await tester.pumpAndSettle();
    expect(controller.listeners, 1);
    expect(scale.listeners, 1);
    await tester.pumpWidget(const SizedBox());
    reports.clear();
    expect(controller.listeners, 0);
    expect(scale.listeners, 0);
    expect(controller.disposals, 0);
    expect(scale.disposals, 0);
    expect(controller.onDoubleClick, isNull);
    expect(controller.animateScale, isNull);
    expect(controller.getInitialScale, isNull);
    controller.scale = 2;
    scale.scaleState = PhotoViewScaleState.covering;
    await tester.pump();
    expect(reports, isEmpty);
    expect(tester.takeException(), isNull);
    controller.dispose();
    scale.dispose();
  });

  testWidgets('replacement retires old callbacks and observes the new scale', (
    tester,
  ) async {
    final old = _Controller();
    final current = _Controller();
    final oldScale = _ScaleController();
    final currentScale = _ScaleController();
    final reports = <PhotoViewScaleState>[];
    await tester.pumpWidget(_view(controller: old, scale: oldScale));
    await tester.pumpAndSettle();
    final doubleClick = old.onDoubleClick!;
    final animateScale = old.animateScale!;
    final initialScale = old.getInitialScale!;
    await tester.pumpWidget(
      _view(controller: current, scale: currentScale, onScale: reports.add),
    );
    await tester.pumpAndSettle();
    reports.clear();
    doubleClick();
    animateScale(3);
    expect(initialScale(), isNull);
    old.scale = 2;
    oldScale.scaleState = PhotoViewScaleState.covering;
    await tester.pumpAndSettle();
    expect(reports, isEmpty);
    expect(current.scale, 1);
    expect(old.listeners, 0);
    expect(oldScale.listeners, 0);
    currentScale.scaleState = PhotoViewScaleState.zoomedIn;
    await tester.pumpAndSettle();
    expect(reports, contains(PhotoViewScaleState.zoomedIn));
    await tester.pumpWidget(const SizedBox());
    for (final c in [old, current]) {
      expect(c.disposals, 0);
      c.dispose();
    }
    for (final c in [oldScale, currentScale]) {
      expect(c.disposals, 0);
      c.dispose();
    }
    expect(tester.takeException(), isNull);
  });

  for (final replacePhoto in [false, true]) {
    testWidgets('owned replacement releases only retired objects $replacePhoto',
        (
      tester,
    ) async {
      final borrowed = _Controller();
      final borrowedScale = _ScaleController();
      await tester.pumpWidget(_view());
      await tester.pumpAndSettle();
      final first = tester.widget<PhotoViewCore>(find.byType(PhotoViewCore));
      var photoClosed = false;
      var scaleClosed = false;
      first.controller.outputStateStream
          .listen((_) {}, onDone: () => photoClosed = true);
      first.scaleStateController.outputScaleStateStream
          .listen((_) {}, onDone: () => scaleClosed = true);
      await tester.pumpWidget(
        _view(
          controller: replacePhoto ? borrowed : null,
          scale: replacePhoto ? null : borrowedScale,
        ),
      );
      await tester.pumpAndSettle();
      final next = tester.widget<PhotoViewCore>(find.byType(PhotoViewCore));
      expect(photoClosed, replacePhoto);
      expect(scaleClosed, !replacePhoto);
      if (replacePhoto) {
        expect(next.scaleStateController, same(first.scaleStateController));
      } else {
        expect(next.controller, same(first.controller));
      }
      await tester.pumpWidget(_view());
      await tester.pumpAndSettle();
      final last = tester.widget<PhotoViewCore>(find.byType(PhotoViewCore));
      var lastPhotoClosed = false;
      var lastScaleClosed = false;
      last.controller.outputStateStream
          .listen((_) {}, onDone: () => lastPhotoClosed = true);
      last.scaleStateController.outputScaleStateStream
          .listen((_) {}, onDone: () => lastScaleClosed = true);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(photoClosed && scaleClosed && lastPhotoClosed && lastScaleClosed,
          true);
      expect(borrowed.disposals, 0);
      expect(borrowedScale.disposals, 0);
      borrowed.dispose();
      borrowedScale.dispose();
      expect(tester.takeException(), isNull);
    });
  }

  for (final replace in [false, true]) {
    testWidgets(
        'delayed gesture completion retires on ${replace ? 'replacement' : 'unmount'}',
        (
      tester,
    ) async {
      final controller = _Controller();
      final next = _Controller();
      var ends = 0;
      await tester.pumpWidget(_view(
          controller: controller,
          onEnd: (context, details, value) {
            ends++;
            return false;
          }));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(const Offset(300, 250));
      await gesture.moveBy(const Offset(70, 10));
      await tester.pump();
      controller.updateState!(null);
      await gesture.up();
      expect(ends, 0);
      await tester
          .pumpWidget(replace ? _view(controller: next) : const SizedBox());
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(ends, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      next.dispose();
    });
  }
}
