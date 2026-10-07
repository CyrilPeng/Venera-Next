import 'package:venera_next/features/history/history_api.dart';
import 'package:venera_next/features/reader/reader_viewport.dart';
import 'package:venera_next/features/reader/platform_effects.dart'
    show ReaderPlatformEffectsScope;
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/reader/layout_detection.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/comic_layout.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/log.dart';

void main() {
  late Directory directory;
  late Map<String, dynamic> previousSettings;
  LocalFavoritesManager? previousFavorites;
  late bool previousLogMuted;
  final settings = appdata.settings;
  final readers = <_ReaderHarnessState>[];

  setUp(() {
    readers.clear();
    previousLogMuted = Log.isMuted;
    Log.isMuted = true;
    directory = Directory.systemTemp.createTempSync('reader-mode-regression-');
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    previousSettings = jsonDecode(jsonEncode(appdata.toJson()['settings']));
    previousFavorites = LocalFavoritesManager.cache;
    LocalFavoritesManager.cache = _Favorites();
    settings['autoReaderMode'] = true;
    settings['readerMode'] = 'galleryRightToLeft';
    settings['longStripReaderMode'] = 'continuousTopToBottom';
    settings['pagedReaderMode'] = 'galleryRightToLeft';
    settings['deviceSpecificSettings'] = <String, dynamic>{};
    settings['comicSpecificSettings'] = <String, dynamic>{};
    settings['comicLayoutDetections'] = <String, dynamic>{};
    settings['readerScreenPicNumberForLandscape'] = 2;
    settings['showSingleImageOnFirstPage'] = false;
    settings['enablePageAnimation'] = false;
    settings['language'] = 'en-US';
  });

  tearDown(() {
    Log.isMuted = previousLogMuted;
    LocalFavoritesManager.cache = previousFavorites;
    previousSettings.forEach((key, value) => settings[key] = value);
    directory.deleteSync(recursive: true);
  });

  void readerTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        for (final reader in readers) {
          reader.finishPendingWork();
        }
        await tester.pump(const Duration(seconds: 3));
      }
    });
  }

  Future<_ReaderHarnessState> mount(
    WidgetTester tester, {
    VoidCallback? onClosed,
  }) async {
    final key = GlobalKey<_ReaderHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ReaderPlatformEffectsScope(child: child!),
        navigatorKey: App.rootNavigatorKey,
        home: OverlayWidget(_ReaderHarness(key: key, onClosed: onClosed)),
      ),
    );
    final reader = key.currentState!;
    readers.add(reader);
    return reader;
  }

  for (final cancelled in [false, true]) {
    readerTest(
      'real layout save waits for admission and checks cancellation=$cancelled',
      (tester) async {
        final reader = await mount(tester);
        reader.useProductionSettings = true;
        final release = Completer<void>();
        final exclusive = AppDataOperations.instance.run(() => release.future);
        final detection = reader.detectLayout();
        reader.probes.single.finish(ComicLayout.longStrip);
        await tester.pump();
        expect(reader.settingsSaves, 1);
        expect(settings.comicLayout('comic', 'local'), ComicLayout.unknown);
        if (cancelled) reader.probes.single.cancel();
        release.complete();
        var finished = false;
        final saves = Future.wait([
          exclusive,
          detection,
          appdata.saveData(false),
        ]).then((_) => finished = true);
        for (var i = 0; i < 500 && !finished; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(finished, isTrue);
        await saves;
        expect(
          settings.comicLayout('comic', 'local'),
          cancelled ? ComicLayout.unknown : ComicLayout.longStrip,
        );
        final saved = jsonDecode(
          File('${directory.path}/appdata.json').readAsStringSync(),
        );
        expect(
          saved['settings']['comicLayoutDetections'].containsKey('comic@local'),
          !cancelled,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  readerTest('reader teardown notifies its injected owner once', (
    tester,
  ) async {
    var closed = 0;
    await mount(tester, onClosed: () => closed++);
    expect(closed, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
    expect(closed, 1);
  });

  readerTest(
    '700ms presentation does not release unfinished probe work on exit',
    (tester) async {
      var closed = 0;
      final reader = await mount(tester, onClosed: () => closed++);
      var presented = false;
      unawaited(reader.prepareReadingMode().then((_) => presented = true));
      await tester.pump(const Duration(milliseconds: 700));
      expect(presented, isTrue);
      final probe = reader.probes.single;
      await tester.pumpWidget(const SizedBox());
      expect(probe.isCancelled, isTrue);
      var drained = false;
      final closing = reader.imageWork.dispose().then((_) => drained = true);
      await tester.pump(const Duration(seconds: 3));
      expect(drained, isFalse);
      expect(closed, 0);
      expect(reader.settingsSaves, 0);
      probe.finishDone();
      await tester.pump();
      await closing;
      expect(closed, 1);
      expect(settings.comicLayout('comic', 'local'), ComicLayout.unknown);
      expect(tester.takeException(), isNull);
    },
  );

  for (final timedOut in [false, true]) {
    readerTest(
      'probe ${timedOut ? '8s timeout' : 'cancellation'} cannot publish and allows retry',
      (tester) async {
        final reader = await mount(tester);
        final detection = reader.detectLayout();
        final probe = reader.probes.single;
        if (timedOut) {
          await tester.pump(const Duration(seconds: 8));
        } else {
          probe.cancel();
          await tester.pump();
        }
        expect(probe.isCancelled, isTrue);
        expect(reader.settingsSaves, 0);
        expect(reader.mode, ReaderMode.galleryRightToLeft);
        probe.finish(ComicLayout.longStrip);
        await detection;
        await tester.pump();
        expect(reader.isDetectingLayout, isFalse);
        expect(reader.settingsSaves, 0);
        expect(settings.comicLayout('comic', 'local'), ComicLayout.unknown);
        expect(find.textContaining('Switched to'), findsNothing);

        final retry = reader.detectLayout();
        expect(reader.probes, hasLength(2));
        reader.probes.last.finish(ComicLayout.paged);
        await retry;
        expect(reader.settingsSaves, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  readerTest(
    'same probe input shares work and saves once after real completion',
    (tester) async {
      final reader = await mount(tester);
      final first = reader.detectLayout();
      final second = reader.detectLayout();
      expect(reader.probes, hasLength(1));
      final probe = reader.probes.single;
      probe.finish(ComicLayout.longStrip, releaseDone: false);
      await tester.pump();
      expect(reader.settingsSaves, 0);
      expect(settings.comicLayout('comic', 'local'), ComicLayout.unknown);
      expect(reader.mode, ReaderMode.galleryRightToLeft);
      probe.finishDone();
      await Future.wait([first, second]);
      await tester.pump();
      expect(reader.settingsSaves, 1);
      expect(reader.mode, ReaderMode.continuousTopToBottom);
    },
  );

  for (final replaceChapter in [false, true]) {
    readerTest(
      '${replaceChapter ? 'new chapter input' : 'forced detection'} replaces the old attempt but retains its cleanup',
      (tester) async {
        final reader = await mount(tester);
        final oldDetection = reader.detectLayout();
        final old = reader.probes.single;
        old.finish(ComicLayout.longStrip, releaseDone: false);
        await tester.pump();
        expect(reader.settingsSaves, 0);
        if (replaceChapter) {
          reader.controller.restoreChapter(3);
          reader.controller.replaceChapterImages(
            List.generate(12, (i) => 'new-$i'),
          );
        }
        final replacement = reader.detectLayout(force: !replaceChapter);
        expect(reader.probes, hasLength(2));
        expect(old.isCancelled, isTrue);
        reader.probes.last.finish(ComicLayout.paged);
        await replacement;
        expect(reader.settingsSaves, 1);
        expect(settings.comicLayout('comic', 'local'), ComicLayout.paged);

        var drained = false;
        final draining = reader.imageWork.prepareForExit().then((release) {
          drained = true;
          return release;
        });
        await tester.pump();
        expect(drained, isFalse);
        old.finishDone();
        await oldDetection;
        final release = await draining;
        release();
        await tester.pump();
        expect(reader.settingsSaves, 1);
        expect(settings.comicLayout('comic', 'local'), ComicLayout.paged);
        expect(reader.mode, ReaderMode.galleryRightToLeft);
        expect(reader.isDetectingLayout, isFalse);
        expect(find.textContaining('Switched to'), findsNothing);
      },
    );
  }

  for (final unmount in [false, true]) {
    readerTest(
      '${unmount ? 'unmount' : 'exit hold'} waits for an accepted settings save and suppresses mode switching',
      (tester) async {
        var closed = 0;
        final reader = await mount(tester, onClosed: () => closed++);
        final save = reader.delaySettingsSave();
        final detection = reader.detectLayout();
        reader.probes.single.finish(ComicLayout.longStrip);
        await tester.pump();
        expect(reader.settingsSaves, 1);
        expect(reader.mode, ReaderMode.galleryRightToLeft);
        if (unmount) await tester.pumpWidget(const SizedBox());
        var drained = false;
        final ownerCompletion = unmount
            ? reader.imageWork.dispose().then((_) => () {})
            : reader.imageWork.prepareForExit();
        final draining = ownerCompletion.then((release) {
          drained = true;
          return release;
        });
        await tester.pump(const Duration(seconds: 3));
        expect(drained, isFalse);
        expect(closed, 0);
        save.complete();
        await detection;
        final release = await draining;
        release();
        await tester.pump();
        expect(reader.mode, ReaderMode.galleryRightToLeft);
        expect(find.textContaining('Switched to'), findsNothing);
        expect(closed, unmount ? 1 : 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  readerTest('old probe cleanup cannot clear the replacement detection state', (
    tester,
  ) async {
    final reader = await mount(tester);
    final first = reader.detectLayout();
    final old = reader.probes.single;
    old.finish(ComicLayout.longStrip, releaseDone: false);
    await tester.pump();
    final replacement = reader.detectLayout(force: true);
    expect(reader.probes, hasLength(2));
    old.finishDone();
    await first;
    await tester.pump();
    expect(reader.isDetectingLayout, isTrue);
    expect(reader.settingsSaves, 0);
    reader.probes.last.finish(ComicLayout.paged);
    await replacement;
    expect(reader.isDetectingLayout, isFalse);
    expect(reader.settingsSaves, 1);
    expect(settings.comicLayout('comic', 'local'), ComicLayout.paged);
  });

  readerTest(
    'cancellation after an early result releases UI while cleanup remains owned',
    (tester) async {
      final reader = await mount(tester);
      var ready = false;
      final detection = reader.detectLayout().then((_) => ready = true);
      final probe = reader.probes.single;
      probe.finish(ComicLayout.longStrip, releaseDone: false);
      await tester.pump();
      expect(ready, isFalse);
      final releaseHold = reader.imageWork.holdForExit();
      await tester.pump();
      expect(ready, isTrue);
      expect(reader.settingsSaves, 0);
      var drained = false;
      final draining = reader.imageWork.prepareForExit().then((release) {
        drained = true;
        return release;
      });
      await tester.pump();
      expect(drained, isFalse);
      probe.finishDone();
      await detection;
      final release = await draining;
      release();
      releaseHold();
      expect(reader.settingsSaves, 0);
      expect(settings.comicLayout('comic', 'local'), ComicLayout.unknown);
    },
  );

  for (final changeChapter in [false, true]) {
    readerTest(
      '${changeChapter ? 'chapter' : 'image list'} changes cancel stale probes without starting another detection',
      (tester) async {
        final reader = await mount(tester);
        final detection = reader.detectLayout();
        final old = reader.probes.single;
        if (changeChapter) {
          reader.controller.restoreChapter(3);
        } else {
          reader.controller.replaceChapterImages(
            List.generate(12, (i) => 'replacement-$i'),
          );
        }
        reader.update();
        expect(old.isCancelled, isTrue);
        await tester.pump();
        await detection;
        expect(reader.probes, hasLength(1));
        expect(reader.isDetectingLayout, isFalse);
        expect(reader.settingsSaves, 0);
        var drained = false;
        final draining = reader.imageWork.prepareForExit().then((release) {
          drained = true;
          return release;
        });
        await tester.pump();
        expect(drained, isFalse);
        old.finishDone();
        final release = await draining;
        release();
        final retry = reader.detectLayout();
        expect(reader.probes, hasLength(2));
        reader.probes.last.finish(ComicLayout.paged);
        await retry;
        expect(reader.settingsSaves, 1);
      },
    );
  }

  readerTest(
    'prepare retries a failed forced save after a previously sampled chapter',
    (tester) async {
      final reader = await mount(tester);
      final first = reader.detectLayout();
      reader.probes.single.finish(ComicLayout.longStrip);
      await first;
      expect(reader.mode, ReaderMode.continuousTopToBottom);
      final error = StateError('forced save failed');
      reader.onSaveSettings = () => Future.error(error);
      final forced = reader.detectLayout(force: true);
      reader.probes.last.finish(ComicLayout.paged);
      await forced;
      expect(reader.settingsSaves, 2);
      expect(reader.mode, ReaderMode.continuousTopToBottom);
      await expectLater(
        reader.imageWork.prepareForExit(),
        throwsA(isA<ImageWorkFailure>()),
      );
      reader.onSaveSettings = null;
      final prepared = reader.prepareReadingMode();
      expect(reader.probes, hasLength(3));
      reader.probes.last.finish(ComicLayout.paged);
      await prepared;
      expect(reader.settingsSaves, 3);
      expect(reader.mode, ReaderMode.galleryRightToLeft);
      expect(tester.takeException(), isNull);
    },
  );

  readerTest(
    'content reload cancels detection before replacing its old image list',
    (tester) async {
      final reader = await mount(tester);
      final originalImages = reader.images;
      final detection = reader.detectLayout();
      final probe = reader.probes.single;
      reader.onReaderContentLoading();
      expect(reader.images, same(originalImages));
      expect(probe.isCancelled, isTrue);
      await tester.pump();
      await detection;
      expect(reader.isDetectingLayout, isFalse);
      var drained = false;
      final draining = reader.imageWork.prepareForExit().then((release) {
        drained = true;
        return release;
      });
      await tester.pump();
      expect(drained, isFalse);
      expect(reader.settingsSaves, 0);
      probe.finishDone();
      final release = await draining;
      release();
      final retry = reader.detectLayout();
      expect(reader.probes, hasLength(2));
      reader.probes.last.finish(ComicLayout.paged);
      await retry;
      expect(reader.settingsSaves, 1);
    },
  );

  for (final storageFailure in [false, true]) {
    readerTest(
      '${storageFailure ? 'settings save' : 'probe cleanup'} failure reaches the image owner with original diagnostics',
      (tester) async {
        final reader = await mount(tester);
        final error = StateError(
          storageFailure ? 'settings failed' : 'cleanup failed',
        );
        final stack = StackTrace.current;
        if (storageFailure) {
          reader.onSaveSettings = () => Future.error(error, stack);
        }
        final detection = reader.detectLayout();
        final probe = reader.probes.single;
        probe.finish(ComicLayout.longStrip, releaseDone: storageFailure);
        if (!storageFailure) {
          await tester.pump();
          expect(reader.settingsSaves, 0);
          probe.finishDone(error: error, stack: stack);
        }
        await detection;
        await tester.pump();
        expect(reader.isDetectingLayout, isFalse);
        expect(reader.mode, ReaderMode.galleryRightToLeft);
        expect(reader.settingsSaves, storageFailure ? 1 : 0);
        expect(find.textContaining('Switched to'), findsNothing);
        expect(tester.takeException(), isNull);
        await expectLater(
          reader.imageWork.prepareForExit(),
          throwsA(
            isA<ImageWorkFailure>()
                .having(
                  (failure) => failure.failures.single.error,
                  'original error',
                  same(error),
                )
                .having(
                  (failure) => failure.failures.single.stack,
                  'original stack',
                  same(stack),
                ),
          ),
        );
        reader.onSaveSettings = null;
        final retry = reader.detectLayout();
        expect(reader.probes, hasLength(2));
        reader.probes.last.finish(ComicLayout.paged);
        await retry;
        expect(reader.isDetectingLayout, isFalse);
      },
    );
  }

  for (final nextChapter in [false, true]) {
    readerTest(
      'late old save failure survives replacement cancellation and retries ${nextChapter ? 'in the new chapter' : 'the same chapter'}',
      (tester) async {
        final reader = await mount(tester);
        final oldSave = reader.delaySettingsSave();
        final first = reader.detectLayout();
        reader.probes.single.finish(ComicLayout.longStrip);
        await tester.pump();
        expect(reader.settingsSaves, 1);
        if (nextChapter) {
          reader.controller.restoreChapter(3);
          reader.controller.replaceChapterImages(
            List.generate(12, (i) => 'next-$i'),
          );
          reader.update();
        }
        final replacement = reader.detectLayout(force: true);
        expect(reader.probes, hasLength(2));
        final error = StateError('old save failed after replacement');
        final stack = StackTrace.current;
        oldSave.completeError(error, stack);
        await tester.pump();
        reader.probes.last.cancel();
        reader.probes.last.finishDone();
        await Future.wait([first, replacement]);
        await expectLater(
          reader.imageWork.prepareForExit(),
          throwsA(
            isA<ImageWorkFailure>()
                .having(
                  (failure) => failure.failures.single.error,
                  'original error',
                  same(error),
                )
                .having(
                  (failure) => failure.failures.single.stack,
                  'original stack',
                  same(stack),
                ),
          ),
        );
        expect(reader.settingsSaves, 1);
        expect(reader.mode, ReaderMode.galleryRightToLeft);
        reader.onSaveSettings = null;
        final retry = reader.prepareReadingMode();
        expect(reader.probes, hasLength(3));
        reader.probes.last.finish(ComicLayout.paged);
        await retry;
        expect(reader.settingsSaves, 2);
        expect(settings.comicLayout('comic', 'local'), ComicLayout.paged);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final sharedCleanupError in [false, true]) {
    readerTest(
      'failed result clears detection and records its original error once; shared cleanup=$sharedCleanupError',
      (tester) async {
        final reader = await mount(tester);
        final error = StateError('probe failed');
        final stack = StackTrace.current;
        final detection = reader.detectLayout();
        reader.probes.single.failResult(
          error,
          stack,
          failDone: sharedCleanupError,
        );
        await detection;
        await tester.pump();
        expect(reader.isDetectingLayout, isFalse);
        expect(reader.settingsSaves, 0);
        expect(reader.mode, ReaderMode.galleryRightToLeft);
        expect(tester.takeException(), isNull);
        await expectLater(
          reader.imageWork.prepareForExit(),
          throwsA(
            isA<ImageWorkFailure>()
                .having(
                  (failure) => failure.failures.single.error,
                  'original error',
                  same(error),
                )
                .having(
                  (failure) => failure.failures.single.stack,
                  'original stack',
                  same(stack),
                ),
          ),
        );
        final retry = reader.detectLayout();
        expect(reader.probes, hasLength(2));
        reader.probes.last.finish(ComicLayout.paged);
        await retry;
      },
    );
  }

  readerTest(
    'default-off leaves mode and navigation unchanged and starts no probe',
    (tester) async {
      settings['autoReaderMode'] = false;
      final reader = await mount(tester);
      await reader.prepareReadingMode();
      expect(reader.probes, isEmpty);
      expect(reader.mode, ReaderMode.galleryRightToLeft);
      expect((reader.chapter, reader.page), (2, 3));
      final controller = _Controller();
      reader.viewportBinding.update(controller, true);
      expect(reader.toNextPage(), isTrue);
      expect(controller.visited, [4]);
    },
  );

  readerTest(
    'first open waits up to 700ms then applies a late result with the actual mode toast',
    (tester) async {
      final reader = await mount(tester);
      var ready = false;
      unawaited(reader.prepareReadingMode().then((_) => ready = true));
      await tester.pump(const Duration(milliseconds: 699));
      expect(ready, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      expect(ready, isTrue);
      expect(reader.isDetectingLayout, isTrue);
      expect(reader.mode, ReaderMode.galleryRightToLeft);
      reader.probes.single.finish(ComicLayout.longStrip);
      await tester.pump();
      await tester.pump();
      expect(reader.mode, ReaderMode.continuousTopToBottom);
      expect(
        find.text('Switched to Continuous (Top to Bottom)'),
        findsOneWidget,
      );
      expect(find.text('Apply reading preference'), findsNothing);
      expect((reader.chapter, reader.page), (2, 5));
      expect(reader.imageViewController, isNull);
      expect(settings.comicLayout('comic', 'local'), ComicLayout.longStrip);
      final controller = _Controller();
      reader.viewportBinding.update(controller, true);
      expect(reader.toNextPage(), isTrue);
      expect(reader.toPrevPage(), isTrue);
      expect(controller.visited, [6, 5]);
      expect(reader.chapter, 2);
      expect(reader.toNextChapter(), isTrue);
      expect((reader.chapter, reader.page), (3, 1));
    },
  );

  readerTest('fast detection releases the initial wait before its deadline', (
    tester,
  ) async {
    final reader = await mount(tester);
    var ready = false;
    unawaited(reader.prepareReadingMode().then((_) => ready = true));
    reader.probes.single.finish(ComicLayout.longStrip);
    await tester.pump(const Duration(milliseconds: 10));
    expect(ready, isTrue);
    expect(reader.mode, ReaderMode.continuousTopToBottom);
  });

  for (final action in ['disable', 'override']) {
    readerTest('late result respects $action while detection was pending', (
      tester,
    ) async {
      final reader = await mount(tester);
      final detection = reader.detectLayout();
      if (action == 'disable') {
        settings['autoReaderMode'] = false;
      } else {
        settings.setComicReaderModeOverride(
          'comic',
          'local',
          'galleryLeftToRight',
        );
        reader.applyReadingMode(ReaderMode.galleryLeftToRight);
      }
      final current = reader.mode;
      reader.probes.single.finish(ComicLayout.longStrip);
      await detection;
      await tester.pump();
      expect(reader.mode, current);
      expect(find.textContaining('Switched to'), findsNothing);
    });
  }

  readerTest('unknown or unchanged results do not switch or notify', (
    tester,
  ) async {
    final reader = await mount(tester);
    final unknown = reader.detectLayout();
    reader.probes.last.finish(ComicLayout.unknown);
    await unknown;
    final same = reader.detectLayout(force: true);
    reader.probes.last.finish(ComicLayout.paged);
    await same;
    await tester.pump();
    expect(reader.mode, ReaderMode.galleryRightToLeft);
    expect((reader.chapter, reader.page), (2, 3));
    expect(find.textContaining('Switched to'), findsNothing);
  });

  readerTest(
    'leaving the reader cancels recognition and ignores its late result',
    (tester) async {
      final reader = await mount(tester);
      final detection = reader.detectLayout();
      final probe = reader.probes.single;
      await tester.pumpWidget(const SizedBox.shrink());
      expect(probe.cancelled, isTrue);
      probe.finish(ComicLayout.longStrip);
      await detection;
      await tester.pump(const Duration(seconds: 1));
      expect(settings.comicLayout('comic', 'local'), ComicLayout.unknown);
      expect(tester.takeException(), isNull);
    },
  );

  readerTest(
    'mode switch invalidates an old page animation and accepts new navigation',
    (tester) async {
      settings['enablePageAnimation'] = true;
      final reader = await mount(tester);
      final oldController = _Controller();
      reader.viewportBinding.update(oldController, true);
      reader.toNextPage();
      expect(reader.isPageAnimating, isTrue);
      reader.applyReadingMode(ReaderMode.continuousTopToBottom);
      expect(reader.isPageAnimating, isFalse);
      oldController.animation.complete();
      await tester.pump();
      expect(reader.isPageAnimating, isFalse);
      settings['enablePageAnimation'] = false;
      final currentController = _Controller();
      reader.viewportBinding.update(currentController, true);
      reader.toNextPage();
      expect(currentController.visited, [6]);
      expect((reader.chapter, reader.page), (2, 6));
    },
  );

  readerTest(
    'single cover and paired pages map back to the same source image',
    (tester) async {
      settings['showSingleImageOnFirstPage'] = true;
      final reader = await mount(tester);
      expect(
        reader.page,
        3,
      ); // Images 4 and 5 are displayed together after the cover.
      reader.applyReadingMode(ReaderMode.waterfallTopToBottom);
      expect((reader.chapter, reader.page), (2, 4));
      reader.applyReadingMode(ReaderMode.galleryRightToLeft);
      expect((reader.chapter, reader.page), (2, 3));
    },
  );
}

// Keep the real ReaderState lifecycle and navigation, isolating native window,
// database and image-rendering services. Probe behavior is tested separately.
class _ReaderHarness extends Reader {
  _ReaderHarness({required super.key, VoidCallback? onClosed})
    : super(
        onClosed: onClosed ?? () {},
        type: ComicType.local,
        cid: 'comic',
        name: 'Comic',
        author: '',
        tags: const [],
        chapters: const ComicChapters({
          'one': 'One',
          'two': 'Two',
          'three': 'Three',
        }),
        history: _History(),
        initialChapter: 2,
        initialPage: 5,
      );
  @override
  ReaderState createState() => _ReaderHarnessState();
}

class _ReaderHarnessState extends ReaderState {
  final probes = <_Probe>[];
  final pendingSaves = <Completer<void>>[];
  Future<void> Function()? onSaveSettings;
  var settingsSaves = 0;

  Completer<void> delaySettingsSave() {
    final pending = Completer<void>();
    pendingSaves.add(pending);
    onSaveSettings = () => pending.future;
    return pending;
  }

  void finishPendingWork() {
    for (final probe in probes) {
      probe.cancel();
      probe.finishDone();
    }
    for (final pending in pendingSaves) {
      if (!pending.isCompleted) pending.complete();
    }
  }

  @override
  void initState() {
    super.initState();
    controller.replaceChapterImages(List.generate(12, (i) => 'image-$i'));
  }

  @override
  ComicLayoutProbe createLayoutProbe() {
    final probe = _Probe();
    probes.add(probe);
    return probe;
  }

  @override
  Future<void> saveReadingSettings(void Function(Settings draft) edit) {
    settingsSaves++;
    if (useProductionSettings) return super.saveReadingSettings(edit);
    edit(appdata.settings);
    return onSaveSettings?.call() ?? Future.value();
  }

  bool useProductionSettings = false;

  @override
  void setImageCacheSize() {}
  @override
  void initReaderWindow() {}
  @override
  void disposeReaderWindow() {}
  @override
  void onPageChanged() {}
  @override
  Widget build(BuildContext context) => Text('${mode.key}:$chapter:$page');
}

class _Probe extends ComicLayoutProbe {
  final completion = Completer<ComicLayoutDetection>();
  final cleanup = Completer<void>();
  Timer? timeout;
  bool cancelled = false;
  @override
  Future<void> get done => cleanup.future;
  @override
  bool get isCancelled => cancelled;

  void finish(ComicLayout layout, {bool releaseDone = true}) {
    timeout?.cancel();
    if (!completion.isCompleted) {
      completion.complete(ComicLayoutDetection(layout, 6));
    }
    if (releaseDone) finishDone();
  }

  void failResult(Object error, StackTrace stack, {bool failDone = false}) {
    timeout?.cancel();
    if (!completion.isCompleted) completion.completeError(error, stack);
    finishDone(error: failDone ? error : null, stack: stack);
  }

  void finishDone({Object? error, StackTrace? stack}) {
    if (cleanup.isCompleted) return;
    if (error == null) {
      cleanup.complete();
    } else {
      cleanup.completeError(error, stack);
    }
  }

  @override
  Future<ComicLayoutDetection> detect({
    required List<String> images,
    required String? sourceKey,
    required String comicId,
    required String chapterId,
  }) {
    timeout ??= Timer(const Duration(seconds: 8), cancel);
    return completion.future;
  }

  @override
  void cancel() {
    if (cancelled) return;
    cancelled = true;
    timeout?.cancel();
    if (!completion.isCompleted) {
      completion.complete(const ComicLayoutDetection(ComicLayout.unknown, 0));
    }
  }
}

class _Controller extends Fake implements ReaderImageViewController {
  final visited = <int>[];
  final animation = Completer<void>();
  @override
  void toPage(int page) => visited.add(page);
  @override
  Future<void> animateToPage(int page) => animation.future;
  @override
  bool toChapter(int chapter, {bool toLastPage = false}) => false;
}

class _History extends Fake implements History {}

class _Favorites extends ChangeNotifier implements LocalFavoritesManager {
  @override
  int get connectionGeneration => 1;

  @override
  Future<void> onRead(
    String id,
    ComicType type, {
    int? generation,
    void Function()? checkActive,
  }) async {
    checkActive?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
