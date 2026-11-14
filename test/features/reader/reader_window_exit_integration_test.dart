import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/routing/app_navigation.dart';

import 'support/reader_integration_fixture.dart';

void main() {
  setUpReaderIntegration();

  testWidgets(
    'production window manager channel acknowledgement gates core close',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      var coreCloses = 0;
      final host = await readerFixtureHost(() => coreCloses++);
      final restoring = Completer<void>();
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('window_manager'), (
            call,
          ) async {
            calls.add(call);
            if (call.method == 'setFullScreen' &&
                (call.arguments as Map)['isFullScreen'] == false) {
              await restoring.future;
            }
            return false;
          });
      try {
        await fixture.mount(tester, pushed: false, registry: host.selections);
        fixture.readerKey.currentState!.fullscreen();
        await pumpReaderUntil(
          tester,
          () => calls.any((call) => call.method == 'show'),
        );
        await tester.pump();
        var closed = false;
        final closing = host.close().then((_) => closed = true);
        await tester.pump();
        expect(
          calls.where((call) => call.method == 'setFullScreen'),
          hasLength(2),
        );
        expect(coreCloses, 0);
        expect(closed, isFalse);
        restoring.complete();
        await pumpReaderUntil(tester, () => closed);
        await closing;
        expect(coreCloses, 1);
        expect(tester.takeException(), isNull);
      } finally {
        if (!restoring.isCompleted) restoring.complete();
        await fixture.dispose(tester);
        await host.sync.closeAndWait();
      }
    },
  );

  for (final detach in [false, true]) {
    testWidgets('host waits for window restoration; detached=$detach', (
      tester,
    ) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      var coreCloses = 0;
      final host = await readerFixtureHost(() => coreCloses++);
      final native = ReaderFixtureNativeWindow();
      final restored = Completer<void>();
      try {
        await fixture.mount(
          tester,
          pushed: false,
          registry: host.selections,
          windowCoordinator: native.coordinator,
        );
        fixture.readerKey.currentState!.fullscreen();
        await pumpReaderUntil(tester, () => native.fullscreen);
        await tester.pump();
        native.onFullscreen = (value) =>
            value ? Future.value() : restored.future;
        if (detach) await tester.pumpWidget(const SizedBox());
        var closed = false;
        final closing = host.close().then((_) => closed = true);
        await tester.pump();
        expect(coreCloses, 0);
        expect(closed, isFalse);
        expect(native.fullscreen, isTrue);
        restored.complete();
        await pumpReaderUntil(tester, () => closed);
        await closing;
        expect(native.fullscreen, isFalse);
        expect(native.visible, isTrue);
        expect(coreCloses, 1);
        expect(fixture.notifications, 1);
        expect(tester.takeException(), isNull);
      } finally {
        if (!restored.isCompleted) restored.complete();
        await fixture.dispose(tester);
        await host.sync.closeAndWait();
      }
    });
  }

  testWidgets(
    'failed window show blocks core; retry only shows and preserves reader writes',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      var coreCloses = 0;
      final host = await readerFixtureHost(() => coreCloses++);
      final native = ReaderFixtureNativeWindow();
      var failing = true;
      try {
        await fixture.mount(
          tester,
          pushed: false,
          registry: host.selections,
          windowCoordinator: native.coordinator,
        );
        fixture.readerKey.currentState!.fullscreen();
        await pumpReaderUntil(
          tester,
          () => native.fullscreen && native.visible,
        );
        await tester.pump();
        native.onShow = () async {
          if (failing) throw StateError('native window show');
        };
        Object? failure;
        final closing = host.close().catchError((Object error) {
          failure = error;
        });
        await pumpReaderUntil(tester, () => failure != null);
        await closing;
        expect(failure.toString(), contains('native window show'));
        expect(coreCloses, 0);
        expect(native.fullscreen, isFalse);
        expect(native.visible, isFalse);
        final progress = fixture.history.progress.length;
        final durations = fixture.history.durations.length;
        native.events.clear();
        failing = false;
        var closed = false;
        final retry = host.close().then((_) => closed = true);
        await pumpReaderUntil(tester, () => closed);
        await retry;
        expect(native.events, ['show']);
        expect(coreCloses, 1);
        expect(fixture.history.progress, hasLength(progress));
        expect(fixture.history.durations, hasLength(durations));
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
    'removing an old reader keeps newer reader fullscreen in the shared frame',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final native = ReaderFixtureNativeWindow();
      final nextKey = GlobalKey<FixtureReaderState>();
      try {
        await fixture.mount(
          tester,
          pushed: false,
          windowCoordinator: native.coordinator,
        );
        final old = fixture.readerKey.currentState!;
        final oldRoute = ModalRoute.of(old.context)!;
        old.fullscreen();
        await pumpReaderUntil(
          tester,
          () => native.fullscreen && native.visible,
        );
        unawaited(
          appNavigation.rootNavigatorKey.currentState!.push<void>(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                body: FixtureReader(
                  key: nextKey,
                  onClosed: () {},
                  windowCoordinator: native.coordinator,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(nextKey.currentState, isNotNull);
        native.events.clear();
        appNavigation.rootNavigatorKey.currentState!.removeRoute(oldRoute);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(fixture.readerKey.currentState, isNull);
        expect(native.fullscreen, isTrue);
        expect(native.events, isEmpty);
        expect(
          tester
              .widget<WindowFrameController>(find.byType(WindowFrameController))
              .isWindowFrameHidden,
          isTrue,
        );
        nextKey.currentState!.fullscreen();
        await pumpReaderUntil(tester, () => !native.fullscreen);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets(
    'window close restores fullscreen after a later reversible preparation fails',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final native = ReaderFixtureNativeWindow();
      var failing = true;
      Future<void> otherPreparation() async {
        if (failing) throw StateError('other window preparation');
      }

      try {
        await fixture.mount(
          tester,
          pushed: false,
          windowCoordinator: native.coordinator,
          beforeReaderMount: (frame) => frame.addExitTask(otherPreparation),
        );
        fixture.readerKey.currentState!.fullscreen();
        await pumpReaderUntil(
          tester,
          () => native.fullscreen && native.visible,
        );
        native.events.clear();
        fixture.closeWindow(tester);
        await pumpReaderUntil(
          tester,
          () => native.events.where((e) => e == 'fullscreen:true').isNotEmpty,
        );
        await tester.pump();
        expect(tester.takeException(), isA<StateError>());
        expect(
          native.events,
          containsAllInOrder(['fullscreen:false', 'fullscreen:true']),
        );
        expect(native.fullscreen, isTrue);
        expect(fixture.exits, 0);
        failing = false;
        fixture.closeWindow(tester);
        await pumpReaderUntil(tester, () => fixture.exits == 1);
        expect(native.fullscreen, isFalse);
        expect(native.visible, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets(
    'window release stays with original application after reader reparenting',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final oldRegistry = SelectionTaskRegistry();
      final newRegistry = SelectionTaskRegistry();
      final registries = ValueNotifier(oldRegistry);
      final native = ReaderFixtureNativeWindow();
      final release = Completer<void>();
      try {
        await fixture.mount(
          tester,
          pushed: false,
          registries: registries,
          windowCoordinator: native.coordinator,
        );
        fixture.readerKey.currentState!.fullscreen();
        await pumpReaderUntil(
          tester,
          () => native.fullscreen && native.visible,
        );
        native.onFullscreen = (value) =>
            value ? Future.value() : release.future;
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
        release.complete();
        await pumpReaderUntil(tester, () => oldClosed);
        await Future.wait([oldClose, newClose]);
        expect(native.fullscreen, isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        await fixture.dispose(tester);
        registries.dispose();
      }
    },
  );
}
