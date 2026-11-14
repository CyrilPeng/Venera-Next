import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/continuous_view.dart';
import 'package:venera_next/features/reader/display_image_provider.dart';
import 'package:venera_next/features/reader/image_export.dart';
import 'package:venera_next/features/reader/image_downloads.dart';
import 'package:venera_next/features/reader/gallery_view.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/features/reader/brightness.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/comic_layout.dart';
import 'package:venera_next/network/images.dart';

import 'support/reader_integration_fixture.dart';

void main() {
  final binding = setUpReaderIntegration();

  for (final detach in [false, true]) {
    testWidgets(
      'real reader dimming previews while saving and blocks ${detach ? 'window after removal' : 'back'}',
      (tester) async {
        final fixture = await ReaderIntegrationFixture.create(tester);
        final release = Completer<void>();
        Future<void>? exclusive;
        try {
          appdata.settings['readerBrightnessEnabled'] = true;
          appdata.settings['readerBrightness'] = 50;
          appdata.settings['disableSyncFields'] = '';
          await fixture.mount(tester, pushed: true);
          final reader = fixture.readerKey.currentState!;
          exclusive = AppDataOperations.instance.run(() => release.future);
          tester
              .widget<ReaderBrightnessControl>(
                find.byType(ReaderBrightnessControl),
              )
              .onBrightnessChanged(20);
          await tester.pump();
          expect(appdata.settings['readerBrightness'], 50);
          expect(
            tester
                .widget<ReaderBrightnessOverlay>(
                  find.byType(ReaderBrightnessOverlay),
                )
                .brightness,
            20,
          );
          if (detach) {
            appNavigation.rootNavigatorKey.currentState!.pop();
            await tester.pumpAndSettle();
            expect(fixture.readerKey.currentState, isNull);
            fixture.closeWindow(tester);
          } else {
            await appNavigation.rootNavigatorKey.currentState!.maybePop();
          }
          await tester.pump();
          expect(fixture.exits, 0);
          if (!detach) expect(fixture.readerKey.currentState, same(reader));
          release.complete();
          var saved = false;
          final saving = Future.wait([
            exclusive,
            appdata.saveData(false),
          ]).then((_) => saved = true);
          await pumpReaderUntil(tester, () => saved);
          await saving;
          await tester.pumpAndSettle();
          expect(appdata.settings['readerBrightness'], 20);
          expect(fixture.readerKey.currentState, isNull);
          expect(fixture.exits, detach ? 1 : 0);
          expect(tester.takeException(), isNull);
        } finally {
          if (!release.isCompleted) release.complete();
          if (exclusive != null) {
            var drained = false;
            final draining = Future.wait([
              exclusive,
              appdata.saveData(false),
            ]).then((_) => drained = true);
            await pumpReaderUntil(tester, () => drained);
            await draining;
          }
          await fixture.dispose(tester);
        }
      },
      skip: !Platform.isWindows,
    );
  }

  for (final nativeFrame in [false, true]) {
    for (final detachReader in [false, true]) {
      testWidgets(
        'visible PhotoView ${nativeFrame ? 'native frame' : 'file read'} blocks ${detachReader ? 'window exit after forced unmount' : 'reader back'}',
        (tester) async {
          final fixture = await ReaderIntegrationFixture.create(tester);
          final native = ReaderNativeFrameGate();
          final read = ReaderLocalReadGate(
            File('${LocalManager().path}/book/one/1.png'),
          );
          final previousIO = IOOverrides.current;
          try {
            appdata.settings['preloadImageCount'] = 0;
            if (nativeFrame) {
              binding.nativeGate = native;
            } else {
              IOOverrides.global = read;
            }
            await fixture.mount(tester, pushed: true, waitForImage: false);
            await pumpReaderUntil(
              tester,
              () => nativeFrame ? native.pendingFrames > 0 : read.reads > 0,
            );
            final reader = fixture.readerKey.currentState!;
            final originalWork = reader.imageWork;
            final gallery = tester.widget<ReaderGalleryView>(
              find.byType(ReaderGalleryView),
            );
            expect(gallery.imageWork, same(originalWork));
            final photoFinder = find.byWidgetPredicate(
              (widget) =>
                  widget is PhotoView &&
                  widget.imageProvider is ReaderDisplayImageProvider,
            );
            expect(photoFinder, findsWidgets);
            final photo = tester.widget<PhotoView>(photoFinder.first);
            expect(
              (photo.imageProvider! as ReaderDisplayImageProvider).work,
              same(originalWork),
            );
            final photoElement = tester.element(photoFinder.first);
            expect(readerPaintedImages(photoFinder.first), findsNothing);

            if (detachReader) {
              appNavigation.rootNavigatorKey.currentState!.removeRoute(
                ModalRoute.of(reader.context)!,
              );
              await tester.pumpAndSettle();
              expect(reader.mounted, isFalse);
              expect(photoElement.mounted, isFalse);
              fixture.closeWindow(tester);
            } else {
              unawaited(reader.requestExit());
            }
            await tester.pump(const Duration(seconds: 3));
            expect(originalWork.start(), isNull);
            expect(fixture.notifications, 0);
            expect(fixture.exits, 0);
            if (!detachReader) {
              expect(fixture.readerKey.currentState, same(reader));
              expect(tester.element(photoFinder.first), same(photoElement));
              expect(find.text('Saving...'), findsOneWidget);
              expect(readerPaintedImages(photoFinder.first), findsNothing);
            }
            if (nativeFrame) {
              expect(native.codecs, isNotEmpty);
              expect(
                native.codecs.every((codec) => codec.disposals == 0),
                isTrue,
              );
              expect(
                native.frames.every((frame) => !frame.image.debugDisposed),
                isTrue,
              );
            } else {
              expect(read.reads, 1);
              expect(read.completedReads, 0);
            }

            native.release();
            read.release();
            await pumpReaderUntil(tester, () => fixture.notifications > 0);
            await tester.pumpAndSettle();
            expect(fixture.readerKey.currentState, isNull);
            expect(find.text('Library home'), findsOneWidget);
            expect(fixture.exits, detachReader ? 1 : 0);
            expect(reader.imageWork, same(originalWork));
            if (nativeFrame) {
              expect(native.frames, isNotEmpty);
              expect(
                native.frames.every((frame) => frame.image.debugDisposed),
                isTrue,
              );
              expect(
                native.codecs.every((codec) => codec.disposals == 1),
                isTrue,
              );
            } else {
              expect(read.completedReads, 1);
            }
            expect(tester.takeException(), isNull);
          } finally {
            native.release();
            read.release();
            binding.nativeGate = null;
            IOOverrides.global = previousIO;
            await fixture.dispose(tester);
            binding.imageCache.clear();
            binding.imageCache.clearLiveImages();
            await tester.pump();
          }
        },
        skip: !Platform.isWindows,
      );
    }
  }

  for (final continuous in [false, true]) {
    testWidgets(
      'mounted ${continuous ? 'continuous ComicImage' : 'single PhotoView'} resumes after later window exit failure',
      (tester) async {
        final fixture = await ReaderIntegrationFixture.create(tester);
        final native = ReaderNativeFrameGate();
        final laterService = Completer<void>();
        var laterCalls = 0;
        try {
          appdata.settings['preloadImageCount'] = 0;
          if (continuous) {
            appdata.settings['readerMode'] =
                ReaderMode.continuousTopToBottom.key;
          }
          binding.nativeGate = native;
          await fixture.mount(
            tester,
            pushed: false,
            waitForImage: false,
            beforeReaderMount: (frame) => frame.addExitTask(() async {
              if (++laterCalls == 1) await laterService.future;
            }),
          );
          await pumpReaderUntil(tester, () => native.pendingFrames > 0);
          final reader = fixture.readerKey.currentState!;
          final originalWork = reader.imageWork;
          final consumerFinder = continuous
              ? find.byType(ComicImage).first
              : find
                    .byWidgetPredicate(
                      (widget) =>
                          widget is PhotoView &&
                          widget.imageProvider is ReaderDisplayImageProvider,
                    )
                    .first;
          final consumer = tester.element(consumerFinder);
          final provider = continuous
              ? tester.widget<ComicImage>(consumerFinder).image
              : tester.widget<PhotoView>(consumerFinder).imageProvider!;
          expect(
            (provider as ReaderDisplayImageProvider).work,
            same(originalWork),
          );
          if (continuous) {
            expect(
              tester
                  .widget<ReaderContinuousView>(
                    find.byType(ReaderContinuousView),
                  )
                  .imageWork,
              same(originalWork),
            );
          } else {
            expect(
              tester
                  .widget<ReaderGalleryView>(find.byType(ReaderGalleryView))
                  .imageWork,
              same(originalWork),
            );
          }
          expect(readerPaintedImages(consumerFinder), findsNothing);
          fixture.closeWindow(tester);
          await tester.pump(const Duration(seconds: 3));
          expect(laterCalls, 0);
          expect(fixture.notifications, 0);
          expect(fixture.exits, 0);
          expect(originalWork.start(), isNull);
          expect(tester.element(consumerFinder), same(consumer));

          // The original native request must drain before the later service.
          // No new request may start until that service's failure releases hold.
          binding.nativeGate = null;
          native.release();
          await pumpReaderUntil(tester, () => laterCalls == 1);
          expect(native.frames, isNotEmpty);
          expect(
            native.frames.every((frame) => frame.image.debugDisposed),
            isTrue,
          );
          expect(native.codecs.every((codec) => codec.disposals == 1), isTrue);
          expect(readerPaintedImages(consumerFinder), findsNothing);
          expect(tester.element(consumerFinder), same(consumer));
          expect(originalWork.start(), isNull);
          laterService.completeError(
            StateError('later visible reader failure'),
          );
          await tester.pump();
          expect(tester.takeException(), isA<StateError>());
          await pumpReaderUntil(
            tester,
            () => readerPaintedImages(consumerFinder).evaluate().isNotEmpty,
          );
          expect(fixture.readerKey.currentState, same(reader));
          expect(tester.element(consumerFinder), same(consumer));
          expect(reader.imageWork, same(originalWork));
          expect(fixture.exits, 0);
          expect(find.text('Closing...'), findsNothing);
          expect(readerPaintedImages(consumerFinder), findsWidgets);
          fixture.closeWindow(tester);
          await tester.pumpAndSettle();
          expect(laterCalls, 2);
          expect(fixture.exits, 1);
          expect(tester.takeException(), isNull);
        } finally {
          binding.nativeGate = null;
          native.release();
          if (!laterService.isCompleted) laterService.complete();
          await fixture.dispose(tester);
          binding.imageCache.clear();
          binding.imageCache.clearLiveImages();
          await tester.pump();
        }
      },
      skip: !Platform.isWindows,
    );
  }

  for (final detachReader in [false, true]) {
    testWidgets(
      'prefetch cleanup blocks ${detachReader ? 'window exit after forced unmount' : 'reader back'}',
      (tester) async {
        final fixture = await ReaderIntegrationFixture.create(tester);
        final release = Completer<void>();
        var cancelled = false;
        final source = StreamController<ImageDownloadProgress>(
          onCancel: () {
            cancelled = true;
            return release.future;
          },
        );
        ReaderImageDownloads? downloads;
        try {
          await fixture.mount(tester, pushed: true);
          final reader = fixture.readerKey.currentState!;
          expect(
            tester
                .widget<ReaderGalleryView>(find.byType(ReaderGalleryView))
                .imageWork,
            same(reader.imageWork),
          );
          downloads = ReaderImageDownloads(
            work: reader.imageWork,
            loader: (_, _, _, _) => source.stream,
          );
          downloads.preload('owned-prefetch', null, 'book', 'one');
          await tester.pump();
          if (detachReader) {
            appNavigation.rootNavigatorKey.currentState!.removeRoute(
              ModalRoute.of(reader.context)!,
            );
            await tester.pumpAndSettle();
            expect(reader.mounted, isFalse);
            fixture.closeWindow(tester);
          } else {
            unawaited(reader.requestExit());
          }
          await tester.pump(const Duration(seconds: 3));
          expect(cancelled, isTrue);
          expect(fixture.notifications, 0);
          expect(fixture.exits, 0);
          if (!detachReader) {
            expect(fixture.readerKey.currentState, same(reader));
          }
          release.complete();
          await tester.pumpAndSettle();
          expect(fixture.notifications, greaterThan(0));
          expect(fixture.exits, detachReader ? 1 : 0);
          expect(find.text('Library home'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          if (!release.isCompleted) release.complete();
          final disposing = downloads?.dispose();
          await tester.pump();
          // Drain controller futures outside fake async before the next widget
          // pump. A controller never listened to has no close event to await.
          await tester.runAsync(() async {
            await disposing;
            if (cancelled) {
              await source.close();
            } else {
              unawaited(source.close());
            }
          });
          await fixture.dispose(tester);
        }
      },
      skip: !Platform.isWindows,
    );
  }

  testWidgets(
    'reader back joins layout cleanup after its cancelled result has returned',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final probe = ReaderLayoutProbeGate();
      try {
        await fixture.mount(tester, pushed: true);
        final reader = fixture.readerKey.currentState!;
        reader.layoutProbe = probe;
        final originalLayout = appdata.settings.comicLayout('book', 'local');
        final originalMode = reader.mode;
        var resultReturned = false;
        final detecting = reader
            .detectLayout(force: true)
            .then((_) => resultReturned = true);
        expect(probe.started, isTrue);

        // Model the probe's bounded presentation result. Its real worker and
        // cancellation lifetime remains pending after this result returns.
        probe.cancel();
        await tester.pump();
        expect(resultReturned, isTrue);
        expect(reader.isDetectingLayout, isFalse);
        expect(reader.settingsSaves, 0);
        unawaited(reader.requestExit());
        await tester.pump(const Duration(seconds: 3));
        expect(fixture.readerKey.currentState, same(reader));
        expect(find.text('Saving...'), findsOneWidget);
        expect(fixture.notifications, 0);
        expect(fixture.exits, 0);
        expect(reader.mode, originalMode);
        expect(appdata.settings.comicLayout('book', 'local'), originalLayout);

        probe.finish();
        await tester.pumpAndSettle();
        await detecting;
        expect(fixture.readerKey.currentState, isNull);
        expect(find.text('Library home'), findsOneWidget);
        expect(fixture.notifications, greaterThan(0));
        expect(fixture.exits, 0);
        expect(reader.settingsSaves, 0);
        expect(tester.takeException(), isNull);
      } finally {
        probe.finish();
        await tester.pump();
        await fixture.dispose(tester);
      }
    },
    skip: !Platform.isWindows,
  );

  for (final detachReader in [false, true]) {
    testWidgets(
      'window waits for layout settings save ${detachReader ? 'handed off by an unmounted reader' : 'in its root reader'}',
      (tester) async {
        final fixture = await ReaderIntegrationFixture.create(tester);
        final probe = ReaderLayoutProbeGate();
        final saving = Completer<void>();
        try {
          await fixture.mount(tester, pushed: detachReader);
          final reader = fixture.readerKey.currentState!;
          reader.layoutProbe = probe;
          reader.onSaveSettings = () => saving.future;
          appdata.settings['autoReaderMode'] = true;
          appdata.settings['longStripReaderMode'] =
              ReaderMode.continuousTopToBottom.key;
          final originalMode = reader.mode;
          var resultReturned = false;
          final detecting = reader
              .detectLayout(force: true)
              .then((_) => resultReturned = true);
          probe.finish(ComicLayout.longStrip);
          await tester.pump();
          expect(reader.settingsSaves, 1);
          expect(resultReturned, isFalse);
          expect(reader.mode, originalMode);

          if (detachReader) {
            appNavigation.rootNavigatorKey.currentState!.removeRoute(
              ModalRoute.of(reader.context)!,
            );
            await tester.pumpAndSettle();
            expect(fixture.readerKey.currentState, isNull);
            expect(reader.mounted, isFalse);
          }
          fixture.closeWindow(tester);
          await tester.pump(const Duration(seconds: 3));
          expect(resultReturned, isTrue);
          expect(reader.imageWork.start(), isNull);
          expect(fixture.notifications, 0);
          expect(fixture.exits, 0);
          expect(find.text('Closing...'), findsOneWidget);
          if (detachReader) {
            expect(find.text('Library home'), findsOneWidget);
          } else {
            expect(fixture.readerKey.currentState, same(reader));
          }

          saving.complete();
          await tester.pumpAndSettle();
          await detecting;
          expect(fixture.notifications, 1);
          expect(fixture.exits, 1);
          expect(reader.settingsSaves, 1);
          expect(reader.mode, originalMode);
          expect(find.textContaining('Switched to'), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          probe.finish();
          if (!saving.isCompleted) saving.complete();
          await tester.pump();
          await fixture.dispose(tester);
        }
      },
      skip: !Platform.isWindows,
    );
  }

  for (final windowClose in [false, true]) {
    testWidgets(
      'reader ${windowClose ? 'window close' : 'back'} waits for a cancelled original image read',
      (tester) async {
        final fixture = await ReaderIntegrationFixture.create(tester);
        final rawRead = Completer<Uint8List>();
        ReaderImageExporter? exporter;
        try {
          await fixture.mount(tester, pushed: true);
          final reader = fixture.readerKey.currentState!;
          var reads = 0;
          var delivered = 0;
          final errors = <Object>[];
          exporter = readerFixtureExporter(
            reader,
            read: (_) {
              reads++;
              return rawRead.future;
            },
            save: (_) => delivered++,
            onError: (error, _) => errors.add(error),
          );
          final exporting = exporter.export(sharing: false);
          await tester.pump();
          expect(reads, 1);

          if (windowClose) {
            fixture.closeWindow(tester);
          } else {
            unawaited(reader.requestExit());
          }
          expect(reader.imageWork.start(), isNull);
          await tester.pump(const Duration(seconds: 3));
          expect(fixture.readerKey.currentState, same(reader));
          expect(find.text('Saving...'), findsOneWidget);
          expect(fixture.notifications, 0);
          expect(fixture.exits, 0);
          expect(delivered, 0);

          rawRead.complete(Uint8List.fromList([1, 2, 3]));
          await tester.pumpAndSettle();
          await exporting;
          expect(fixture.readerKey.currentState, isNull);
          expect(find.text('Library home'), findsOneWidget);
          expect(delivered, 0);
          expect(errors, isEmpty);
          // Route teardown can submit another progress revision after prepare.
          expect(fixture.notifications, greaterThan(0));
          expect(fixture.exits, 0);
          expect(tester.takeException(), isNull);
        } finally {
          if (!rawRead.isCompleted) rawRead.complete(Uint8List(0));
          await tester.pump();
          await exporter?.dispose();
          await fixture.dispose(tester);
        }
      },
      skip: !Platform.isWindows,
    );
  }
}
