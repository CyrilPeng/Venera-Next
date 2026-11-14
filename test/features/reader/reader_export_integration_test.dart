import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/image_export.dart';
import 'package:venera_next/features/reader/image_position.dart';
import 'package:venera_next/features/reader/gallery_view.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/features/reader/scaffold.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/comic_type.dart';

import 'support/reader_integration_fixture.dart';

void main() {
  setUpReaderIntegration();

  testWidgets(
    'captured reader image read retains the original chapter cache key',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final previous = CacheManager.instance;
      final cache = CacheManager.open(
        dataPath: fixture.directory.path,
        cacheRoot: fixture.directory.path,
      );
      CacheManager.instance = cache;
      try {
        await fixture.mount(
          tester,
          pushed: false,
          chapters: const ComicChapters({'one': 'One', 'two': 'Two'}),
        );
        await tester.runAsync(() async {
          await cache.writeCache('collision@local@book@one', [1, 2, 3]);
          await cache.writeCache('collision@local@book@two', [4, 5, 6]);
        });
        final read = tester
            .widget<ReaderGalleryView>(find.byType(ReaderGalleryView))
            .readImage;
        fixture.readerKey.currentState!.controller.restoreChapter(2);
        final bytes = await tester.runAsync(
          () => read(
            const ReaderImageAddress(
              imageKey: 'collision',
              sourceKey: 'local',
              comicId: 'book',
              chapterId: 'one',
            ),
          ),
        );
        expect(bytes, [1, 2, 3]);
      } finally {
        await tester.runAsync(cache.dispose);
        CacheManager.instance = previous;
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets('reader image cache miss returns an absent image', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    final previous = CacheManager.instance;
    final cache = CacheManager.open(
      dataPath: fixture.directory.path,
      cacheRoot: fixture.directory.path,
    );
    CacheManager.instance = cache;
    try {
      await fixture.mount(tester, pushed: false);
      final read = tester
          .widget<ReaderGalleryView>(find.byType(ReaderGalleryView))
          .readImage;
      expect(
        await tester.runAsync(
          () => read(
            const ReaderImageAddress(
              imageKey: 'missing',
              sourceKey: 'local',
              comicId: 'book',
              chapterId: 'one',
            ),
          ),
        ),
        isNull,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.runAsync(cache.dispose);
      CacheManager.instance = previous;
      await fixture.dispose(tester);
    }
  });

  for (final change in ['chapter id', 'chapter order', 'chapter title']) {
    testWidgets('export rejects $change changed during selection', (
      tester,
    ) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final chapters = {'one': 'One', 'two': 'Two'};
      const selector = MethodChannel('plugins.flutter.io/file_selector');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var dialogs = 0;
      messenger.setMockMethodCallHandler(selector, (_) async {
        dialogs++;
        return null;
      });
      try {
        await fixture.mount(
          tester,
          pushed: false,
          chapters: ComicChapters(chapters),
        );
        final reader = fixture.readerKey.currentState!;
        final shell = tester.state<ReaderScaffoldState>(
          find.byType(ReaderScaffold),
        );
        Future<void>? export;
        final detach = reader.imageWork.retainTasks((task) {
          export ??= task.done;
          return () {};
        });
        await tester.runAsync(() async {
          shell.saveCurrentImage();
          switch (change) {
            case 'chapter id':
              chapters.remove('one');
            case 'chapter order':
              chapters.remove('one');
              chapters['one'] = 'One';
            case 'chapter title':
              chapters['one'] = 'Renamed';
          }
          expect(export, isNotNull);
          await export;
        });
        detach();
        expect(dialogs, 0);
        expect(tester.takeException(), isNull);
      } finally {
        messenger.setMockMethodCallHandler(selector, null);
        await fixture.dispose(tester);
      }
    });
  }

  testWidgets(
    'failed favorite status offers read-only retry and preserves data',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      var renamed = false;
      try {
        await fixture.mount(tester, pushed: false);
        final shell = tester.state<ReaderScaffoldState>(
          find.byType(ReaderScaffold),
        );
        shell.openOrClose();
        fixture.history.imageFavoritesDatabase.execute(
          'ALTER TABLE image_favorites RENAME TO unavailable_favorites',
        );
        renamed = true;
        readerFixtureImageOwner!.notifyChanges();
        await tester.pumpAndSettle();
        final retry = find.byTooltip('Unable to load image collection. Retry');
        expect(retry, findsOneWidget);
        expect(find.byIcon(Icons.favorite_border), findsNothing);
        fixture.history.imageFavoritesDatabase.execute(
          'ALTER TABLE unavailable_favorites RENAME TO image_favorites',
        );
        renamed = false;
        await tester.tap(retry);
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.favorite_border), findsOneWidget);
        expect(await readerFixtureImageOwner!.getAll(), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        if (renamed) {
          fixture.history.imageFavoritesDatabase.execute(
            'ALTER TABLE unavailable_favorites RENAME TO image_favorites',
          );
        }
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets('export request rejects content reload and final host close', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    final registry = SelectionTaskRegistry();
    try {
      await fixture.mount(
        tester,
        pushed: false,
        withWindow: false,
        registry: registry,
      );
      final reader = fixture.readerKey.currentState!;
      final request = reader.createImageExportRequest()!;
      final settings = reader.createSettingsRequest()!;
      expect(request.resolve(0)?.chapterId, 'one');
      reader.controller.beginContentLoad();
      expect(request.resolve(0), isNull);
      expect(reader.createImageExportRequest(), isNull);
      final closing = registry.closeAndWait();
      expect(reader.createImageExportRequest(), isNull);
      expect(reader.createSettingsRequest(), isNull);
      expect(settings.isCurrent(), isFalse);
      await tester.pump();
      await closing;
    } finally {
      await fixture.dispose(tester);
    }
  });

  for (final change in ['comic', 'source', 'chapters']) {
    testWidgets(
      'reader requests reject replacement $change on the same State',
      (tester) async {
        final fixture = await ReaderIntegrationFixture.create(tester);
        try {
          await fixture.mount(tester, pushed: false);
          final reader = fixture.readerKey.currentState!;
          final export = reader.createImageExportRequest()!;
          final settings = reader.createSettingsRequest()!;
          await fixture.mount(
            tester,
            pushed: false,
            expectContent: false,
            comicId: change == 'comic' ? 'replacement' : 'book',
            comicType: change == 'source'
                ? const ReaderFixtureOtherComicType()
                : ComicType.local,
            chapters: change == 'chapters'
                ? const ComicChapters({'one': 'Replacement chapter'})
                : readerIntegrationChapters,
          );
          expect(fixture.readerKey.currentState, same(reader));
          expect(export.resolve(0), isNull);
          expect(settings.isCurrent(), change == 'chapters');
          if (change != 'chapters') {
            settings.apply(
              'readerMode',
              applyShellEffect: (_) => fail('Old shell effect'),
            );
            expect(reader.mode, ReaderMode.galleryLeftToRight);
          }
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.dispose(tester);
        }
      },
    );
  }

  testWidgets(
    'spread selection exports the second duplicate with its source number',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      const selector = MethodChannel('plugins.flutter.io/file_selector');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final destination = File('${fixture.directory.path}/duplicate.png');
      Object? arguments;
      messenger.setMockMethodCallHandler(selector, (call) async {
        arguments = call.arguments;
        return destination.path;
      });
      try {
        appdata.settings['readerScreenPicNumberForLandscape'] = 2;
        appdata.settings['readerScreenPicNumberForPortrait'] = 2;
        appdata.settings['showSingleImageOnFirstPage'] = false;
        await fixture.mount(tester, pushed: false);
        final reader = fixture.readerKey.currentState!;
        final key = reader.images!.first;
        reader.controller.replaceChapterImages([key, key, key]);
        reader.update();
        await tester.pumpAndSettle();
        final gallery = reader.imageViewController! as GalleryModeState;
        final visible =
            gallery.imageStates.keys
                .whereType<ComicImageState>()
                .where((image) => image.visibleInReader)
                .toList()
              ..sort(
                (a, b) => tester
                    .getCenter(find.byWidget(a.widget))
                    .dx
                    .compareTo(tester.getCenter(find.byWidget(b.widget)).dx),
              );
        expect(visible, hasLength(2));
        final point = tester.getCenter(find.byWidget(visible.last.widget));
        Future<void>? exporting;
        var done = false;
        final detach = reader.imageWork.retainTasks((task) {
          exporting ??= task.done.then((_) => done = true);
          return () {};
        });
        try {
          tester
              .state<ReaderScaffoldState>(find.byType(ReaderScaffold))
              .saveCurrentImage();
          await tester.pumpAndSettle();
          await tester.tapAt(point);
          await pumpReaderUntil(tester, () => done);
          await exporting;
          expect(arguments.toString(), contains('Book_EP1_P2.png'));
          expect(
            destination.readAsBytesSync(),
            File(key.substring(7)).readAsBytesSync(),
          );
          expect(tester.takeException(), isNull);
        } finally {
          detach();
        }
      } finally {
        messenger.setMockMethodCallHandler(selector, null);
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets('shell export saves original bytes after page navigation', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    const selector = MethodChannel('plugins.flutter.io/file_selector');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final selected = Completer<String?>();
    final dialog = Completer<void>();
    final destination = File('${fixture.directory.path}/export.png');
    Object? arguments;
    messenger.setMockMethodCallHandler(selector, (call) {
      arguments = call.arguments;
      dialog.complete();
      return selected.future;
    });
    try {
      await fixture.mount(tester, pushed: false);
      final reader = fixture.readerKey.currentState!;
      final source = File(reader.images!.first.substring(7)).readAsBytesSync();
      Future<void>? exporting;
      var exportDone = false;
      final detach = reader.imageWork.retainTasks((task) {
        exporting ??= task.done.then((_) => exportDone = true);
        return () {};
      });
      final shell = tester.state<ReaderScaffoldState>(
        find.byType(ReaderScaffold),
      );
      shell.saveCurrentImage();
      await pumpReaderUntil(tester, () => dialog.isCompleted || exportDone);
      expect(dialog.isCompleted, isTrue);
      reader.toPage(2, animated: false);
      await tester.pumpAndSettle();
      selected.complete(destination.path);
      await pumpReaderUntil(tester, () => exportDone);
      await exporting;
      detach();
      expect(arguments.toString(), contains('Book_EP1_P1.png'));
      expect(destination.readAsBytesSync(), source);
      expect(tester.takeException(), isNull);
    } finally {
      if (!selected.isCompleted) selected.complete(null);
      messenger.setMockMethodCallHandler(selector, null);
      await fixture.dispose(tester);
    }
  });

  for (final detached in [false, true]) {
    testWidgets(
      'shell export retains native save during host close; detached=$detached',
      (tester) async {
        final fixture = await ReaderIntegrationFixture.create(tester);
        var coreCloses = 0;
        final host = await readerFixtureHost(() => coreCloses++);
        const selector = MethodChannel('plugins.flutter.io/file_selector');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final selected = Completer<String?>();
        final dialog = Completer<void>();
        messenger.setMockMethodCallHandler(selector, (_) {
          dialog.complete();
          return selected.future;
        });
        try {
          await fixture.mount(
            tester,
            pushed: false,
            withWindow: false,
            registry: host.selections,
          );
          final shell = tester.state<ReaderScaffoldState>(
            find.byType(ReaderScaffold),
          );
          shell.saveCurrentImage();
          await pumpReaderUntil(tester, () => dialog.isCompleted);
          if (detached) await tester.pumpWidget(const SizedBox());
          var closed = false;
          final closing = host.close().then((_) => closed = true);
          await tester.pump();
          expect(closed, isFalse);
          expect(coreCloses, 0);
          selected.complete(null);
          await pumpReaderUntil(tester, () => closed);
          await closing;
          expect(coreCloses, 1);
          expect(tester.takeException(), isNull);
        } finally {
          if (!selected.isCompleted) selected.complete(null);
          messenger.setMockMethodCallHandler(selector, null);
          await fixture.dispose(tester);
          await host.close();
        }
      },
    );
  }

  for (final detach in [false, true]) {
    testWidgets(
      'host drains queued favorite read before core close; detached=$detach',
      (tester) async {
        final fixture = await ReaderIntegrationFixture.create(tester);
        var coreCloses = 0;
        final host = await readerFixtureHost(() => coreCloses++);
        final release = Completer<void>();
        Future<void>? barrier;
        try {
          await fixture.mount(
            tester,
            pushed: false,
            withWindow: false,
            registry: host.selections,
          );
          barrier = fixture.history.accessImageFavorites(
            (_, _) => release.future,
          );
          readerFixtureImageOwner!.notifyChanges();
          await tester.pump();
          expect(find.byTooltip('Loading image collection'), findsOneWidget);
          if (detach) await tester.pumpWidget(const SizedBox());
          var closed = false;
          final closing = host.close().then((_) => closed = true);
          await tester.pump();
          expect(coreCloses, 0);
          expect(closed, isFalse);
          release.complete();
          await barrier;
          await pumpReaderUntil(tester, () => closed);
          await closing;
          expect(coreCloses, 1);
          expect(fixture.history.hasPendingWrites, isFalse);
          expect(tester.takeException(), isNull);
        } finally {
          if (!release.isCompleted) release.complete();
          await barrier;
          await fixture.dispose(tester);
          await host.close();
        }
      },
    );
  }

  testWidgets(
    'favorite request rejects a replaced database and frozen reader',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final registry = SelectionTaskRegistry();
      final replacement = ControlledReaderHistory();
      try {
        await fixture.mount(
          tester,
          pushed: false,
          withWindow: false,
          registry: registry,
        );
        final reader = fixture.readerKey.currentState!;
        final request = reader.createImageFavoriteRequest()!;
        expect(request.isCurrent(), isTrue);
        await replaceReaderFixtureHistory(tester, replacement);
        expect(request.isCurrent(), isFalse);
        await expectLater(
          Future.sync(() => request.toggle(0, () {})),
          throwsA(isA<ImageWorkTaskCancelled>()),
        );
        await replaceReaderFixtureHistory(
          tester,
          fixture.history,
          images: fixture.images,
        );
        final closing = registry.closeAndWait();
        expect(reader.createImageFavoriteRequest(), isNull);
        expect(reader.createImageFavoriteQuery(), isNull);
        expect(request.isCurrent(), isFalse);
        await tester.pump();
        await closing;
      } finally {
        readerFixtureHistoryOwner = fixture.history;
        readerFixtureImageOwner = fixture.images;
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets(
    'spread favorite status uses source image numbers and prompts for ambiguous selection',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      try {
        appdata.settings['readerScreenPicNumberForLandscape'] = 2;
        appdata.settings['readerScreenPicNumberForPortrait'] = 2;
        appdata.settings['showSingleImageOnFirstPage'] = false;
        await fixture.mount(tester, pushed: false);
        final reader = fixture.readerKey.currentState!;
        expect(reader.pageLayout.imageRange(1, 3), (0, 2));
        expect(await reader.createImageFavoriteQuery()!.read(), isNull);
        expect(find.byTooltip('Select an image to collect'), findsOneWidget);
        await readerFixtureImageOwner!.toggle(
          ImageFavoriteInput(
            id: 'book',
            sourceKey: 'local',
            eid: 'one',
            ep: 1,
            epName: 'Chapter one',
            title: 'Book',
            subtitle: '',
            author: '',
            tags: [],
            translatedTags: [],
            maxPage: 3,
            page: 3,
            imageKey: reader.images![2],
            coverKey: reader.images!.first,
          ),
        );
        reader.toPage(2, animated: false);
        await tester.pumpAndSettle();
        expect(reader.pageLayout.imageRange(reader.page, 3), (2, 3));
        expect(await reader.createImageFavoriteQuery()!.read(), isTrue);
        expect(find.byTooltip('Uncollect the image'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets(
    'root reader waits for platform delivery and admits new exports after later exit failure',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
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
        exporter = readerFixtureExporter(
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
      final fixture = await ReaderIntegrationFixture.create(tester);
      final platform = Completer<void>();
      ReaderImageExporter? exporter;
      try {
        await fixture.mount(tester, pushed: true);
        final reader = fixture.readerKey.currentState!;
        var deliveries = 0;
        exporter = readerFixtureExporter(
          reader,
          save: (_) {
            deliveries++;
            return platform.future;
          },
        );
        final exporting = exporter.export(sharing: false);
        await tester.pump();
        expect(deliveries, 1);

        appNavigation.rootNavigatorKey.currentState!.removeRoute(
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
}
