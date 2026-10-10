import 'package:venera_next/features/sync/data_sync_controller.dart';
import '../support/data_sync_fixture.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/sync_window_binding.dart';
import 'package:venera_next/app_runtime/interactive_bindings.dart';
import 'package:venera_next/foundation/event_subscription.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/window_placement.dart';
import 'package:venera_next/foundation/window_placement_tracker.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  late SyncTestFixture fixture;
  late _PendingHistory historyOwner;
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    fixture = SyncTestFixture();
    historyOwner = _PendingHistory(() async {});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => false,
        );
  });
  tearDown(() {
    historyOwner.dispose();
    fixture.disposeController();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  testWidgets('detaching during final close does not reopen prepared owners', (
    tester,
  ) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    final finalizing = Completer<void>();
    var isFinalizing = false;
    var releases = 0;
    var exits = 0;
    historyOwner = _PendingHistory(() async {});
    Future<VoidCallback> prepare() async =>
        () => releases++;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => WindowFrame(
          child!,
          finalize: (_) {
            isFinalizing = true;
            return finalizing.future;
          },
          onExit: () => exits++,
        ),
        home: ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (_, show, _) => show
              ? SyncWindowBinding(
                  waitForHistoryWrites: historyOwner.waitForAsyncWrites,
                  controller: fixture.controller,
                  isFinalizing: () => isFinalizing,
                  prepareInteractive: prepare,
                  prepareFollowUpdates: prepare,
                  prepareWebDavLibrary: prepare,
                  prepareDownloads: prepare,
                  prepareImages: prepare,
                  prepareImports: prepare,
                  child: const Scaffold(),
                )
              : const Scaffold(),
        ),
      ),
    );
    (tester.state(find.byType(WindowFrame)) as WindowListener).onWindowClose();
    await tester.pump();
    expect(isFinalizing, isTrue);
    visible.value = false;
    await tester.pump();
    expect(releases, 0);
    finalizing.complete();
    await tester.pumpAndSettle();
    expect(exits, 1);
    expect(releases, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'window drains placement reads and saves, resumes after failure and retries',
    (tester) async {
      const first = WindowPlacement(Rect.fromLTWH(20, 30, 900, 700), false);
      const moved = WindowPlacement(Rect.fromLTWH(50, 60, 1100, 800), true);
      final firstRead = Completer<WindowPlacement>();
      final firstSave = Completer<void>();
      final firstFollow = Completer<VoidCallback>();
      final failure = StateError('follow preparation failed after placement');
      final saved = <WindowPlacement>[];
      final events = <String>[];
      var current = first;
      var reads = 0;
      var followAttempts = 0;
      var exits = 0;
      final placement = WindowPlacementTracker(
        ready: Future.value(),
        read: () {
          reads++;
          return reads == 1 ? firstRead.future : Future.value(current);
        },
        save: (value) async {
          saved.add(value);
          if (saved.length == 1) await firstSave.future;
        },
      );
      final interactive = InteractiveBindings(
        android: false,
        windows: false,
        placement: placement,
        links: () => throw StateError('desktop has no Android link binding'),
        shares: () => throw StateError('desktop has no Android share binding'),
        heartbeat: () async {},
      )..start();
      historyOwner = _PendingHistory(() async {
        events.add('history');
      });
      Future<VoidCallback> prepare(String stage) async {
        events.add(stage);
        return () {};
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: appNavigation.rootNavigatorKey,
            builder: (_, child) => WindowFrame(
              SyncWindowBinding(
                waitForHistoryWrites: historyOwner.waitForAsyncWrites,
                controller: fixture.controller,
                prepareInteractive: interactive.prepareForExit,
                prepareFollowUpdates: () {
                  events.add('follow ${++followAttempts}');
                  return followAttempts == 1
                      ? firstFollow.future
                      : Future.value(() {});
                },
                prepareWebDavLibrary: () => prepare('WebDAV'),
                prepareImports: () => prepare('imports'),
                prepareDownloads: () => prepare('downloads'),
                prepareImages: () => prepare('images'),
                child: child!,
              ),
              onExit: () => exits++,
            ),
            home: const Scaffold(),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(reads, 1);
        void close() =>
            (tester.state(find.byType(WindowFrame)) as WindowListener)
                .onWindowClose();
        close();
        close();
        await tester.pump(const Duration(milliseconds: 500));
        expect(reads, 1);
        expect(saved, isEmpty);
        expect(events, isEmpty);
        expect(exits, 0);

        firstRead.complete(first);
        await tester.pump();
        expect(saved, [first]);
        await tester.pump(const Duration(milliseconds: 500));
        expect(reads, 1);
        expect(events, isEmpty);
        expect(exits, 0);

        firstSave.complete();
        await tester.pump();
        expect(reads, 2); // The final placement is sampled after the old save.
        expect(events, ['follow 1']);
        await tester.pump(const Duration(milliseconds: 250));
        expect(reads, 2);
        expect(exits, 0);

        firstFollow.completeError(failure);
        await tester.pump();
        expect(tester.takeException(), same(failure));
        expect(events, ['follow 1']);
        expect(exits, 0);
        current = moved;
        await tester.pump(const Duration(milliseconds: 100));
        expect(reads, 3);
        expect(saved, [first, moved]);

        close();
        await tester.pump();
        expect(reads, 4);
        expect(saved, [first, moved]);
        expect(events, [
          'follow 1',
          'follow 2',
          'WebDAV',
          'imports',
          'downloads',
          'images',
          'history',
        ]);
        expect(exits, 1);
        await tester.pump(const Duration(milliseconds: 250));
        expect(reads, 4);
        expect(tester.takeException(), isNull);
      } finally {
        if (!firstRead.isCompleted) firstRead.complete(first);
        if (!firstSave.isCompleted) firstSave.complete();
        if (!firstFollow.isCompleted) firstFollow.complete(() {});
        await tester.pump();
        await tester.runAsync(interactive.dispose);
        await tester.pumpWidget(const SizedBox());
      }
      final readsAtDisposal = reads;
      await tester.pump(const Duration(seconds: 1));
      expect(reads, readsAtDisposal);
      expect(placement.start, throwsStateError);
    },
    skip: !Platform.isWindows,
  );

  for (final detach in [false, true]) {
    testWidgets(
      'platform events drain before services and recover; detach=$detach',
      (tester) async {
        final links = StreamController<Uri>();
        final shares = StreamController<Object?>();
        final activeEvent = Completer<void>();
        final follow = Completer<VoidCallback>();
        final seen = <Object?>[];
        final events = <String>[];
        var releases = 0;
        final interactive = InteractiveBindings(
          android: true,
          windows: false,
          links: () => EventSubscription(
            events: links.stream,
            handle: (event, active) async {},
            onError: (error, stack) => fail('$error'),
          ),
          shares: () => EventSubscription(
            events: shares.stream,
            handle: (event, active) async {
              if (event == 'old') await activeEvent.future;
              if (active()) seen.add(event);
            },
            onError: (error, stack) => fail('$error'),
          ),
          heartbeat: () async {},
        )..start();
        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) => WindowFrame(
              SyncWindowBinding(
                waitForHistoryWrites: historyOwner.waitForAsyncWrites,
                controller: fixture.controller,
                prepareInteractive: interactive.prepareForExit,
                prepareFollowUpdates: () {
                  events.add('follow');
                  return follow.future;
                },
                prepareImports: () async {
                  events.add('imports');
                  return () {};
                },
                child: child!,
              ),
              onExit: () => events.add('exit'),
            ),
            home: const Scaffold(),
          ),
        );
        shares.add('old');
        await tester.pump();
        (tester.state(find.byType(WindowFrame)) as WindowListener)
            .onWindowClose();
        await tester.pump();
        expect(events, isEmpty);
        activeEvent.complete();
        await tester.pump();
        expect(events, ['follow']);
        expect(seen, isEmpty);
        if (detach) await tester.pumpWidget(const SizedBox());
        shares.add('rejected');
        await tester.pump();
        expect(seen, isEmpty);
        if (detach) {
          follow.complete(() => releases++);
        } else {
          follow.completeError(StateError('preparation failed'));
        }
        await tester.pump();
        if (!detach) expect(tester.takeException(), isA<StateError>());
        expect(releases, detach ? 1 : 0);
        shares.add('restored');
        await tester.pump();
        expect(seen, ['restored']);
        expect(events, ['follow']);
        await tester.pumpWidget(const SizedBox());
        // Stream cancellation can complete in the real async zone.
        await tester.runAsync(() async {
          await interactive.dispose();
          await Future.wait([links.close(), shares.close()]);
        });
      },
      skip: !Platform.isWindows,
    );
  }

  for (final detach in [false, true]) {
    testWidgets(
      'follow updates settle before storage preparation; detach=$detach',
      (tester) async {
        final followUpdates = Completer<VoidCallback>();
        final events = <String>[];
        var releases = 0;
        var exits = 0;
        fixture = SyncTestFixture(persistImplicit: () => events.add('sync'));
        historyOwner = _PendingHistory(() async {
          events.add('history');
        });
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: appNavigation.rootNavigatorKey,
            builder: (_, child) => WindowFrame(
              SyncWindowBinding(
                waitForHistoryWrites: historyOwner.waitForAsyncWrites,
                controller: fixture.controller,
                prepareFollowUpdates: () {
                  events.add('follow updates');
                  return followUpdates.future;
                },
                prepareImports: () async {
                  events.add('imports');
                  return () {};
                },
                prepareDownloads: () async {
                  events.add('downloads');
                  return () {};
                },
                child: child!,
              ),
              onExit: () => exits++,
            ),
            home: const Scaffold(),
          ),
        );
        final close = tester
            .widgetList<WindowButton>(find.byType(WindowButton))
            .last;
        close.onPressed();
        close.onPressed();
        await tester.pump();
        expect(events, ['follow updates']);
        expect(exits, 0);
        if (detach) await tester.pumpWidget(const SizedBox());
        followUpdates.complete(() => releases++);
        await tester.pump();
        expect(
          events,
          detach
              ? ['follow updates']
              : ['follow updates', 'imports', 'downloads', 'history', 'sync'],
        );
        expect(exits, detach ? 0 : 1);
        expect(releases, detach ? 1 : 0);
        await tester.pumpWidget(const SizedBox());
        expect(releases, 1);
      },
      skip: !Platform.isWindows,
    );
  }

  for (final detach in [false, true]) {
    testWidgets(
      'WebDAV settles after follow updates and before storage; detach=$detach',
      (tester) async {
        final followUpdates = Completer<VoidCallback>();
        final webDav = Completer<VoidCallback>();
        final events = <String>[];
        final released = <String>[];
        var exits = 0;
        fixture = SyncTestFixture(persistImplicit: () => events.add('sync'));
        historyOwner = _PendingHistory(() async {
          events.add('history');
        });
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: appNavigation.rootNavigatorKey,
            builder: (_, child) => WindowFrame(
              SyncWindowBinding(
                waitForHistoryWrites: historyOwner.waitForAsyncWrites,
                controller: fixture.controller,
                prepareFollowUpdates: () {
                  events.add('follow updates');
                  return followUpdates.future;
                },
                prepareWebDavLibrary: () {
                  events.add('WebDAV');
                  return webDav.future;
                },
                prepareImports: () async {
                  events.add('imports');
                  return () => released.add('imports');
                },
                prepareDownloads: () async {
                  events.add('downloads');
                  return () => released.add('downloads');
                },
                child: child!,
              ),
              onExit: () => exits++,
            ),
            home: const Scaffold(),
          ),
        );
        final close = tester
            .widgetList<WindowButton>(find.byType(WindowButton))
            .last;
        close.onPressed();
        close.onPressed();
        await tester.pump();
        expect(events, ['follow updates']);
        followUpdates.complete(() => released.add('follow updates'));
        await tester.pump();
        expect(events, ['follow updates', 'WebDAV']);
        expect(exits, 0);
        if (detach) await tester.pumpWidget(const SizedBox());
        expect(released, isEmpty);

        webDav.complete(() => released.add('WebDAV'));
        await tester.pump();
        expect(
          events,
          detach
              ? ['follow updates', 'WebDAV']
              : [
                  'follow updates',
                  'WebDAV',
                  'imports',
                  'downloads',
                  'history',
                  'sync',
                ],
        );
        expect(exits, detach ? 0 : 1);
        expect(released, detach ? ['WebDAV', 'follow updates'] : isEmpty);
        await tester.pumpWidget(const SizedBox());
        expect(
          released,
          detach
              ? ['WebDAV', 'follow updates']
              : ['downloads', 'imports', 'WebDAV', 'follow updates'],
        );
      },
      skip: !Platform.isWindows,
    );
  }

  for (final detach in [false, true]) {
    testWidgets(
      'images drain after downloads and before persistence; detach=$detach',
      (tester) async {
        final images = Completer<VoidCallback>();
        final events = <String>[];
        final released = <String>[];
        var exits = 0;
        fixture.disposeController();
        fixture = SyncTestFixture(persistImplicit: () => events.add('sync'));
        historyOwner = _PendingHistory(() async {
          events.add('history');
        });
        Future<VoidCallback> prepare(String stage) async {
          events.add(stage);
          return () => released.add(stage);
        }

        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: appNavigation.rootNavigatorKey,
            builder: (_, child) => WindowFrame(
              SyncWindowBinding(
                waitForHistoryWrites: historyOwner.waitForAsyncWrites,
                controller: fixture.controller,
                prepareInteractive: () => prepare('interactive'),
                prepareFollowUpdates: () => prepare('follow'),
                prepareWebDavLibrary: () => prepare('WebDAV'),
                prepareImports: () => prepare('imports'),
                prepareDownloads: () => prepare('downloads'),
                prepareImages: () {
                  events.add('images');
                  return images.future;
                },
                child: child!,
              ),
              onExit: () => exits++,
            ),
            home: const Scaffold(),
          ),
        );
        final window = tester.state(find.byType(WindowFrame)) as WindowListener;
        window.onWindowClose();
        window.onWindowClose();
        await tester.pump();
        const preparation = [
          'interactive',
          'follow',
          'WebDAV',
          'imports',
          'downloads',
          'images',
        ];
        expect(events, preparation);
        expect(exits, 0);
        if (detach) await tester.pumpWidget(const SizedBox());
        expect(released, isEmpty);
        images.complete(() => released.add('images'));
        await tester.pump();
        expect(
          events,
          detach ? preparation : [...preparation, 'history', 'sync'],
        );
        expect(exits, detach ? 0 : 1);
        const restoration = [
          'images',
          'downloads',
          'imports',
          'WebDAV',
          'follow',
          'interactive',
        ];
        expect(released, detach ? restoration : isEmpty);
        await tester.pumpWidget(const SizedBox());
        expect(released, restoration);
      },
      skip: !Platform.isWindows,
    );
  }

  testWidgets(
    'failed image preparation restores earlier holds and permits another close',
    (tester) async {
      final failure = StateError('image preparation');
      final released = <String>[];
      var attempts = 0;
      var historyCalls = 0;
      var exits = 0;
      historyOwner = _PendingHistory(() async {
        historyCalls++;
      });
      Future<VoidCallback> prepare(String stage) async {
        final attempt = attempts;
        return () => released.add('$stage $attempt');
      }

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: appNavigation.rootNavigatorKey,
          builder: (_, child) => WindowFrame(
            SyncWindowBinding(
              waitForHistoryWrites: historyOwner.waitForAsyncWrites,
              controller: fixture.controller,
              prepareInteractive: () {
                attempts++;
                return prepare('interactive');
              },
              prepareFollowUpdates: () => prepare('follow'),
              prepareWebDavLibrary: () => prepare('WebDAV'),
              prepareImports: () => prepare('imports'),
              prepareDownloads: () => prepare('downloads'),
              prepareImages: () {
                if (attempts == 1) throw failure;
                return prepare('images');
              },
              child: child!,
            ),
            onExit: () => exits++,
          ),
          home: const Scaffold(),
        ),
      );
      void close() => (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      close();
      await tester.pump();
      expect(tester.takeException(), same(failure));
      expect(historyCalls, 0);
      expect(exits, 0);
      expect(released, [
        'downloads 1',
        'imports 1',
        'WebDAV 1',
        'follow 1',
        'interactive 1',
      ]);
      close();
      await tester.pump();
      expect(attempts, 2);
      expect(historyCalls, 1);
      expect(exits, 1);
      await tester.pumpWidget(const SizedBox());
      expect(released, [
        'downloads 1',
        'imports 1',
        'WebDAV 1',
        'follow 1',
        'interactive 1',
        'images 2',
        'downloads 2',
        'imports 2',
        'WebDAV 2',
        'follow 2',
        'interactive 2',
      ]);
    },
    skip: !Platform.isWindows,
  );

  for (final failureStage in ['WebDAV', 'imports']) {
    testWidgets(
      'failed $failureStage preparation releases owners and permits retry',
      (tester) async {
        final firstWebDav = Completer<VoidCallback>();
        final released = <String>[];
        final failure = StateError('$failureStage preparation failed');
        var attempts = 0;
        var importCalls = 0;
        var exits = 0;
        historyOwner = _PendingHistory(() async {});
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: appNavigation.rootNavigatorKey,
            builder: (_, child) => WindowFrame(
              SyncWindowBinding(
                waitForHistoryWrites: historyOwner.waitForAsyncWrites,
                controller: fixture.controller,
                prepareFollowUpdates: () async {
                  final attempt = ++attempts;
                  return () => released.add('follow $attempt');
                },
                prepareWebDavLibrary: () async {
                  final attempt = attempts;
                  if (attempt == 1) return firstWebDav.future;
                  return () => released.add('WebDAV $attempt');
                },
                prepareImports: () async {
                  importCalls++;
                  final attempt = attempts;
                  if (attempt == 1) throw failure;
                  return () => released.add('imports $attempt');
                },
                prepareDownloads: () async {
                  final attempt = attempts;
                  return () => released.add('downloads $attempt');
                },
                child: child!,
              ),
              onExit: () => exits++,
            ),
            home: const Scaffold(),
          ),
        );
        void close() => tester
            .widgetList<WindowButton>(find.byType(WindowButton))
            .last
            .onPressed();
        close();
        await tester.pump();
        expect(importCalls, 0);
        expect(exits, 0);
        if (failureStage == 'WebDAV') {
          firstWebDav.completeError(failure);
        } else {
          firstWebDav.complete(() => released.add('WebDAV 1'));
        }
        await tester.pump();
        expect(tester.takeException(), same(failure));
        expect(exits, 0);
        expect(
          released,
          failureStage == 'WebDAV' ? ['follow 1'] : ['WebDAV 1', 'follow 1'],
        );
        close();
        await tester.pump();
        expect(attempts, 2);
        expect(importCalls, failureStage == 'WebDAV' ? 1 : 2);
        expect(exits, 1);
        await tester.pumpWidget(const SizedBox());
        expect(released, [
          if (failureStage == 'imports') 'WebDAV 1',
          'follow 1',
          'downloads 2',
          'imports 2',
          'WebDAV 2',
          'follow 2',
        ]);
      },
      skip: !Platform.isWindows,
    );
  }

  testWidgets(
    'idle close waits for persistence, releases on failure and retries',
    (tester) async {
      final firstSave = Completer<void>();
      var saves = 0;
      var releases = 0;
      var followReleases = 0;
      var exits = 0;
      fixture = SyncTestFixture(
        persistImplicit: () {
          saves++;
          if (saves == 1) return firstSave.future;
        },
      );
      historyOwner = _PendingHistory(() async {});
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: appNavigation.rootNavigatorKey,
          builder: (_, child) => WindowFrame(
            SyncWindowBinding(
              waitForHistoryWrites: historyOwner.waitForAsyncWrites,
              controller: fixture.controller,
              prepareFollowUpdates: () async =>
                  () => followReleases++,
              prepareImports: () async =>
                  () => releases++,
              prepareDownloads: () async =>
                  () => releases++,
              child: child!,
            ),
            onExit: () => exits++,
          ),
          home: const Scaffold(),
        ),
      );
      void close() => tester
          .widgetList<WindowButton>(find.byType(WindowButton))
          .last
          .onPressed();
      close();
      await tester.pump();
      expect(saves, 1);
      expect(exits, 0);
      firstSave.completeError(StateError('save failed'));
      await tester.pump();
      expect(tester.takeException(), isA<StateError>());
      expect(exits, 0);
      expect(releases, 2);
      expect(followReleases, 1);
      close();
      await tester.pump();
      expect(saves, 2);
      expect(exits, 1);
      await tester.pumpWidget(const SizedBox());
      expect(releases, 4);
      expect(followReleases, 2);
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'window close waits for an active download and persistence',
    (tester) async {
      final download = Completer<Res<bool>>();
      var exits = 0;
      fixture.transfer.onDownload = () => download.future;
      historyOwner = _PendingHistory(() async {});
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: appNavigation.rootNavigatorKey,
          builder: (_, child) => WindowFrame(
            SyncWindowBinding(
              waitForHistoryWrites: historyOwner.waitForAsyncWrites,
              controller: fixture.controller,
              prepareImports: () async => () {},
              prepareDownloads: () async => () {},
              child: child!,
            ),
            onExit: () => exits++,
          ),
          home: const Scaffold(),
        ),
      );
      final task = fixture.controller.downloadData();
      tester
          .widgetList<WindowButton>(find.byType(WindowButton))
          .last
          .onPressed();
      await tester.pump();
      expect(exits, 0);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      download.complete(const Res(false));
      await task;
      await tester.pumpAndSettle();
      expect(exits, 1);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
    skip: !Platform.isWindows,
  );

  for (final mode in ['success', 'failure', 'detach', 'no-root']) {
    testWidgets('window shutdown feedback and exit guards: $mode', (
      tester,
    ) async {
      final pending = Completer<void>();
      final sync = _WaitingSync(pending.future);
      var importsReleased = 0;
      var downloadsReleased = 0;
      var exits = 0;
      historyOwner = _PendingHistory(() async {});
      Widget host(bool bound) => MaterialApp(
        navigatorKey: mode == 'no-root' ? null : appNavigation.rootNavigatorKey,
        builder: (_, child) => WindowFrame(
          bound
              ? SyncWindowBinding(
                  waitForHistoryWrites: historyOwner.waitForAsyncWrites,
                  controller: sync,
                  prepareImports: () async =>
                      () => importsReleased++,
                  prepareDownloads: () async =>
                      () => downloadsReleased++,
                  child: child!,
                )
              : child!,
          onExit: () => exits++,
        ),
        home: const Scaffold(),
      );
      await tester.pumpWidget(host(true));
      tester
          .widgetList<WindowButton>(find.byType(WindowButton))
          .last
          .onPressed();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(exits, 0);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      if (mode == 'detach') {
        await tester.pumpWidget(host(false));
        await tester.pump();
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(exits, 0);
        // Earlier producers stay frozen until the pending sync hold settles.
        expect(importsReleased, 0);
        expect(downloadsReleased, 0);
      }
      if (mode == 'failure') {
        pending.completeError(StateError('upload wait failed'));
      } else {
        pending.complete();
      }
      await tester.pumpAndSettle();
      if (mode == 'failure') {
        expect(tester.takeException(), isA<StateError>());
        expect(exits, 0);
        expect(importsReleased, 1);
        expect(downloadsReleased, 1);
      } else {
        expect(exits, 1);
      }
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(importsReleased, 1);
      expect(downloadsReleased, 1);
      expect(tester.takeException(), isNull);
    }, skip: !Platform.isWindows);
  }

  for (final detach in [false, true]) {
    testWidgets(
      'exit drains imports and releases when download preparation fails or detaches: $detach',
      (tester) async {
        final imports = Completer<VoidCallback>();
        final downloads = Completer<VoidCallback>();
        var importReleases = 0;
        var downloadCalls = 0;
        var exits = 0;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: appNavigation.rootNavigatorKey,
            builder: (_, child) => WindowFrame(
              SyncWindowBinding(
                waitForHistoryWrites: historyOwner.waitForAsyncWrites,
                controller: fixture.controller,
                prepareImports: () => imports.future,
                prepareDownloads: () {
                  downloadCalls++;
                  return downloads.future;
                },
                child: child!,
              ),
              onExit: () => exits++,
            ),
            home: const Scaffold(body: Text('shutdown')),
          ),
        );
        tester
            .widgetList<WindowButton>(find.byType(WindowButton))
            .last
            .onPressed();
        await tester.pump();
        expect(downloadCalls, 0);
        expect(exits, 0);
        if (detach) await tester.pumpWidget(const SizedBox());
        imports.complete(() => importReleases++);
        await tester.pump();
        if (!detach) {
          expect(downloadCalls, 1);
          downloads.completeError(StateError('download preparation failed'));
          await tester.pump();
          expect(tester.takeException(), isA<StateError>());
        }
        expect(importReleases, 1);
        expect(exits, 0);
        await tester.pumpWidget(const SizedBox());
        expect(importReleases, 1);
      },
      skip: !Platform.isWindows,
    );
  }

  for (final failHistory in [false, true]) {
    testWidgets(
      'exit waits for downloads and releases on history failure: $failHistory',
      (tester) async {
        final downloads = Completer<VoidCallback>();
        final history = Completer<void>();
        var releases = 0;
        var exits = 0;
        final events = <String>[];
        historyOwner = _PendingHistory(() {
          events.add('history');
          return history.future;
        });
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: appNavigation.rootNavigatorKey,
            builder: (_, child) => WindowFrame(
              SyncWindowBinding(
                waitForHistoryWrites: historyOwner.waitForAsyncWrites,
                controller: fixture.controller,
                prepareDownloads: () {
                  events.add('downloads');
                  return downloads.future;
                },
                child: child!,
              ),
              onExit: () => exits++,
            ),
            home: const Scaffold(body: Text('shutdown')),
          ),
        );
        tester
            .widgetList<WindowButton>(find.byType(WindowButton))
            .last
            .onPressed();
        await tester.pump();
        expect(events, ['downloads']);
        expect(exits, 0);
        downloads.complete(() => releases++);
        await tester.pump();
        expect(events, ['downloads', 'history']);
        if (failHistory) {
          history.completeError(StateError('history failure'));
        } else {
          history.complete();
        }
        await tester.pump();
        if (failHistory) {
          expect(tester.takeException(), isA<StateError>());
          expect(exits, 0);
          expect(releases, 1);
        } else {
          expect(exits, 1);
          expect(releases, 0);
        }
        await tester.pumpWidget(const SizedBox());
        expect(releases, 1);
      },
      skip: !Platform.isWindows,
    );
  }

  for (final detached in [false, true]) {
    testWidgets(
      'shutdown drains reader then history then upload; detached=$detached',
      (tester) async {
        final saved = Completer<void>();
        final history = Completer<void>();
        final uploaded = Completer<Res<bool>>();
        final events = <String>[];
        historyOwner = _PendingHistory(() {
          events.add('history');
          return history.future;
        });
        fixture.transfer.onUpload = () {
          events.add('upload');
          return uploaded.future;
        };
        var exits = 0;
        late WindowFrameController frame;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: appNavigation.rootNavigatorKey,
            builder: (_, child) => WindowFrame(
              SyncWindowBinding(
                waitForHistoryWrites: historyOwner.waitForAsyncWrites,
                controller: fixture.controller,
                child: child!,
              ),
              onExit: () => exits++,
            ),
            home: Builder(
              builder: (context) {
                frame = WindowFrame.of(context);
                return const Scaffold(body: Text('reader'));
              },
            ),
          ),
        );
        Future<void> closeReader() async {
          events.add('reader');
          await saved.future;
          unawaited(fixture.controller.uploadData());
        }

        frame.addExitTask(closeReader);
        if (detached) {
          frame.removeExitTask(closeReader);
          frame.trackExitTask(closeReader());
        }
        var allowClose = false;
        bool guard() => allowClose;
        frame.addCloseListener(guard);
        final close = tester
            .widgetList<WindowButton>(find.byType(WindowButton))
            .last;
        close.onPressed();
        await tester.pump();
        expect(events, detached ? ['reader'] : isEmpty);
        allowClose = true;
        close.onPressed();
        close.onPressed();
        await tester.pump();
        expect(events, ['reader']);
        expect(exits, 0);
        saved.complete();
        await tester.pump();
        expect(events, ['reader', 'upload', 'history']);
        expect(exits, 0);
        history.complete();
        await tester.pump();
        expect(exits, 0);
        uploaded.complete(const Res(true));
        await tester.pump();
        expect(exits, 1);
        close.onPressed();
        await tester.pump();
        expect(exits, 1);
        await tester.pumpWidget(const SizedBox());
      },
      skip: !Platform.isWindows,
    );
  }

  testWidgets('explicit forced exit bypasses an upload only once', (
    tester,
  ) async {
    final uploaded = Completer<Res<bool>>();
    fixture.transfer.onUpload = () => uploaded.future;
    final upload = fixture.controller.uploadData();
    var exits = 0;
    late WindowFrameController frame;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: appNavigation.rootNavigatorKey,
        builder: (_, child) => WindowFrame(
          SyncWindowBinding(
            waitForHistoryWrites: historyOwner.waitForAsyncWrites,
            controller: fixture.controller,
            child: child!,
          ),
          onExit: () => exits++,
        ),
        home: Builder(
          builder: (context) {
            frame = WindowFrame.of(context);
            return const Scaffold();
          },
        ),
      ),
    );
    tester.widgetList<WindowButton>(find.byType(WindowButton)).last.onPressed();
    await tester.pump();
    frame.forceExit();
    frame.forceExit();
    expect(exits, 1);
    uploaded.complete(const Res(true));
    await upload;
    await tester.pump();
    expect(exits, 1);
    await tester.pumpWidget(const SizedBox());
  }, skip: !Platform.isWindows);

  testWidgets(
    'late write failure restores every prepared service',
    (tester) async {
      final write = Completer<void>();
      late WindowFrameController frame;
      var registerWrite = true;
      var releases = 0;
      var uploads = 0;
      var exits = 0;
      fixture = SyncTestFixture(
        persistImplicit: () {
          if (registerWrite) {
            registerWrite = false;
            frame.trackExitTask(write.future);
          }
        },
      );
      fixture.transfer.onUpload = () async {
        uploads++;
        return const Res(true);
      };
      historyOwner = _PendingHistory(() async {});
      Future<VoidCallback> prepare() async =>
          () => releases++;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: appNavigation.rootNavigatorKey,
          builder: (_, child) => WindowFrame(
            SyncWindowBinding(
              waitForHistoryWrites: historyOwner.waitForAsyncWrites,
              controller: fixture.controller,
              prepareInteractive: prepare,
              prepareFollowUpdates: prepare,
              prepareWebDavLibrary: prepare,
              prepareImports: prepare,
              prepareDownloads: prepare,
              prepareImages: prepare,
              child: child!,
            ),
            onExit: () => exits++,
          ),
          home: Builder(
            builder: (context) {
              frame = WindowFrame.of(context);
              return const Scaffold();
            },
          ),
        ),
      );
      tester
          .widgetList<WindowButton>(find.byType(WindowButton))
          .last
          .onPressed();
      await tester.pump();
      expect(releases, 0);
      expect(exits, 0);
      write.completeError(StateError('late persistence failed'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isA<StateError>());
      expect(releases, 6);
      expect(exits, 0);
      expect((await fixture.controller.uploadData()).success, isTrue);
      expect(uploads, 1);
      await tester.pumpWidget(const SizedBox());
      expect(releases, 6);
    },
    skip: !Platform.isWindows,
  );

  for (final removeBeforeComplete in [false, true]) {
    testWidgets(
      'window close waits for upload; removed=$removeBeforeComplete',
      (tester) async {
        final pending = Completer<Res<bool>>();
        fixture.transfer.onUpload = () => pending.future;
        final upload = fixture.controller.uploadData();
        var exits = 0;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: appNavigation.rootNavigatorKey,
            builder: (context, child) => WindowFrame(
              SyncWindowBinding(
                waitForHistoryWrites: historyOwner.waitForAsyncWrites,
                controller: fixture.controller,
                child: child!,
              ),
              onExit: () => exits++,
            ),
            home: const Scaffold(body: Text('content')),
          ),
        );
        await tester.pump();
        // Invoke the close button directly so the modal cannot hide duplicate clicks.
        final close = tester
            .widgetList<WindowButton>(find.byType(WindowButton))
            .last;
        close.onPressed();
        close.onPressed();
        await tester.pump();
        expect(exits, 0);
        if (removeBeforeComplete) await tester.pumpWidget(const SizedBox());
        pending.complete(const Res(true));
        await upload;
        await tester.pump();
        expect(exits, removeBeforeComplete ? 0 : 1);
        await tester.pumpWidget(const SizedBox());
      },
      skip: !Platform.isWindows,
    ); // Custom Windows title-bar behavior.
  }

  testWidgets(
    'native close shares shutdown waiting and detaches its listener',
    (tester) async {
      final baseline = windowManager.listeners.toSet();
      final pending = Completer<void>();
      historyOwner = _PendingHistory(() => pending.future);
      var exits = 0;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: appNavigation.rootNavigatorKey,
          builder: (_, child) => WindowFrame(
            SyncWindowBinding(
              waitForHistoryWrites: historyOwner.waitForAsyncWrites,
              controller: fixture.controller,
              child: child!,
            ),
            onExit: () => exits++,
          ),
          home: const Scaffold(),
        ),
      );
      final registered = windowManager.listeners
          .where((item) => !baseline.contains(item))
          .toList();
      for (final listener in registered) {
        listener.onWindowClose();
        listener.onWindowClose();
      }
      await tester.pump();
      expect(exits, 0);
      pending.complete();
      await tester.pump();
      expect(exits, 1);
      await tester.pumpWidget(const SizedBox());
      expect(windowManager.listeners.toSet(), baseline);
    },
    skip: !Platform.isWindows,
  );
}

class _PendingHistory extends HistoryManager {
  _PendingHistory(this.wait) : super.create();
  final Future<void> Function() wait;
  @override
  Future<void> waitForAsyncWrites() => wait();
}

class _WaitingSync extends Fake implements DataSyncController {
  _WaitingSync(this.pending);
  final Future<void> pending;
  @override
  bool get isUploading => true;
  @override
  Future<void> waitForUpload() => pending;
  @override
  Future<void> flushPersistence() async {}
  @override
  Future<VoidCallback> prepareForExit() async {
    await pending;
    return () {};
  }
}
