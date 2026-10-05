import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photo_view/photo_view.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/continuous_view.dart';
import 'package:venera_next/features/reader/display_image_provider.dart';
import 'package:venera_next/features/reader/orientation.dart';
import 'package:venera_next/features/reader/image_export.dart';
import 'package:venera_next/features/reader/image_downloads.dart';
import 'package:venera_next/features/reader/gallery_view.dart';
import 'package:venera_next/features/reader/layout_detection.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/features/reader/reader_session.dart';
import 'package:venera_next/features/reader/scaffold.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/comic_layout.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/images.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  final binding = _ReaderExitBinding();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (_) async => false,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  for (final detach in [false, true]) {
    testWidgets(
      'favorite write blocks ${detach ? 'window after forced unmount' : 'reader back'} until real completion',
      (tester) async {
        final fixture = await _ReaderFixture.create(tester);
        final pending = Completer<void>();
        final favorites = LocalFavoritesManager.cache! as _Favorites;
        favorites.reading = pending.future;
        try {
          await fixture.mount(tester, pushed: true);
          expect(favorites.reads, 1);
          if (detach) {
            App.rootNavigatorKey.currentState!.pop();
            await tester.pumpAndSettle();
            fixture.closeWindow(tester);
            await tester.pump();
            expect(fixture.exits, 0);
          } else {
            unawaited(App.rootNavigatorKey.currentState!.maybePop());
            await tester.pump(const Duration(milliseconds: 400));
            expect(fixture.readerKey.currentState, isNotNull);
          }
          pending.complete();
          await _pumpUntil(
            tester,
            () => detach
                ? fixture.exits == 1
                : fixture.readerKey.currentState == null,
          );
          expect(tester.takeException(), isNull);
        } finally {
          if (!pending.isCompleted) pending.complete();
          await fixture.dispose(tester);
        }
      },
    );
  }

  for (final nativeFrame in [false, true]) {
    for (final detachReader in [false, true]) {
      testWidgets(
        'visible PhotoView ${nativeFrame ? 'native frame' : 'file read'} blocks ${detachReader ? 'window exit after forced unmount' : 'reader back'}',
        (tester) async {
          final fixture = await _ReaderFixture.create(tester);
          final native = _NativeFrameGate();
          final read = _LocalReadGate(
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
            await _pumpUntil(
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
            expect(_paintedImages(photoFinder.first), findsNothing);

            if (detachReader) {
              App.rootNavigatorKey.currentState!.removeRoute(
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
              expect(_paintedImages(photoFinder.first), findsNothing);
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
            await _pumpUntil(tester, () => fixture.notifications > 0);
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
        final fixture = await _ReaderFixture.create(tester);
        final native = _NativeFrameGate();
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
          await _pumpUntil(tester, () => native.pendingFrames > 0);
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
          expect(_paintedImages(consumerFinder), findsNothing);
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
          await _pumpUntil(tester, () => laterCalls == 1);
          expect(native.frames, isNotEmpty);
          expect(
            native.frames.every((frame) => frame.image.debugDisposed),
            isTrue,
          );
          expect(native.codecs.every((codec) => codec.disposals == 1), isTrue);
          expect(_paintedImages(consumerFinder), findsNothing);
          expect(tester.element(consumerFinder), same(consumer));
          expect(originalWork.start(), isNull);
          laterService.completeError(
            StateError('later visible reader failure'),
          );
          await tester.pump();
          expect(tester.takeException(), isA<StateError>());
          await _pumpUntil(
            tester,
            () => _paintedImages(consumerFinder).evaluate().isNotEmpty,
          );
          expect(fixture.readerKey.currentState, same(reader));
          expect(tester.element(consumerFinder), same(consumer));
          expect(reader.imageWork, same(originalWork));
          expect(fixture.exits, 0);
          expect(find.text('Closing...'), findsNothing);
          expect(_paintedImages(consumerFinder), findsWidgets);
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
        final fixture = await _ReaderFixture.create(tester);
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
            App.rootNavigatorKey.currentState!.removeRoute(
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
      final fixture = await _ReaderFixture.create(tester);
      final probe = _LayoutProbeGate();
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
        final fixture = await _ReaderFixture.create(tester);
        final probe = _LayoutProbeGate();
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
            App.rootNavigatorKey.currentState!.removeRoute(
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
        final fixture = await _ReaderFixture.create(tester);
        final rawRead = Completer<Uint8List>();
        ReaderImageExporter? exporter;
        try {
          await fixture.mount(tester, pushed: true);
          final reader = fixture.readerKey.currentState!;
          var reads = 0;
          var delivered = 0;
          final errors = <Object>[];
          exporter = _exporter(
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

  testWidgets(
    'root reader waits for platform delivery and admits new exports after later exit failure',
    (tester) async {
      final fixture = await _ReaderFixture.create(tester);
      final platform = Completer<void>();
      ReaderImageExporter? exporter;
      var laterCalls = 0;
      try {
        await fixture.mount(
          tester,
          pushed: false,
          beforeReaderMount: (frame) => frame.addExitTask(() async {
            if (++laterCalls == 1) throw StateError('later service failure');
          }),
        );
        final reader = fixture.readerKey.currentState!;
        var deliveries = 0;
        final errors = <Object>[];
        exporter = _exporter(
          reader,
          save: (_) async {
            if (++deliveries == 1) await platform.future;
          },
          onError: (error, _) => errors.add(error),
        );
        final exporting = exporter.export(sharing: false);
        await tester.pump();
        expect(deliveries, 1);
        fixture.closeWindow(tester);
        expect(reader.imageWork.start(), isNull);
        await tester.pump(const Duration(seconds: 3));
        expect(laterCalls, 0);
        expect(fixture.notifications, 0);
        expect(fixture.exits, 0);
        expect(fixture.readerKey.currentState, same(reader));

        platform.complete();
        await tester.pump();
        await exporting;
        expect(tester.takeException(), isA<StateError>());
        expect(laterCalls, 1);
        expect(fixture.exits, 0);
        expect(fixture.readerKey.currentState, same(reader));
        final admitted = reader.imageWork.start();
        expect(admitted, isNotNull);
        admitted!.finish();

        final retry = exporter.export(sharing: false);
        await tester.pump();
        await retry;
        expect(deliveries, 2);
        expect(errors, isEmpty);
        fixture.closeWindow(tester);
        await tester.pumpAndSettle();
        expect(laterCalls, 2);
        expect(fixture.exits, 1);
        expect(tester.takeException(), isNull);
      } finally {
        if (!platform.isCompleted) platform.complete();
        await tester.pump();
        await exporter?.dispose();
        await fixture.dispose(tester);
      }
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'disposed reader retains pending platform delivery until final host exit',
    (tester) async {
      final fixture = await _ReaderFixture.create(tester);
      final platform = Completer<void>();
      ReaderImageExporter? exporter;
      try {
        await fixture.mount(tester, pushed: true);
        final reader = fixture.readerKey.currentState!;
        var deliveries = 0;
        exporter = _exporter(
          reader,
          save: (_) {
            deliveries++;
            return platform.future;
          },
        );
        final exporting = exporter.export(sharing: false);
        await tester.pump();
        expect(deliveries, 1);

        App.rootNavigatorKey.currentState!.removeRoute(
          ModalRoute.of(reader.context)!,
        );
        await tester.pumpAndSettle();
        expect(fixture.readerKey.currentState, isNull);
        expect(reader.mounted, isFalse);
        expect(reader.imageWork.start(), isNull);
        fixture.closeWindow(tester);
        await tester.pump(const Duration(seconds: 3));
        expect(find.text('Library home'), findsOneWidget);
        expect(fixture.notifications, 0);
        expect(fixture.exits, 0);

        platform.complete();
        await tester.pumpAndSettle();
        await exporting;
        expect(fixture.notifications, 1);
        expect(fixture.exits, 1);
        expect(tester.takeException(), isNull);
      } finally {
        if (!platform.isCompleted) platform.complete();
        await tester.pump();
        await exporter?.dispose();
        await fixture.dispose(tester);
      }
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'reader toolbar retains a failed save, then saves newer progress before pop',
    (tester) async {
      final fixture = await _ReaderFixture.create(tester);
      try {
        await fixture.mount(tester, pushed: true);
        final reader = fixture.readerKey.currentState!;
        final saving = Completer<void>();
        fixture.history.onProgress = (_) => saving.future;
        reader.setPage(2);
        tester
            .state<ReaderScaffoldState>(find.byType(ReaderScaffold))
            .openOrClose();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(find.byType(BackButton));
        await tester.pump();
        expect(find.text('Saving...'), findsOneWidget);
        expect(fixture.readerKey.currentState, same(reader));
        expect(App.rootNavigatorKey.currentState!.canPop(), isTrue);
        expect(fixture.history.progress.last.page, 2);
        saving.completeError(StateError('progress disk failure'));
        await tester.pumpAndSettle();
        expect(fixture.readerKey.currentState, same(reader));
        expect(find.text('Saving...'), findsNothing);
        expect(find.text('Unable to close. Please try again.'), findsOneWidget);

        fixture.history.onProgress = null;
        reader.setPage(3);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(fixture.readerKey.currentState, isNull);
        expect(find.text('Library home'), findsOneWidget);
        expect(fixture.history.progress.last.page, 3);
        expect(fixture.exits, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'native window close waits for the current reader save before leaving its route',
    (tester) async {
      final fixture = await _ReaderFixture.create(tester);
      try {
        await fixture.mount(tester, pushed: true);
        final reader = fixture.readerKey.currentState!;
        final saving = Completer<void>();
        fixture.history.onProgress = (_) => saving.future;
        reader.setPage(2);
        fixture.closeWindow(tester);
        fixture.closeWindow(tester);
        await tester.pump();
        expect(find.text('Saving...'), findsOneWidget);
        expect(find.text('Closing...'), findsNothing);
        expect(fixture.readerKey.currentState, same(reader));
        expect(fixture.exits, 0);
        final acceptedWrites = fixture.history.progress.length;
        await tester.pump(const Duration(seconds: 3));
        expect(fixture.history.progress.length, acceptedWrites);
        expect(fixture.readerKey.currentState, same(reader));
        saving.complete();
        await tester.pumpAndSettle();
        expect(fixture.readerKey.currentState, isNull);
        expect(find.text('Library home'), findsOneWidget);
        expect(fixture.history.progress.last.page, 2);
        expect(fixture.exits, 0);
        fixture.closeWindow(tester);
        await tester.pumpAndSettle();
        expect(fixture.exits, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'reader offers explicit leave after an uncertain duration save without replaying it',
    (tester) async {
      final fixture = await _ReaderFixture.create(tester);
      try {
        await fixture.mount(tester, pushed: true);
        final reader = fixture.readerKey.currentState!;
        var failedAttempts = 0;
        Duration? uncertainDuration;
        fixture.history.onDuration = (duration) async {
          uncertainDuration ??= duration;
          if (identical(duration, uncertainDuration)) {
            failedAttempts++;
            throw StateError('duration result is unknown');
          }
        };
        final exiting = reader.requestExit();
        await tester.pumpAndSettle();
        await exiting;
        expect(fixture.readerKey.currentState, same(reader));
        expect(find.text('Leave without saving'), findsOneWidget);
        expect(failedAttempts, 1);
        // Further reading can be persisted, but the uncertain earlier segment
        // remains observable and must never be replayed during final disposal.
        await tester.tap(find.text('Leave without saving'));
        await tester.pumpAndSettle();
        expect(fixture.readerKey.currentState, isNull);
        expect(find.text('Library home'), findsOneWidget);
        expect(failedAttempts, 1);
        expect(tester.takeException(), isA<ReaderSessionFailure>());
        expect(fixture.exits, 0);
      } finally {
        await fixture.dispose(tester);
      }
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'root reader freezes before old saves drain and resumes after a later exit failure',
    (tester) async {
      final fixture = await _ReaderFixture.create(tester);
      final oldSave = Completer<void>();
      var laterCalls = 0;
      try {
        await fixture.mount(
          tester,
          pushed: false,
          beforeReaderMount: (frame) => frame.addExitTask(() async {
            laterCalls++;
            if (laterCalls == 1) throw StateError('later service failure');
          }),
        );
        final reader = fixture.readerKey.currentState!;
        expect(App.rootNavigatorKey.currentState!.canPop(), isFalse);
        reader.setPage(2);
        reader.autoReading.start();
        final durationWrites = fixture.history.durations.length;
        fixture.frame.trackExitTask(oldSave.future);
        fixture.closeWindow(tester);
        // The real session receives the synchronous window notification even
        // though a previously detached owner's save blocks its exit task.
        expect(reader.autoReading.status, AutoReadingStatus.paused);
        await tester.pump();
        expect(fixture.history.durations.length, durationWrites + 1);
        expect(laterCalls, 0);
        expect(fixture.notifications, 0);
        await tester.pump(const Duration(minutes: 3));
        expect(fixture.history.durations.length, durationWrites + 1);
        expect(reader.page, 2);
        expect(fixture.exits, 0);

        oldSave.complete();
        await tester.pump();
        expect(tester.takeException(), isA<StateError>());
        expect(laterCalls, 1);
        expect(fixture.notifications, 1);
        expect(fixture.history.progress.last.page, 2);
        expect(fixture.readerKey.currentState, same(reader));
        expect(
          reader.autoReading.status,
          isIn([AutoReadingStatus.running, AutoReadingStatus.waiting]),
        );
        expect(find.text('Closing...'), findsNothing);

        reader.autoReading.stop();
        reader.setPage(3);
        fixture.closeWindow(tester);
        await tester.pumpAndSettle();
        expect(fixture.history.progress.last.page, 3);
        expect(fixture.notifications, 2);
        expect(laterCalls, 2);
        expect(fixture.exits, 1);
        expect(tester.takeException(), isNull);
      } finally {
        if (!oldSave.isCompleted) oldSave.complete();
        await fixture.dispose(tester);
      }
    },
    skip: !Platform.isWindows,
  );

  for (final failLateSave in [false, true]) {
    testWidgets(
      'root reader drains progress arriving after its exit task; late failure=$failLateSave',
      (tester) async {
        final fixture = await _ReaderFixture.create(tester);
        final laterService = Completer<void>();
        final firstLateSave = Completer<void>();
        final lastLateSave = Completer<void>();
        var laterCalls = 0;
        try {
          await fixture.mount(
            tester,
            pushed: false,
            beforeReaderMount: (frame) => frame.addExitTask(() {
              laterCalls++;
              return laterService.future;
            }),
          );
          final reader = fixture.readerKey.currentState!;
          reader.autoReading.start();
          fixture.closeWindow(tester);
          await tester.pump();
          expect(laterCalls, 1);
          expect(fixture.notifications, 1);
          expect(reader.autoReading.status, AutoReadingStatus.paused);
          fixture.history.onProgress = (snapshot) => switch (snapshot.page) {
            2 => firstLateSave.future,
            3 => lastLateSave.future,
            _ => Future.value(),
          };

          // A completed reader preparation must acquire another hold and
          // immediately drain this late snapshot while another owner waits.
          reader.setPage(2);
          await tester.pump();
          expect(fixture.history.progress.last.page, 2);
          expect(fixture.notifications, 1);
          expect(fixture.exits, 0);
          firstLateSave.complete();
          await tester.pump();
          expect(fixture.notifications, 2);
          expect(reader.autoReading.status, AutoReadingStatus.paused);

          // Keep both successful preparation holds alive while a third drain
          // is pending; recovery must release every one of them on failure.
          reader.setPage(3);
          await tester.pump();
          expect(fixture.history.progress.last.page, 3);
          laterService.complete();
          await tester.pump(const Duration(seconds: 3));
          expect(laterCalls, 1);
          expect(fixture.exits, 0);
          expect(reader.autoReading.status, AutoReadingStatus.paused);
          expect(find.text('Closing...'), findsOneWidget);
          expect(tester.takeException(), isNull);

          if (failLateSave) {
            lastLateSave.completeError(StateError('late progress failure'));
          } else {
            lastLateSave.complete();
          }
          await tester.pump();
          expect(fixture.notifications, 3);
          if (failLateSave) {
            expect(tester.takeException(), isA<ReaderSessionFailure>());
            expect(fixture.exits, 0);
            expect(fixture.readerKey.currentState, same(reader));
            expect(find.text('Closing...'), findsNothing);
            expect(
              reader.autoReading.status,
              isIn([AutoReadingStatus.running, AutoReadingStatus.waiting]),
            );
            reader.autoReading.stop();
            fixture.history.onProgress = null;
            reader.setPage(1);
            fixture.closeWindow(tester);
            await tester.pumpAndSettle();
            expect(fixture.history.progress.last.page, 1);
            expect(laterCalls, 2);
            expect(fixture.exits, 1);
          } else {
            expect(fixture.exits, 1);
          }
          expect(tester.takeException(), isNull);
        } finally {
          if (!laterService.isCompleted) laterService.complete();
          if (!firstLateSave.isCompleted) firstLateSave.complete();
          if (!lastLateSave.isCompleted) lastLateSave.complete();
          await fixture.dispose(tester);
        }
      },
      skip: !Platform.isWindows,
    );
  }
}

const _chapters = ComicChapters({'one': 'One'});

Finder _paintedImages(Finder consumer) => find.descendant(
  of: consumer,
  matching: find.byWidgetPredicate(
    (widget) => widget is RawImage && widget.image != null,
  ),
);

Future<void> _pumpUntil(WidgetTester tester, bool Function() finished) async {
  for (var attempt = 0; attempt < 100 && !finished(); attempt++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(finished(), isTrue, reason: 'Reader work did not reach its gate');
}

/// Flutter's decoder remains real; only completion of its native frame future
/// is controlled. No reader, host, provider, stream or image-work wiring is
/// replaced, and tests without a gate use the normal binding unchanged.
class _ReaderExitBinding extends AutomatedTestWidgetsFlutterBinding {
  _NativeFrameGate? nativeGate;

  @override
  Future<ui.Codec> instantiateImageCodecWithSize(
    ui.ImmutableBuffer buffer, {
    ui.TargetImageSizeCallback? getTargetSize,
  }) async {
    final gate = nativeGate;
    final codec = await super.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: getTargetSize,
    );
    return gate?.wrap(codec) ?? codec;
  }
}

class _NativeFrameGate {
  final _released = Completer<void>();
  final codecs = <_GatedNativeCodec>[];
  final frames = <ui.FrameInfo>[];
  int pendingFrames = 0;

  ui.Codec wrap(ui.Codec codec) {
    final owned = _GatedNativeCodec(codec, this);
    codecs.add(owned);
    return owned;
  }

  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}

class _GatedNativeCodec implements ui.Codec {
  _GatedNativeCodec(this.raw, this.gate);
  final ui.Codec raw;
  final _NativeFrameGate gate;
  int disposals = 0;

  @override
  int get frameCount => raw.frameCount;
  @override
  int get repetitionCount => raw.repetitionCount;

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    final frame = await raw.getNextFrame();
    gate.frames.add(frame);
    gate.pendingFrames++;
    await gate._released.future;
    gate.pendingFrames--;
    return frame;
  }

  @override
  void dispose() {
    disposals++;
    raw.dispose();
  }
}

/// Override only one fixture file. ReaderImageProvider's exists/length/read,
/// cancellation checks, native decoder and cache lifecycle still execute.
final class _LocalReadGate extends IOOverrides {
  _LocalReadGate(File file) : file = _GatedReadFile(file);
  final _GatedReadFile file;
  int get reads => file.reads;
  int get completedReads => file.completedReads;

  @override
  File createFile(String path) =>
      path.replaceAll('\\', '/') == file.path.replaceAll('\\', '/')
      ? file
      : super.createFile(path);

  void release() => file.release();
}

class _GatedReadFile implements File {
  _GatedReadFile(this.raw);
  final File raw;
  final _released = Completer<void>();
  int reads = 0;
  int completedReads = 0;
  @override
  String get path => raw.path;
  @override
  Future<bool> exists() => raw.exists();
  @override
  bool existsSync() => raw.existsSync();
  @override
  Future<int> length() => raw.length();
  @override
  int lengthSync() => raw.lengthSync();

  @override
  Future<Uint8List> readAsBytes() async {
    reads++;
    final bytes = await raw.readAsBytes();
    await _released.future;
    completedReads++;
    return bytes;
  }

  void release() {
    if (!_released.isCompleted) _released.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ReaderImageExporter _exporter(
  ReaderState reader, {
  Future<Uint8List> Function(ReaderImageSelection)? read,
  required FutureOr<void> Function(ReaderImageExport) save,
  void Function(Object, StackTrace)? onError,
}) => ReaderImageExporter(
  work: reader.imageWork,
  select: () async => const ReaderImageSelection(
    imageKey: '1.png',
    sourceKey: 'local',
    comicId: 'book',
    chapterId: 'one',
    title: 'Book',
    chapter: 1,
    imageNumber: 1,
  ),
  read: read ?? (_) async => img.encodePng(img.Image(width: 1, height: 1)),
  save: save,
  share: save,
  onError: onError ?? (error, _) => fail('Unexpected export failure: $error'),
);

class _ReaderFixture {
  _ReaderFixture()
    : previousSettings = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map,
      ),
      previousFavorites = LocalFavoritesManager.cache,
      previousHistory = HistoryManager.cache,
      previousLogMuted = Log.isMuted;

  final Map<String, dynamic> previousSettings;
  final LocalFavoritesManager? previousFavorites;
  final HistoryManager? previousHistory;
  final bool previousLogMuted;
  final history = _ControlledHistory();
  final readerKey = GlobalKey<_TestReaderState>();
  late final Directory directory;
  late WindowFrameController frame;
  int exits = 0;
  int notifications = 0;

  static Future<_ReaderFixture> create(WidgetTester tester) async {
    final fixture = _ReaderFixture();
    fixture.directory = Directory.systemTemp.createTempSync('reader-exit-');
    App.dataPath = fixture.directory.path;
    App.cachePath = fixture.directory.path;
    Log.isMuted = true;
    HistoryManager.cache = fixture.history;
    LocalFavoritesManager.cache = _Favorites();
    final settings = appdata.settings;
    settings['comicSpecificSettings'] = <String, dynamic>{};
    settings['deviceSpecificSettings'] = <String, dynamic>{};
    settings['autoReaderMode'] = false;
    settings['readerMode'] = ReaderMode.galleryLeftToRight.key;
    settings['readerScreenPicNumberForLandscape'] = 1;
    settings['readerScreenPicNumberForPortrait'] = 1;
    settings['autoPageTurningInterval'] = 60;
    settings['autoReadingAcrossChapters'] = false;
    settings['enableClockAndBatteryInfoInReader'] = false;
    settings['showPageNumberInReader'] = false;
    settings['eInkMode'] = false;
    settings['language'] = 'en-US';
    LocalManager.resetForTesting();
    LocalManager.debugSkipComicSourceInit = true;
    await tester.runAsync(() async {
      final root = fixture.directory.path;
      Directory('$root/comics').createSync();
      File('$root/local_path').writeAsStringSync('$root/comics');
      await fixture.history.init();
      await LocalManager().init();
      final png = img.encodePng(img.Image(width: 100, height: 150));
      final folder = Directory('${LocalManager().path}/book/one')
        ..createSync(recursive: true);
      for (var page = 1; page <= 3; page++) {
        File('${folder.path}/$page.png').writeAsBytesSync(png);
      }
      await LocalManager().add(
        LocalComic(
          id: 'book',
          title: 'Book',
          subtitle: '',
          tags: const [],
          directory: 'book',
          chapters: _chapters,
          cover: '',
          comicType: ComicType.local,
          downloadedChapters: const ['one'],
          createdAt: DateTime(2026),
        ),
      );
    });
    return fixture;
  }

  Future<void> mount(
    WidgetTester tester, {
    required bool pushed,
    bool waitForImage = true,
    void Function(WindowFrameController)? beforeReaderMount,
  }) async {
    var registered = false;
    Widget reader() => Scaffold(
      body: _TestReader(key: readerKey, onClosed: () => notifications++),
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        builder: (_, child) => WindowFrame(
          Builder(
            builder: (context) {
              frame = WindowFrame.of(context);
              if (!registered) {
                registered = true;
                beforeReaderMount?.call(frame);
              }
              return ReaderOrientationScope(child: OverlayWidget(child!));
            },
          ),
          onExit: () => exits++,
        ),
        home: pushed ? const Scaffold(body: Text('Library home')) : reader(),
      ),
    );
    if (pushed) {
      unawaited(
        App.rootNavigatorKey.currentState!.push<void>(
          MaterialPageRoute(builder: (_) => reader()),
        ),
      );
    }
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      final current = readerKey.currentState;
      if (!waitForImage &&
          current?.imageViewController is AutoReadingViewport &&
          current?.isLoading == false) {
        break;
      }
      if (current?.imageViewController case AutoReadingViewport viewport
          when viewport.autoReadingReady && !current!.isLoading) {
        break;
      }
    }
    expect(readerKey.currentState?.images, hasLength(3));
    expect(readerKey.currentState?.isLoading, isFalse);
    expect(
      readerKey.currentState?.imageViewController,
      isA<AutoReadingViewport>(),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  }

  void closeWindow(WidgetTester tester) =>
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();

  Future<void> dispose(WidgetTester tester) async {
    history.onProgress = null;
    history.onDuration = null;
    readerKey.currentState?.autoReading.stop();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    LocalManager.resetForTesting();
    history.close();
    HistoryManager.cache = previousHistory;
    LocalFavoritesManager.cache = previousFavorites;
    Log.isMuted = previousLogMuted;
    previousSettings.forEach((key, value) => appdata.settings[key] = value);
    directory.deleteSync(recursive: true);
  }
}

class _TestReader extends Reader {
  _TestReader({required super.key, required super.onClosed})
    : super(
        type: ComicType.local,
        cid: 'book',
        name: 'Book',
        author: '',
        tags: const [],
        chapters: _chapters,
        history: History.fromMap({
          'id': 'book',
          'type': 0,
          'time': 1000,
          'title': 'Book',
          'subtitle': '',
          'cover': '',
          'ep': 1,
          'page': 1,
          'max_page': 3,
        }),
      );

  @override
  ReaderState createState() => _TestReaderState();
}

class _TestReaderState extends ReaderState {
  ComicLayoutProbe? layoutProbe;
  Future<void> Function()? onSaveSettings;
  int settingsSaves = 0;

  @override
  ComicLayoutProbe createLayoutProbe() =>
      layoutProbe ?? super.createLayoutProbe();

  @override
  Future<void> saveReadingSettings() {
    settingsSaves++;
    return onSaveSettings?.call() ?? super.saveReadingSettings();
  }

  @override
  void setImageCacheSize() {}
}

/// Separate UI and cleanup gates; the real reader/session/window owns both.
class _LayoutProbeGate extends ComicLayoutProbe {
  final _result = Completer<ComicLayoutDetection>();
  final _cleanup = Completer<void>();
  bool started = false;
  bool _cancelled = false;

  @override
  bool get isCancelled => _cancelled;
  @override
  Future<void> get done => _cleanup.future;

  @override
  Future<ComicLayoutDetection> detect({
    required List<String> images,
    required String? sourceKey,
    required String comicId,
    required String chapterId,
  }) {
    started = true;
    return _result.future;
  }

  @override
  void cancel() {
    _cancelled = true;
    if (!_result.isCompleted) {
      _result.complete(const ComicLayoutDetection(ComicLayout.unknown, 0));
    }
  }

  void finish([ComicLayout layout = ComicLayout.unknown]) {
    if (!_cleanup.isCompleted) _cleanup.complete();
    if (!_result.isCompleted) _result.complete(ComicLayoutDetection(layout, 6));
  }
}

class _ControlledHistory extends HistoryManager {
  _ControlledHistory() : super.create();

  final progress = <History>[];
  final durations = <Duration>[];
  Future<void> Function(History)? onProgress;
  Future<void> Function(Duration)? onDuration;

  @override
  Future<void> addHistory(History history) {
    final snapshot = history.copy();
    progress.add(snapshot);
    return onProgress?.call(snapshot) ?? Future.value();
  }

  @override
  Future<void> addReadDuration(History history, Duration duration) async {
    durations.add(duration);
    await onDuration?.call(duration);
  }
}

class _Favorites extends ChangeNotifier implements LocalFavoritesManager {
  @override
  int get connectionGeneration => 1;
  Future<void>? reading;
  int reads = 0;

  @override
  Future<void> onRead(
    String id,
    ComicType type, {
    int? generation,
    void Function()? checkActive,
  }) async {
    checkActive?.call();
    reads++;
    await reading;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
