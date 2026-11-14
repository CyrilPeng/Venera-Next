import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/features/reader/reader_session.dart';
import 'package:venera_next/features/reader/exit_guard.dart';
import 'package:venera_next/features/reader/history_writer.dart';
import 'package:venera_next/features/reader/window_controller.dart';
import 'package:venera_next/features/reader/scaffold.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/appdata.dart';

import 'support/reader_integration_fixture.dart';

void main() {
  setUpReaderIntegration();

  for (final detach in [false, true]) {
    testWidgets(
      'host drains both platform effects before core close; detached=$detach',
      (tester) async {
        final fixture = await ReaderIntegrationFixture.create(tester);
        final platform = ReaderPlatformEffectsProbe()..install();
        var coreCloses = 0;
        final host = await readerFixtureHost(() => coreCloses++);
        final orientation = Completer<void>(), bars = Completer<void>();
        try {
          appdata.settings['showSystemStatusBar'] = false;
          await fixture.mount(
            tester,
            pushed: false,
            withWindow: false,
            registry: host.selections,
          );
          final reader = fixture.readerKey.currentState!;
          reader.cycleReaderOrientation();
          await tester.pump();
          expect(platform.orientation, contains('portraitUp'));
          expect(platform.barsVisible, isFalse);
          platform.onOrientation = (value) =>
              value.isEmpty ? orientation.future : Future.value();
          platform.onBars = (value) => value ? bars.future : Future.value();
          if (detach) await tester.pumpWidget(const SizedBox());
          var closed = false;
          final closing = host.close().then((_) => closed = true);
          reader.cycleReaderOrientation();
          await tester.pump();
          expect(closed, isFalse);
          expect(coreCloses, 0);
          orientation.complete();
          await tester.pump();
          expect(closed, isFalse);
          bars.complete();
          await pumpReaderUntil(tester, () => closed);
          await closing;
          expect(coreCloses, 1);
          expect(platform.orientation, isEmpty);
          expect(platform.barsVisible, isTrue);
          expect(fixture.notifications, 1);
          expect(tester.takeException(), isNull);
        } finally {
          if (!orientation.isCompleted) orientation.complete();
          if (!bars.isCompleted) bars.complete();
          await fixture.dispose(tester);
          await host.sync.closeAndWait();
          platform.uninstall();
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    'native effects failure blocks core and retry does not replay reader persistence',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final platform = ReaderPlatformEffectsProbe()..install();
      var coreCloses = 0;
      final host = await readerFixtureHost(() => coreCloses++);
      var failing = true;
      try {
        appdata.settings['showSystemStatusBar'] = false;
        await fixture.mount(
          tester,
          pushed: false,
          withWindow: false,
          registry: host.selections,
        );
        fixture.readerKey.currentState!.cycleReaderOrientation();
        await tester.pump();
        platform.onOrientation = (_) async {
          if (failing) throw StateError('orientation restoration');
        };
        platform.onBars = (_) async {
          if (failing) throw StateError('system bars restoration');
        };
        Object? failure;
        final closing = host.close().catchError((Object error) {
          failure = error;
        });
        await pumpReaderUntil(tester, () => failure != null);
        await closing;
        expect(failure.toString(), contains('orientation restoration'));
        expect(failure.toString(), contains('system bars restoration'));
        expect(coreCloses, 0);
        final progress = fixture.history.progress.length,
            durations = fixture.history.durations.length;
        expect(fixture.notifications, 1);
        failing = false;
        var closed = false;
        final retry = host.close().then((_) => closed = true);
        await pumpReaderUntil(tester, () => closed);
        await retry;
        expect(fixture.history.progress, hasLength(progress));
        expect(fixture.history.durations, hasLength(durations));
        expect(fixture.notifications, 1);
        expect(coreCloses, 1);
        expect(tester.takeException(), isNull);
      } finally {
        failing = false;
        await fixture.dispose(tester);
        await host.sync.closeAndWait();
        platform.uninstall();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'old reader removal cannot overwrite new orientation or menu bars',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final platform = ReaderPlatformEffectsProbe()..install();
      try {
        appdata.settings['showSystemStatusBar'] = false;
        await fixture.mount(tester, pushed: true, withWindow: false);
        final oldRoute = ModalRoute.of(fixture.readerKey.currentContext!)!;
        fixture.readerKey.currentState!.cycleReaderOrientation();
        await tester.pump();
        final nextKey = GlobalKey<FixtureReaderState>();
        unawaited(
          appNavigation.rootNavigatorKey.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                body: FixtureReader(key: nextKey, onClosed: () {}),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        nextKey.currentState!.cycleReaderOrientation();
        await tester.pump();
        nextKey.currentState!.cycleReaderOrientation();
        await tester.pump();
        expect(platform.orientation, contains('landscapeLeft'));
        platform.events.clear();
        appNavigation.rootNavigatorKey.currentState!.removeRoute(oldRoute);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(platform.events, isEmpty);
        final scaffold = tester.state<ReaderScaffoldState>(
          find.byType(ReaderScaffold),
        );
        scaffold.openOrClose();
        await tester.pump();
        expect(platform.barsVisible, isTrue);
        scaffold.openOrClose();
        await tester.pump();
        expect(platform.barsVisible, isFalse);
        expect(platform.orientation, contains('landscapeLeft'));
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
        platform.uninstall();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'reader back waits for native effects restoration',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final platform = ReaderPlatformEffectsProbe()..install();
      final restored = Completer<void>();
      try {
        appdata.settings['showSystemStatusBar'] = false;
        await fixture.mount(tester, pushed: true, withWindow: false);
        final reader = fixture.readerKey.currentState!;
        reader.cycleReaderOrientation();
        await tester.pump();
        platform.onBars = (value) => value ? restored.future : Future.value();
        var left = false;
        final leaving = reader.requestExit().then((_) => left = true);
        await tester.pump();
        expect(left, isFalse);
        expect(
          ModalRoute.of(fixture.readerKey.currentContext!)!.isCurrent,
          isTrue,
        );
        restored.complete();
        await pumpReaderUntil(tester, () => left);
        await leaving;
        await tester.pump(const Duration(seconds: 1));
        expect(fixture.readerKey.currentState, isNull);
        expect(platform.orientation, isEmpty);
        expect(platform.barsVisible, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        if (!restored.isCompleted) restored.complete();
        await fixture.dispose(tester);
        platform.uninstall();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'reversible window failure resumes reader effects',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final platform = ReaderPlatformEffectsProbe()..install();
      var failing = true;
      try {
        appdata.settings['showSystemStatusBar'] = false;
        await fixture.mount(
          tester,
          pushed: false,
          beforeReaderMount: (frame) {
            frame.addExitTask(() async {
              if (failing) throw StateError('other preparation');
            });
          },
        );
        fixture.readerKey.currentState!.cycleReaderOrientation();
        await tester.pump();
        platform.events.clear();
        fixture.closeWindow(tester);
        await pumpReaderUntil(
          tester,
          () => platform.events
              .where((event) => event == 'bars:false')
              .isNotEmpty,
        );
        expect(tester.takeException(), isA<StateError>());
        expect(
          platform.events,
          containsAllInOrder(['bars:true', 'bars:false']),
        );
        expect(platform.orientation, contains('portraitUp'));
        expect(fixture.exits, 0);
        failing = false;
        fixture.closeWindow(tester);
        await pumpReaderUntil(tester, () => fixture.exits == 1);
        expect(platform.orientation, isEmpty);
        expect(platform.barsVisible, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        failing = false;
        await fixture.dispose(tester);
        platform.uninstall();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'platform release remains with original registry during reparenting',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final platform = ReaderPlatformEffectsProbe()..install();
      final original = SelectionTaskRegistry(),
          replacement = SelectionTaskRegistry();
      final registries = ValueNotifier(original);
      final restored = Completer<void>();
      try {
        appdata.settings['showSystemStatusBar'] = false;
        await fixture.mount(
          tester,
          pushed: false,
          withWindow: false,
          registries: registries,
        );
        fixture.readerKey.currentState!.cycleReaderOrientation();
        await tester.pump();
        platform.onBars = (value) => value ? restored.future : Future.value();
        registries.value = replacement;
        await tester.pump();
        var closed = false;
        final closing = original.closeAndWait().then((_) => closed = true);
        await tester.pump();
        expect(closed, isFalse);
        restored.complete();
        await pumpReaderUntil(tester, () => closed);
        await closing;
        var replacementClosed = false;
        final next = replacement.closeAndWait().then(
          (_) => replacementClosed = true,
        );
        await pumpReaderUntil(tester, () => replacementClosed);
        await next;
        expect(fixture.notifications, 1);
        expect(tester.takeException(), isNull);
      } finally {
        if (!restored.isCompleted) restored.complete();
        await fixture.dispose(tester);
        registries.dispose();
        platform.uninstall();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'closed host rejects application defaults and reader native work',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final platform = ReaderPlatformEffectsProbe()..install();
      final registry = SelectionTaskRegistry();
      try {
        await registry.closeAndWait();
        await fixture.mount(
          tester,
          pushed: false,
          withWindow: false,
          registry: registry,
          expectContent: false,
        );
        expect(platform.events, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
        platform.uninstall();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'reader exit waits for platform failure and preserves independent save failure',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final platform = ReaderPlatformEffectsProbe()..install();
      final restoring = Completer<void>();
      try {
        appdata.settings['showSystemStatusBar'] = false;
        await fixture.mount(tester, pushed: true, withWindow: false);
        final reader = fixture.readerKey.currentState!;
        final progressError = StateError('progress preparation failed');
        final progressStack = StackTrace.fromString(
          'progress preparation stack',
        );
        fixture.history.onProgress = (_) =>
            Future.error(progressError, progressStack);
        reader.toPage(2, animated: false);
        platform.onBars = (visible) =>
            visible ? restoring.future : Future.value();
        final guard = tester.widget<ReaderExitGuard>(
          find.byType(ReaderExitGuard),
        );
        Object? failure;
        var finished = false;
        final preparation = guard
            .prepare()
            .then<void>(
              (release) => release(),
              onError: (Object error, StackTrace _) {
                failure = error;
              },
            )
            .whenComplete(() => finished = true);
        await tester.pump();
        expect(finished, isFalse);
        restoring.completeError(StateError('platform preparation failed'));
        await pumpReaderUntil(tester, () => finished);
        await preparation;
        expect(failure, isA<ReaderWindowFailure>());
        final reading =
            (failure as ReaderWindowFailure).failures
                    .singleWhere(
                      (entry) => entry.operation == 'reading preparation',
                    )
                    .error
                as ReaderSessionFailure;
        expect(
          (reading.failures.single.error as ReaderProgressFailure).cause,
          same(progressError),
        );
        expect(
          reading.failures.single.stackTrace.toString(),
          progressStack.toString(),
        );
        expect(failure.toString(), contains('platform preparation failed'));
        expect(reader.controller.isDisposed, isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        if (!restoring.isCompleted) restoring.complete();
        platform.onBars = null;
        await fixture.dispose(tester);
        platform.uninstall();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final detach in [false, true]) {
    testWidgets(
      'host waits for native volume acknowledgement; detached=$detach',
      (tester) async {
        final fixture = await ReaderIntegrationFixture.create(tester);
        var coreCloses = 0;
        final host = await readerFixtureHost(() => coreCloses++);
        final cancellation = Completer<void>();
        final leases = <ReaderFixtureVolumeLease>[];
        try {
          await fixture.mount(
            tester,
            pushed: false,
            withWindow: false,
            registry: host.selections,
            volumeConnect: (send) {
              final lease = ReaderFixtureVolumeLease(
                send,
                release: () => cancellation.future,
              );
              leases.add(lease);
              return lease;
            },
          );
          expect(leases, hasLength(1));
          final reader = fixture.readerKey.currentState!;
          if (detach) await tester.pumpWidget(const SizedBox());
          var closed = false;
          final closing = host.close().then((_) => closed = true);
          leases.single.send(2);
          await tester.pump();
          expect(reader.page, 1);
          expect(coreCloses, 0);
          expect(closed, isFalse);
          expect(leases.single.closes, 1);
          cancellation.complete();
          await pumpReaderUntil(tester, () => closed);
          await closing;
          expect(coreCloses, 1);
          expect(fixture.notifications, 1);
          await host.close();
          expect(leases.single.closes, 1);
          expect(tester.takeException(), isNull);
        } finally {
          if (!cancellation.isCompleted) cancellation.complete();
          await fixture.dispose(tester);
          await host.sync.closeAndWait();
        }
      },
    );
  }

  testWidgets(
    'failed native release blocks host and retry does not replay reader saves',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      var coreCloses = 0;
      final host = await readerFixtureHost(() => coreCloses++);
      final error = StateError('native volume release');
      var failing = true;
      final leases = <ReaderFixtureVolumeLease>[];
      try {
        await fixture.mount(
          tester,
          pushed: false,
          withWindow: false,
          registry: host.selections,
          volumeConnect: (send) {
            final lease = ReaderFixtureVolumeLease(
              send,
              release: () async {
                if (failing) throw error;
              },
            );
            leases.add(lease);
            return lease;
          },
        );
        fixture.readerKey.currentState!.toPage(2, animated: false);
        Object? failure;
        final closing = host.close().catchError((Object e) {
          failure = e;
        });
        await pumpReaderUntil(tester, () => failure != null);
        await closing;
        expect(failure.toString(), contains('native volume release'));
        expect(coreCloses, 0);
        expect(leases.single.closes, 1);
        final progressWrites = fixture.history.progress.length;
        final durationWrites = fixture.history.durations.length;
        expect(fixture.notifications, 1);
        failing = false;
        var closed = false;
        final retry = host.close().then((_) => closed = true);
        await pumpReaderUntil(tester, () => closed);
        await retry;
        expect(coreCloses, 1);
        expect(leases.single.closes, 2);
        expect(fixture.history.progress, hasLength(progressWrites));
        expect(fixture.history.durations, hasLength(durationWrites));
        expect(fixture.notifications, 1);
        expect(tester.takeException(), isNull);
      } finally {
        failing = false;
        await fixture.dispose(tester);
        await host.sync.closeAndWait();
      }
    },
  );

  testWidgets(
    'covered and background readers release volume and reject retired input',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final leases = <ReaderFixtureVolumeLease>[];
      try {
        await fixture.mount(
          tester,
          pushed: false,
          withWindow: false,
          volumeConnect: (send) {
            final lease = ReaderFixtureVolumeLease(send);
            leases.add(lease);
            return lease;
          },
        );
        final reader = fixture.readerKey.currentState!;
        expect(leases, hasLength(1));
        unawaited(
          appNavigation.rootNavigatorKey.currentState!.push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('Cover reader')),
            ),
          ),
        );
        leases.first.send(2);
        expect(reader.page, 1);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(leases.first.closes, 1);
        leases.first.send(2);
        expect(reader.page, 1);
        appNavigation.rootNavigatorKey.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(leases, hasLength(2));
        reader.didChangeAppLifecycleState(AppLifecycleState.inactive);
        leases.last.send(2);
        await tester.pump();
        expect(leases.last.closes, 1);
        expect(reader.page, 1);
        reader.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump();
        expect(leases, hasLength(3));
        leases.first.send(2);
        expect(reader.page, 1);
        leases.last.send(2);
        expect(reader.page, 2);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets(
    'migrated reader keeps pending volume release in its original host',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final oldRegistry = SelectionTaskRegistry();
      final newRegistry = SelectionTaskRegistry();
      final registries = ValueNotifier(oldRegistry);
      final cancellation = Completer<void>();
      final leases = <ReaderFixtureVolumeLease>[];
      try {
        await fixture.mount(
          tester,
          pushed: false,
          withWindow: false,
          registries: registries,
          volumeConnect: (send) {
            final lease = ReaderFixtureVolumeLease(
              send,
              release: () => cancellation.future,
            );
            leases.add(lease);
            return lease;
          },
        );
        registries.value = newRegistry;
        await tester.pump();
        var oldClosed = false;
        var newClosed = false;
        final oldClose = oldRegistry.closeAndWait().then(
          (_) => oldClosed = true,
        );
        final newClose = newRegistry.closeAndWait().then(
          (_) => newClosed = true,
        );
        await tester.pump();
        expect(oldClosed, isFalse);
        expect(newClosed, isTrue);
        expect(leases, hasLength(1));
        expect(leases.single.closes, 1);
        cancellation.complete();
        await pumpReaderUntil(tester, () => oldClosed);
        await Future.wait([oldClose, newClose]);
        expect(tester.takeException(), isNull);
      } finally {
        if (!cancellation.isCompleted) cancellation.complete();
        await fixture.dispose(tester);
        registries.dispose();
      }
    },
  );

  testWidgets(
    'window waits for volume release and restores input after another prepare failure',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final cancellation = Completer<void>();
      final leases = <ReaderFixtureVolumeLease>[];
      var otherFailing = true;
      Future<void> otherPreparation() async {
        if (otherFailing) throw StateError('other prepare');
      }

      try {
        await fixture.mount(
          tester,
          pushed: false,
          beforeReaderMount: (frame) => frame.addExitTask(otherPreparation),
          volumeConnect: (send) {
            final lease = ReaderFixtureVolumeLease(
              send,
              release: leases.isEmpty ? () => cancellation.future : null,
            );
            leases.add(lease);
            return lease;
          },
        );
        final reader = fixture.readerKey.currentState!;
        fixture.closeWindow(tester);
        await tester.pump();
        expect(fixture.exits, 0);
        leases.first.send(2);
        expect(reader.page, 1);
        cancellation.complete();
        await pumpReaderUntil(tester, () => leases.length == 2);
        expect(tester.takeException(), isA<StateError>());
        await tester.pump();
        expect(fixture.exits, 0);
        expect(reader.controller.isDisposed, isFalse);
        leases.last.send(2);
        expect(reader.page, 2);
        otherFailing = false;
        fixture.closeWindow(tester);
        await pumpReaderUntil(tester, () => fixture.exits == 1);
        expect(leases.last.closes, 1);
        expect(tester.takeException(), isNull);
      } finally {
        if (!cancellation.isCompleted) cancellation.complete();
        await fixture.dispose(tester);
      }
    },
  );
}
