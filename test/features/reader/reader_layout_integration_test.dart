import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/continuous_view.dart';
import 'package:venera_next/features/reader/display_image_provider.dart';
import 'package:venera_next/features/reader/gallery_view.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/features/reader/top_bar.dart';
import 'package:venera_next/features/reader/scaffold.dart';
import 'package:venera_next/features/reader/images_host.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_layout.dart';

import 'support/reader_integration_fixture.dart';

void main() {
  setUpReaderIntegration();

  for (final mode in [
    ReaderMode.galleryLeftToRight,
    ReaderMode.galleryRightToLeft,
    ReaderMode.galleryTopToBottom,
  ]) {
    for (final landscapeImages in [1, 2]) {
      for (final duringAnimation in [false, true]) {
        testWidgets(
          'actual automatic gallery resumes after rotation: ${mode.key} spread=$landscapeImages animated=$duringAnimation',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = const Size(375, 667);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(tester.view.resetPhysicalSize);
            final fixture = await ReaderIntegrationFixture.create(
              tester,
              imageCount: 12,
            );
            try {
              appdata.settings['readerMode'] = mode.key;
              appdata.settings['readerScreenPicNumberForLandscape'] =
                  landscapeImages;
              appdata.settings['autoPageTurningInterval'] = 1;
              appdata.settings['enablePageAnimation'] = true;
              await fixture.mount(tester, pushed: false, withWindow: false);
              final reader = fixture.readerKey.currentState!;
              Future<void> expectAutomaticAdvance() async {
                await pumpReaderUntil(tester, () {
                  final viewport = reader.imageViewController;
                  return !reader.isPageAnimating &&
                      viewport is AutoReadingViewport &&
                      (viewport as AutoReadingViewport).autoReadingReady;
                });
                final before = reader.page;
                await pumpReaderUntil(
                  tester,
                  () => reader.page > before && !reader.isPageAnimating,
                );
                expect(reader.autoReading.isActive, isTrue);
              }

              reader.autoReading.start();
              if (duringAnimation) {
                await pumpReaderUntil(tester, () => reader.isPageAnimating);
              }
              tester.view.physicalSize = const Size(667, 375);
              await tester.pump();
              await expectAutomaticAdvance();
              tester.view.physicalSize = const Size(375, 667);
              await tester.pump();
              await expectAutomaticAdvance();
              expect(tester.takeException(), isNull);
            } finally {
              await fixture.dispose(tester);
            }
          },
        );
      }
    }
  }

  for (final layout in [ComicLayout.paged, ComicLayout.longStrip]) {
    for (final mode in ReaderMode.values) {
      testWidgets(
        'real image detection selects ${mode.key} for ${layout.name}',
        (tester) async {
          final fixture = await ReaderIntegrationFixture.create(
            tester,
            imageCount: 10,
            layout: layout,
          );
          try {
            final settings = appdata.settings;
            settings['comicLayoutDetections'] = <String, dynamic>{};
            settings['autoReaderMode'] = true;
            settings['readerMode'] = mode.isGallery
                ? ReaderMode.continuousTopToBottom.key
                : ReaderMode.galleryLeftToRight.key;
            settings['pagedReaderMode'] = mode.key;
            settings['longStripReaderMode'] = mode.key;
            settings['readerScreenPicNumberForLandscape'] = 2;
            settings['readerScreenPicNumberForPortrait'] = 2;
            settings['showSingleImageOnFirstPage'] = true;
            settings['enablePageAnimation'] = false;
            await fixture.mount(tester, pushed: false, initialPage: 4);
            final reader = fixture.readerKey.currentState!;
            await pumpReaderUntil(
              tester,
              () => !reader.isDetectingLayout && reader.mode == mode,
            );
            expect(
              reader.layoutProbe,
              isNull,
              reason: 'Use the production probe.',
            );
            expect(settings.comicLayout('book', 'local'), layout);
            expect(reader.settingsSaves, 1);
            expect(reader.chapter, 1);
            expect(reader.page, mode.isGallery ? 3 : 4);
            expect(reader.history!.page, 4);
            expect(reader.history!.maxPage, 10);
            expect(
              reader.imageViewController,
              mode.isGallery
                  ? isA<GalleryModeState>()
                  : isA<ContinuousModeState>(),
            );
            // Mode selection can finish before the new viewport decodes a frame.
            await pumpReaderUntil(
              tester,
              () => readerPaintedImages(
                find.byType(ReaderImagesHost),
              ).evaluate().isNotEmpty,
            );
            expect(
              readerPaintedImages(find.byType(ReaderImagesHost)),
              findsWidgets,
            );
            final saved = await tester.runAsync(
              () async => jsonDecode(
                await File(
                  '${fixture.directory.path}/appdata.json',
                ).readAsString(),
              ),
            );
            final detection =
                saved['settings']['comicLayoutDetections']['book@local'];
            expect(detection['layout'], layout.name);
            expect(detection['samples'], 6);
            expect(detection['version'], ComicLayoutDetection.version);
            expect(tester.takeException(), isNull);
          } finally {
            await fixture.dispose(tester);
          }
        },
      );
    }
  }

  for (final mode in [
    ReaderMode.continuousLeftToRight,
    ReaderMode.continuousRightToLeft,
  ]) {
    for (final largerNeighbor in [false, true]) {
      testWidgets(
        'a loading neighbor cannot displace a fully visible page in ${mode.key} (larger: $largerNeighbor)',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(800, 600));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final fixture = await ReaderIntegrationFixture.create(
            tester,
            imageCount: 10,
            layout: ComicLayout.longStrip,
          );
          final neighbor = File('${LocalManager().path}/book/one/8.png');
          if (largerNeighbor) {
            neighbor.writeAsBytesSync(
              img.encodePng(img.Image(width: 100, height: 100)),
            );
          }
          final read = ReaderLocalReadGate(neighbor);
          final previousIO = IOOverrides.current;
          try {
            appdata.settings['readerMode'] = mode.key;
            appdata.settings['preloadImageCount'] = 0;
            IOOverrides.global = read;
            await fixture.mount(
              tester,
              pushed: false,
              initialPage: 4,
              waitForImage: false,
            );
            final reader = fixture.readerKey.currentState!;
            final viewport = reader.imageViewController! as ContinuousModeState;
            bool decodedNeighbors() {
              final visible = viewport.imageStates
                  .whereType<ComicImageState>()
                  .where((image) => image.visibleInReader);
              return read.reads > 0 &&
                  visible.any(
                    (image) =>
                        (image.widget.image as ReaderDisplayImageProvider)
                                .image
                                .page ==
                            4 &&
                        image.readyForAutoReading,
                  ) &&
                  visible
                      .where(
                        (image) =>
                            (image.widget.image as ReaderDisplayImageProvider)
                                .image
                                .page !=
                            8,
                      )
                      .every((image) => image.readyForAutoReading);
            }

            await pumpReaderUntil(tester, decodedNeighbors);
            await tester.pump();
            expect(reader.page, 4);
            expect(reader.history!.page, 4);
            expect(read.completedReads, 0);
            read.release();
            await pumpReaderUntil(
              tester,
              () => viewport.imageStates
                  .whereType<ComicImageState>()
                  .where((image) => image.visibleInReader)
                  .every((image) => image.readyForAutoReading),
            );
            await tester.pump();
            expect(reader.page, largerNeighbor ? 8 : 4);
            expect(reader.history!.page, largerNeighbor ? 8 : 4);
            expect(tester.takeException(), isNull);
          } finally {
            read.release();
            IOOverrides.global = previousIO;
            await fixture.dispose(tester);
          }
        },
      );
    }
  }

  for (final visual in [
    (size: const Size(375, 667), dark: false, scale: 1.0),
    (size: const Size(375, 667), dark: true, scale: 2.0),
    (size: const Size(667, 375), dark: false, scale: 2.0),
    (size: const Size(667, 375), dark: true, scale: 1.0),
  ]) {
    testWidgets('reader top bar retains content through window insets $visual', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(visual.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = await ReaderIntegrationFixture.create(tester);
      final native = ReaderFixtureNativeWindow();
      try {
        await fixture.mount(
          tester,
          pushed: false,
          windowCoordinator: native.coordinator,
          textScale: visual.scale,
          reducedMotion: visual.scale > 1,
          brightness: visual.dark ? Brightness.dark : Brightness.light,
        );
        final scaffold = tester.state<ReaderScaffoldState>(
          find.byType(ReaderScaffold),
        );
        scaffold.openOrClose();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        fixture.readerKey.currentState!.fullscreen();
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 10));
          expect(tester.takeException(), isNull);
        }
        final top = find.byType(ReaderTopBar);
        expect(
          MediaQuery.textScalerOf(tester.element(top)).scale(16),
          16 * visual.scale,
        );
        final bar = tester.getRect(top);
        for (final label in ['Book', readerIntegrationChapters.titles.first]) {
          final text = find.descendant(of: top, matching: find.text(label));
          expect(text, findsOneWidget);
          final bounds = tester.getRect(text);
          expect(bounds.top, greaterThanOrEqualTo(bar.top));
          expect(bounds.bottom, lessThanOrEqualTo(bar.bottom));
        }
        final back = find.descendant(
          of: top,
          matching: find.byType(BackButton),
        );
        expect(tester.getSize(back).height, greaterThanOrEqualTo(44));
        final directory = Platform.environment['WINDOW_OWNER_QA_DIRECTORY'];
        if (directory != null) {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byType(RepaintBoundary).first,
            );
            final image = await boundary.toImage(pixelRatio: 1);
            try {
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$directory/reader-${visual.size.width.toInt()}-${visual.dark ? 'dark' : 'light'}-${visual.scale.toInt()}x.png',
              ).writeAsBytes(data!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        fixture.readerKey.currentState!.fullscreen();
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 10));
          expect(tester.takeException(), isNull);
        }
      } finally {
        await fixture.dispose(tester);
      }
    });
  }
}
