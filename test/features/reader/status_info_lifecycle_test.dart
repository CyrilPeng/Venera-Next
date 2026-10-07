import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/application_host.dart';
import 'package:venera_next/app_runtime/core_bootstrap.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_source/source_update_service.dart';
import 'package:venera_next/features/reader/status_info.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:window_manager/window_manager.dart';

import '../../support/data_sync_fixture.dart';

Widget _host(SelectionTaskRegistry registry, Widget child) => MaterialApp(
  home: SelectionTasksScope(registry: registry, child: child),
);

void _closeWindow(WidgetTester tester, [Finder? finder]) =>
    (tester.state(finder ?? find.byType(WindowFrame)) as WindowListener)
        .onWindowClose();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const batteryChannel = MethodChannel('dev.fluttercommunity.plus/battery');
  const windowChannel = MethodChannel('window_manager');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (_) async => false);
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowChannel, null);
    messenger.setMockMethodCallHandler(batteryChannel, null);
  });

  for (final remove in [false, true]) {
    testWidgets('application drains ${remove ? 'removed' : 'mounted'} status '
        'before core release and ignores optional failure', (tester) async {
      final events = <String>[];
      final core = CoreBootstrap(
        environment: () async {},
        settings: () async {},
        infrastructure: () async {},
        sources: () async {},
        stores: () async {},
        finish: () async {},
        shutdownPreparation: () async => events.add('producers'),
        failureCleanup: [
          (name: 'stores', close: () async => events.add('stores')),
        ],
      );
      await core.start();
      final host = ApplicationHost(
        core: core,
        sync: SyncTestFixture().controller,
        sourceUpdates: SourceUpdateService(),
        dataOperations: AppDataOperations(),
      );
      final pending = Completer<ReaderBatterySnapshot?>();
      var calls = 0;
      var now = DateTime(2026, 10, 6, 10);
      await tester.pumpWidget(
        _host(
          host.selections,
          ReaderStatusInfo(
            now: () => now,
            readBattery: () {
              calls++;
              return pending.future;
            },
          ),
        ),
      );
      if (remove) await tester.pumpWidget(const SizedBox());
      var closed = false;
      final closing = host.close().then((_) => closed = true);
      now = now.add(const Duration(minutes: 1));
      await tester.pump(const Duration(seconds: 5));
      expect(calls, 1);
      expect(closed, isFalse);
      expect(events, isEmpty);
      if (!remove) expect(find.text('10:00'), findsNWidgets(2));
      pending.completeError(PlatformException(code: 'battery_unavailable'));
      await tester.pump();
      await closing;
      expect(events, ['producers', 'stores']);
      await host.close();
      await tester.pump(const Duration(seconds: 5));
      expect(calls, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('native level and state futures remain in the accepted sample', (
    tester,
  ) async {
    final level = Completer<int>();
    final state = Completer<String>();
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(batteryChannel, (call) {
          calls.add(call.method);
          return call.method == 'getBatteryLevel' ? level.future : state.future;
        });
    final registry = SelectionTaskRegistry();
    await tester.pumpWidget(_host(registry, const ReaderStatusInfo()));
    var closed = false;
    final closing = registry.closeAndWait().then((_) => closed = true);
    await tester.pump(const Duration(seconds: 3));
    expect(closed, isFalse);
    expect(calls, ['getBatteryLevel']);
    level.complete(60);
    await tester.pump();
    expect(calls, ['getBatteryLevel', 'getBatteryState']);
    expect(closed, isFalse);
    state.complete('charging');
    await tester.pump();
    await closing;
    expect(find.text('60%'), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    expect(calls, hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('callback replacement drains every old generation', (
    tester,
  ) async {
    final registry = SelectionTaskRegistry();
    final old = Completer<ReaderBatterySnapshot?>();
    final next = Completer<ReaderBatterySnapshot?>();
    await tester.pumpWidget(
      _host(registry, ReaderStatusInfo(readBattery: () => old.future)),
    );
    await tester.pumpWidget(
      _host(registry, ReaderStatusInfo(readBattery: () => next.future)),
    );
    var closed = false;
    final closing = registry.closeAndWait().then((_) => closed = true);
    next.complete(const ReaderBatterySnapshot(30, charging: false));
    await tester.pump();
    expect(closed, isFalse);
    old.complete(const ReaderBatterySnapshot(99, charging: true));
    await tester.pump();
    await closing;
    expect(find.text('99%'), findsNothing);
    expect(find.text('30%'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('registry replacement leaves old read with original host', (
    tester,
  ) async {
    final oldRegistry = SelectionTaskRegistry();
    final newRegistry = SelectionTaskRegistry();
    final old = Completer<ReaderBatterySnapshot?>();
    final next = Completer<ReaderBatterySnapshot?>();
    var calls = 0;
    final child = ReaderStatusInfo(
      key: GlobalKey(),
      readBattery: () => ++calls == 1 ? old.future : next.future,
    );
    await tester.pumpWidget(_host(oldRegistry, child));
    await tester.pumpWidget(_host(newRegistry, child));
    expect(calls, 2);
    var oldClosed = false;
    final oldClosing = oldRegistry.closeAndWait().then((_) => oldClosed = true);
    next.complete(const ReaderBatterySnapshot(25, charging: false));
    await tester.pump();
    await tester.pump();
    expect(calls, 2);
    expect(find.text('25%'), findsNWidgets(2));
    await newRegistry.closeAndWait();
    expect(oldClosed, isFalse);
    old.completeError(StateError('retired read'));
    await tester.pump();
    await oldClosing;
    expect(find.text('25%'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('closed host refuses initial and replacement reads', (
    tester,
  ) async {
    final registry = SelectionTaskRegistry();
    await registry.closeAndWait();
    var calls = 0;
    for (var i = 0; i < 2; i++) {
      await tester.pumpWidget(
        _host(
          registry,
          ReaderStatusInfo(
            readBattery: () async {
              calls++;
              return null;
            },
          ),
        ),
      );
    }
    await tester.pump(const Duration(seconds: 3));
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('registration can reenter shutdown before adapter starts', (
    tester,
  ) async {
    final registry = _ClosingRegistry();
    var calls = 0;
    await tester.pumpWidget(
      _host(
        registry,
        ReaderStatusInfo(
          readBattery: () async {
            calls++;
            return null;
          },
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    await registry.closing;
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('adapter reentrant close waits its already registered request', (
    tester,
  ) async {
    final registry = SelectionTaskRegistry();
    final pending = Completer<ReaderBatterySnapshot?>();
    late Future<void> closing;
    var closed = false;
    var calls = 0;
    await tester.pumpWidget(
      _host(
        registry,
        ReaderStatusInfo(
          readBattery: () {
            calls++;
            closing = registry.closeAndWait().then((_) => closed = true);
            return pending.future;
          },
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(calls, 1);
    expect(closed, isFalse);
    pending.complete(null);
    await tester.pump();
    await closing;
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'background pauses clock and rejects old sample without overlap',
    (tester) async {
      final pending = Completer<ReaderBatterySnapshot?>();
      var now = DateTime(2026, 10, 6, 10);
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderStatusInfo(
            now: () => now,
            readBattery: () {
              calls++;
              return calls == 1
                  ? pending.future
                  : Future.value(
                      const ReaderBatterySnapshot(40, charging: true),
                    );
            },
          ),
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 1));
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('10:00'), findsNWidgets(2));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls, 1);
      expect(find.text('10:01'), findsNWidgets(2));
      pending.complete(const ReaderBatterySnapshot(99, charging: false));
      await tester.pump();
      expect(find.text('99%'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 2);
      expect(find.text('40%'), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('initial background defers reads and close never resumes', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final registry = SelectionTaskRegistry();
    var calls = 0;
    await tester.pumpWidget(
      _host(
        registry,
        ReaderStatusInfo(
          readBattery: () async {
            calls++;
            return null;
          },
        ),
      ),
    );
    expect(calls, 0);
    await registry.closeAndWait();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 3));
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'window preparation waits read and resumes after another failure',
    (tester) async {
      final pending = Completer<ReaderBatterySnapshot?>();
      var calls = 0;
      var exits = 0;
      var fail = true;
      late WindowFrameController frame;
      final status = ReaderStatusInfo(
        readBattery: () {
          calls++;
          return calls == 1
              ? pending.future
              : Future.value(const ReaderBatterySnapshot(50, charging: false));
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => WindowFrame(child!, onExit: () => exits++),
          home: Builder(
            builder: (context) {
              frame = WindowFrame.of(context);
              frame.addExitTask(() async {
                if (fail) throw StateError('another owner failed');
              });
              return Scaffold(body: status);
            },
          ),
        ),
      );
      _closeWindow(tester);
      await tester.pump(const Duration(seconds: 3));
      expect(exits, 0);
      expect(frame.isClosing, isTrue);
      expect(calls, 1);
      pending.completeError(StateError('optional battery failure'));
      await tester.pump();
      expect(tester.takeException(), isA<StateError>());
      expect(frame.isClosing, isFalse);
      expect(exits, 0);
      expect(calls, 2);
      fail = false;
      _closeWindow(tester);
      await tester.pump(const Duration(seconds: 3));
      expect(exits, 1);
      expect(calls, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('reparented status retains each request in its original window', (
    tester,
  ) async {
    final move = ValueNotifier(false);
    final old = Completer<ReaderBatterySnapshot?>();
    final next = Completer<ReaderBatterySnapshot?>();
    var calls = 0;
    var oldExits = 0;
    var newExits = 0;
    final child = ReaderStatusInfo(
      key: GlobalKey(),
      readBattery: () => ++calls == 1 ? old.future : next.future,
    );
    const oldKey = ValueKey('old frame');
    const newKey = ValueKey('new frame');
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: move,
          builder: (_, moved, _) => Row(
            children: [
              Expanded(
                child: WindowFrame(
                  moved ? const SizedBox() : child,
                  key: oldKey,
                  onExit: () => oldExits++,
                ),
              ),
              Expanded(
                child: WindowFrame(
                  moved ? child : const SizedBox(),
                  key: newKey,
                  onExit: () => newExits++,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    move.value = true;
    await tester.pump();
    expect(calls, 2);
    _closeWindow(tester, find.byKey(oldKey));
    _closeWindow(tester, find.byKey(newKey));
    await tester.pump(const Duration(seconds: 3));
    expect([oldExits, newExits], [0, 0]);
    next.complete(null);
    await tester.pump();
    expect([oldExits, newExits], [0, 1]);
    old.completeError(StateError('optional retired sample'));
    await tester.pump();
    expect([oldExits, newExits], [1, 1]);
    expect(calls, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    move.dispose();
  });

  testWidgets('mounting during reversible close waits until recovery', (
    tester,
  ) async {
    final preparation = Completer<void>();
    final visible = ValueNotifier(false);
    var calls = 0;
    late WindowFrameController frame;
    final status = ReaderStatusInfo(
      readBattery: () async {
        calls++;
        return null;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => WindowFrame(child!, onExit: () {}),
        home: Builder(
          builder: (context) {
            frame = WindowFrame.of(context);
            return Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: visible,
                builder: (_, show, _) => show ? status : const SizedBox(),
              ),
            );
          },
        ),
      ),
    );
    frame.addExitTask(() => preparation.future);
    _closeWindow(tester);
    await tester.pump();
    visible.value = true;
    await tester.pump(const Duration(seconds: 3));
    expect(calls, 0);
    preparation.completeError(StateError('preparation failure'));
    await tester.pump();
    expect(tester.takeException(), isA<StateError>());
    expect(frame.isClosing, isFalse);
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox());
    visible.dispose();
  });

  testWidgets('removed status keeps window waiting for accepted read', (
    tester,
  ) async {
    final pending = Completer<ReaderBatterySnapshot?>();
    final visible = ValueNotifier(true);
    var exits = 0;
    var calls = 0;
    final child = ReaderStatusInfo(
      readBattery: () {
        calls++;
        return pending.future;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => WindowFrame(child!, onExit: () => exits++),
        home: ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (_, show, _) => show ? child : const SizedBox(),
        ),
      ),
    );
    visible.value = false;
    await tester.pump();
    _closeWindow(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(exits, 0);
    pending.complete(null);
    await tester.pump();
    expect(exits, 1);
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox());
    visible.dispose();
  });
}

class _ClosingRegistry extends SelectionTaskRegistry {
  Future<void>? closing;
  @override
  void Function() retain({
    required void Function() cancel,
    required Future<void> Function() close,
  }) {
    final release = super.retain(cancel: cancel, close: close);
    closing = closeAndWait();
    return release;
  }
}
