import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/application_host.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart'
    show ComicSourceManager, configureComicSourceRegistry;
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/features/reader/reader_session.dart';
import 'package:venera_next/features/reader/scaffold.dart';
import 'package:venera_next/features/reader/brightness.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/app_data_operations.dart';

import 'support/reader_integration_fixture.dart';

void main() {
  setUpReaderIntegration();

  testWidgets(
    'source replacement reloads images while exit drains the original chapter',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final manager = ComicSourceManager();
      final oldChapter = Completer<Res<List<String>>>();
      final started = Completer<void>();
      final first = 'file://${LocalManager().path}/book/one/1.png';
      final replacement = 'file://${LocalManager().path}/book/one/2.png';
      var source = ReaderFixturePagesSource((_, ep) {
        if (ep == 'two') {
          if (!started.isCompleted) started.complete();
          return oldChapter.future;
        }
        return Future.value(Res(List.filled(3, first)));
      });
      configureComicSourceRegistry(
        all: manager.all,
        find: (key) => key == 'replacement' ? source : manager.find(key),
        fromIntKey: (key) => key == 42 ? source : manager.fromIntKey(key),
        isEmpty: () => false,
      );
      try {
        appdata.settings['readerMode'] = ReaderMode.waterfallTopToBottom.key;
        await fixture.mount(
          tester,
          pushed: true,
          comicType: const ReaderFixtureOtherComicType(),
          chapters: const ComicChapters({'one': 'One', 'two': 'Two'}),
        );
        final reader = fixture.readerKey.currentState!;
        final originalView = reader.imageViewController!;
        expect(originalView.toChapter(2), isTrue);
        await pumpReaderUntil(tester, () => started.isCompleted);
        source = ReaderFixturePagesSource(
          (_, _) async => Res(List.filled(3, replacement)),
        );
        manager.notifyStateChange();
        await pumpReaderUntil(
          tester,
          () => !reader.isLoading && reader.images?.first == replacement,
        );
        expect(reader.chapter, 1);
        expect(reader.imageViewController, isNot(same(originalView)));
        var closed = false;
        final closing = reader.requestExit().then((_) => closed = true);
        await tester.pump();
        expect(closed, isFalse);
        oldChapter.complete(Res([first]));
        await pumpReaderUntil(tester, () => closed);
        await closing;
        await tester.pumpAndSettle();
        expect(fixture.readerKey.currentState, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        if (!oldChapter.isCompleted) oldChapter.complete(Res([first]));
        await fixture.dispose(tester);
        configureComicSourceRegistry(
          all: manager.all,
          find: manager.find,
          fromIntKey: manager.fromIntKey,
          isEmpty: () => manager.isEmpty,
        );
      }
    },
  );

  for (final detach in [false, true]) {
    testWidgets('application owns no-window reader saves; detached=$detach', (
      tester,
    ) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      var coreCloses = 0;
      final host = await readerFixtureHost(() => coreCloses++);
      final progress = Completer<void>();
      final duration = Completer<void>();
      final replacement = ControlledReaderHistory();
      try {
        await fixture.mount(
          tester,
          pushed: false,
          withWindow: false,
          registry: host.selections,
        );
        final reader = fixture.readerKey.currentState!;
        fixture.history.onProgress = (_) => progress.future;
        fixture.history.onDuration = (_) => duration.future;
        reader.toPage(2, animated: false);
        reader.autoReading.start();
        // A later global manager must not receive this session's final writes.
        await replaceReaderFixtureHistory(tester, replacement);
        if (detach) await tester.pumpWidget(const SizedBox());
        var closed = false;
        final closing = host.close().then((_) => closed = true);
        expect(reader.controller.isDisposed, isTrue);
        expect(reader.toNextPage(), isFalse);
        expect(reader.imageWork.start(), isNull);
        await tester.pump();
        expect(coreCloses, 0);
        expect(closed, isFalse);
        expect(fixture.history.progress.last.page, 2);
        expect(fixture.history.durations, isNotEmpty);
        expect(replacement.progress, isEmpty);
        expect(replacement.durations, isEmpty);
        progress.complete();
        await tester.pump();
        expect(coreCloses, 0);
        duration.complete();
        await pumpReaderUntil(tester, () => closed);
        await closing;
        expect(coreCloses, 1);
        expect(fixture.notifications, 1);
        // Rebuild a still-mounted closed reader, including a new images host.
        if (!detach) {
          reader.mode = ReaderMode.continuousTopToBottom;
          tester.element(find.byType(FixtureReader)).markNeedsBuild();
          await tester.pump();
          expect(reader.controller.isDisposed, isTrue);
        }
        await host.close();
        expect(fixture.notifications, 1);
        expect(tester.takeException(), isNull);
      } finally {
        if (!progress.isCompleted) progress.complete();
        if (!duration.isCompleted) duration.complete();
        await replaceReaderFixtureHistory(
          tester,
          fixture.history,
          images: fixture.images,
        );
        await fixture.dispose(tester);
        await host.sync.closeAndWait();
      }
    });
  }

  for (final earlyFinalClose in [false, true]) {
    testWidgets(
      'window preparation and application share reader close; early final=$earlyFinalClose',
      (tester) async {
        final fixture = await ReaderIntegrationFixture.create(tester);
        var closes = 0;
        final host = await readerFixtureHost(() => closes++);
        final saving = Completer<void>();
        try {
          await fixture.mount(
            tester,
            pushed: false,
            registry: host.selections,
            finalize: (drain) => host.close(drain: drain),
          );
          final reader = fixture.readerKey.currentState!;
          fixture.history.onProgress = (_) => saving.future;
          reader.toPage(2, animated: false);
          fixture.closeWindow(tester);
          await tester.pump();
          expect(closes, 0);
          expect(fixture.exits, 0);
          expect(reader.controller.isDisposed, isFalse);
          Future<void>? earlyClose;
          if (earlyFinalClose) {
            earlyClose = host.close();
            expect(reader.controller.isDisposed, isTrue);
            await tester.pump();
            expect(closes, 0);
          }
          saving.complete();
          await pumpReaderUntil(tester, () => fixture.exits == 1);
          await earlyClose;
          expect(closes, 1);
          expect(reader.controller.isDisposed, isTrue);
          expect(fixture.notifications, 1);
          expect(tester.takeException(), isNull);
        } finally {
          if (!saving.isCompleted) saving.complete();
          await fixture.dispose(tester);
          await host.sync.closeAndWait();
        }
      },
    );
  }

  testWidgets(
    'application waits for real reader setting persistence after removal',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      var closes = 0;
      final host = await readerFixtureHost(() => closes++);
      final release = Completer<void>();
      Future<void>? exclusive;
      try {
        appdata.settings['readerBrightnessEnabled'] = true;
        appdata.settings['readerBrightness'] = 50;
        await fixture.mount(
          tester,
          pushed: false,
          withWindow: false,
          registry: host.selections,
        );
        exclusive = AppDataOperations.instance.run(() => release.future);
        tester
            .widget<ReaderBrightnessControl>(
              find.byType(ReaderBrightnessControl),
            )
            .onBrightnessChanged(20);
        await tester.pump();
        expect(appdata.settings['readerBrightness'], 50);
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        final closing = host.close().then((_) => closed = true);
        await tester.pump();
        expect(closes, 0);
        expect(closed, isFalse);
        release.complete();
        await pumpReaderUntil(tester, () => closed);
        await closing;
        expect(closes, 1);
        expect(appdata.settings['readerBrightness'], 20);
        final stored =
            jsonDecode(
                  File(
                    '${fixture.directory.path}/appdata.json',
                  ).readAsStringSync(),
                )
                as Map;
        expect((stored['settings'] as Map)['readerBrightness'], 20);
        expect(tester.takeException(), isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        if (exclusive != null) await exclusive;
        await fixture.dispose(tester);
        await host.sync.closeAndWait();
      }
    },
  );

  testWidgets(
    'initial read-later write belongs to original host before child binding',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      var closes = 0;
      final host = await readerFixtureHost(() => closes++);
      final reading = Completer<void>();
      final favorites = readerFixtureFavoritesOwner! as ReaderFixtureFavorites;
      favorites.reading = reading.future;
      try {
        await fixture.mount(
          tester,
          pushed: false,
          withWindow: false,
          registry: host.selections,
        );
        expect(favorites.reads, 1);
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        final closing = host.close().then((_) => closed = true);
        await tester.pump();
        expect(closed, isFalse);
        expect(closes, 0);
        reading.complete();
        await pumpReaderUntil(tester, () => closed);
        await closing;
        expect(closes, 1);
        expect(favorites.reads, 1);
        expect(tester.takeException(), isNull);
      } finally {
        if (!reading.isCompleted) reading.complete();
        await fixture.dispose(tester);
        await host.sync.closeAndWait();
      }
    },
  );

  testWidgets(
    'host retries retain uncertain duration failure without replaying the period',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      var closes = 0;
      final host = await readerFixtureHost(() => closes++);
      final cause = StateError('uncertain duration');
      final error = PersistenceFailure(
        stackTrace: StackTrace.current,
        cause: cause,
        commitState: PersistenceCommitState.unknown,
      );
      try {
        await fixture.mount(
          tester,
          pushed: false,
          withWindow: false,
          registry: host.selections,
        );
        fixture.history.onDuration = (_) async => throw error;
        ApplicationCloseFailure? first;
        for (var attempt = 0; attempt < 2; attempt++) {
          ApplicationCloseFailure? failure;
          var settled = false;
          final closing = host
              .close()
              .catchError((Object error) {
                failure = error as ApplicationCloseFailure;
              })
              .whenComplete(() => settled = true);
          await pumpReaderUntil(tester, () => settled);
          await closing;
          expect(failure, isNotNull);
          if (first == null) {
            first = failure;
          } else {
            final firstSelection =
                first.failures.first.error as SelectionCleanupFailure;
            final nextSelection =
                failure!.failures.first.error as SelectionCleanupFailure;
            expect(
              (nextSelection.failures.single
                      as ({Object error, StackTrace stack}))
                  .error,
              same(
                (firstSelection.failures.single
                        as ({Object error, StackTrace stack}))
                    .error,
              ),
            );
          }
          expect(fixture.history.durations.length, 1);
          expect(closes, 0);
        }
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
        await host.sync.closeAndWait();
      }
    },
  );

  testWidgets(
    'closed application refuses a newly mounted reader before initialization work',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final registry = SelectionTaskRegistry();
      await registry.closeAndWait();
      try {
        await fixture.mount(
          tester,
          pushed: false,
          withWindow: false,
          registry: registry,
          expectContent: false,
          volumeConnect: (_) =>
              throw StateError('closed host must not activate volume'),
        );
        final reader = fixture.readerKey.currentState!;
        expect(reader.controller.isDisposed, isTrue);
        expect(reader.images, isNull);
        expect(reader.imageWork.start(), isNull);
        expect(
          (readerFixtureFavoritesOwner! as ReaderFixtureFavorites).reads,
          0,
        );
        expect(fixture.history.progress, isEmpty);
        expect(fixture.history.durations, isEmpty);
        expect(fixture.notifications, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets('reparented reader remains owned by its original application', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    final first = SelectionTaskRegistry();
    final second = SelectionTaskRegistry();
    final registries = ValueNotifier(first);
    final saving = Completer<void>();
    try {
      await fixture.mount(
        tester,
        pushed: false,
        withWindow: false,
        registries: registries,
      );
      final reader = fixture.readerKey.currentState!;
      fixture.history.onProgress = (_) => saving.future;
      reader.toPage(2, animated: false);
      registries.value = second;
      await tester.pump();
      expect(fixture.readerKey.currentState, same(reader));
      expect(reader.controller.isDisposed, isTrue);
      await second.closeAndWait();
      var closed = false;
      final closing = first.closeAndWait().then((_) => closed = true);
      await tester.pump();
      expect(closed, isFalse);
      saving.complete();
      await pumpReaderUntil(tester, () => closed);
      await closing;
      expect(fixture.notifications, 1);
      expect(tester.takeException(), isNull);
    } finally {
      if (!saving.isCompleted) saving.complete();
      await fixture.dispose(tester);
      registries.dispose();
    }
  });

  testWidgets(
    'consumed reader image failure still blocks original core close',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      var closes = 0;
      final host = await readerFixtureHost(() => closes++);
      final error = StateError('late reader image cleanup');
      final stack = StackTrace.fromString('original reader task stack');
      try {
        await fixture.mount(
          tester,
          pushed: false,
          withWindow: false,
          registry: host.selections,
        );
        final reader = fixture.readerKey.currentState!;
        final task = reader.imageWork.start()!;
        task.recordFailure(error, stack);
        task.finish();
        final reported = expectLater(
          reader.imageWork.prepareForExit(),
          throwsA(isA<ImageWorkFailure>()),
        );
        await tester.pump();
        await reported;
        await tester.pumpWidget(const SizedBox());
        for (var attempt = 0; attempt < 2; attempt++) {
          ApplicationCloseFailure? failure;
          var settled = false;
          final closing = host
              .close()
              .catchError((Object error) {
                failure = error as ApplicationCloseFailure;
              })
              .whenComplete(() => settled = true);
          await pumpReaderUntil(tester, () => settled);
          await closing;
          final selection =
              failure!.failures
                      .firstWhere((item) => item.owner == 'selection tasks')
                      .error
                  as SelectionCleanupFailure;
          final original =
              selection.failures
                      .whereType<({Object error, StackTrace stack})>()
                      .where((entry) => entry.error is ImageWorkFailure)
                      .single
                      .error
                  as ImageWorkFailure;
          expect(original.failures, [(error: error, stack: stack)]);
          expect(closes, 0);
        }
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
        await host.sync.closeAndWait();
      }
    },
  );

  for (final detach in [false, true]) {
    testWidgets(
      'favorite write blocks ${detach ? 'window after forced unmount' : 'reader back'} until real completion',
      (tester) async {
        final fixture = await ReaderIntegrationFixture.create(tester);
        final pending = Completer<void>();
        final favorites =
            readerFixtureFavoritesOwner! as ReaderFixtureFavorites;
        favorites.reading = pending.future;
        try {
          await fixture.mount(tester, pushed: true);
          expect(favorites.reads, 1);
          if (detach) {
            appNavigation.rootNavigatorKey.currentState!.pop();
            await tester.pumpAndSettle();
            fixture.closeWindow(tester);
            await tester.pump();
            expect(fixture.exits, 0);
          } else {
            unawaited(appNavigation.rootNavigatorKey.currentState!.maybePop());
            await tester.pump(const Duration(milliseconds: 400));
            expect(fixture.readerKey.currentState, isNotNull);
          }
          pending.complete();
          await pumpReaderUntil(
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

  testWidgets(
    'reader toolbar retains a failed save, then saves newer progress before pop',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
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
        expect(appNavigation.rootNavigatorKey.currentState!.canPop(), isTrue);
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
      final fixture = await ReaderIntegrationFixture.create(tester);
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
      final fixture = await ReaderIntegrationFixture.create(tester);
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
      final fixture = await ReaderIntegrationFixture.create(tester);
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
        expect(appNavigation.rootNavigatorKey.currentState!.canPop(), isFalse);
        reader.setPage(2);
        reader.autoReading.start();
        final progressRequest = reader.createProgressRequest();
        final durationWrites = fixture.history.durations.length;
        fixture.frame.trackExitTask(oldSave.future);
        fixture.closeWindow(tester);
        // The real session receives the synchronous window notification even
        // though a previously detached owner's save blocks its exit task.
        expect(reader.autoReading.status, AutoReadingStatus.paused);
        expect(progressRequest.selectPage(3), isFalse);
        expect(progressRequest.next(), isFalse);
        expect(reader.toggleAutomaticReading(), isFalse);
        expect(reader.readImagePickContext(), isNull);
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
        expect(progressRequest.selectPage(3), isTrue);
        fixture.closeWindow(tester);
        // The fixture records a native exit without removing its root reader.
        // A newly visited page can keep its loading animation mounted.
        await pumpReaderUntil(tester, () => fixture.exits == 1);
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
        final fixture = await ReaderIntegrationFixture.create(tester);
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
            // This fixture records exit without removing the root reader. A
            // fresh page can retain a loading indicator after image admission
            // closes, so wait for shutdown itself instead of all animations.
            await pumpReaderUntil(tester, () => fixture.exits == 1);
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
