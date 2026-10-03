import 'package:venera_next/features/sync/data_sync_controller.dart';
import '../support/data_sync_fixture.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/sync_window_binding.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  late SyncTestFixture fixture;
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    fixture = SyncTestFixture();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => false,
        );
  });
  tearDown(() {
    HistoryManager.cache = null;
    fixture.disposeController();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  for (final mode in ['success', 'failure', 'detach', 'no-root']) {
    testWidgets('upload dialog cleanup and exit guards: $mode', (tester) async {
      final pending = Completer<void>();
      final sync = _WaitingSync(pending.future);
      var importsReleased = 0;
      var downloadsReleased = 0;
      var exits = 0;
      HistoryManager.cache = _PendingHistory(() async {});
      Widget host(bool bound) => MaterialApp(
        navigatorKey: mode == 'no-root' ? null : App.rootNavigatorKey,
        builder: (_, child) => WindowFrame(
          bound
              ? SyncWindowBinding(
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
      expect(
        find.byType(LinearProgressIndicator),
        mode == 'no-root' ? findsNothing : findsOneWidget,
      );
      if (mode == 'detach') {
        await tester.pumpWidget(host(false));
        await tester.pump();
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(exits, 0);
        expect(importsReleased, 1);
        expect(downloadsReleased, 1);
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
            navigatorKey: App.rootNavigatorKey,
            builder: (_, child) => WindowFrame(
              SyncWindowBinding(
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
        HistoryManager.cache = _PendingHistory(() {
          events.add('history');
          return history.future;
        });
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: App.rootNavigatorKey,
            builder: (_, child) => WindowFrame(
              SyncWindowBinding(
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
        HistoryManager.cache = _PendingHistory(() {
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
            navigatorKey: App.rootNavigatorKey,
            builder: (_, child) => WindowFrame(
              SyncWindowBinding(controller: fixture.controller, child: child!),
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
        navigatorKey: App.rootNavigatorKey,
        builder: (_, child) => WindowFrame(
          SyncWindowBinding(controller: fixture.controller, child: child!),
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
            navigatorKey: App.rootNavigatorKey,
            builder: (context, child) => WindowFrame(
              SyncWindowBinding(controller: fixture.controller, child: child!),
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
      HistoryManager.cache = _PendingHistory(() => pending.future);
      var exits = 0;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          builder: (_, child) => WindowFrame(
            SyncWindowBinding(controller: fixture.controller, child: child!),
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
}
