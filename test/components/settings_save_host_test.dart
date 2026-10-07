import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/application_host.dart';
import 'package:venera_next/app_runtime/core_bootstrap.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_source/source_update_service.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';

import '../support/data_sync_fixture.dart';

class _Page extends StatefulWidget {
  const _Page({super.key, this.initialSave});
  final Future<void> Function()? initialSave;
  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends SettingsSaveState<_Page> {
  @override
  void initState() {
    super.initState();
    if (widget.initialSave case final save?) {
      unawaited(saveSetting('initial', save));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: protectSettings(
      Column(children: [const Text('Settings'), settingsSaveStatus]),
    ),
  );
}

Widget _app(SelectionTaskRegistry registry, GlobalKey<_PageState> key) =>
    MaterialApp(
      home: SelectionTasksScope(
        registry: registry,
        child: _Page(key: key),
      ),
    );

Future<ApplicationHost> _host(void Function() close) async {
  final core = CoreBootstrap(
    environment: () async {},
    settings: () async {},
    infrastructure: () async {},
    sources: () async {},
    stores: () async {},
    finish: () async {},
    failureCleanup: [(name: 'settings stores', close: () async => close())],
  );
  await core.start();
  return ApplicationHost(
    core: core,
    sync: SyncTestFixture().controller,
    sourceUpdates: SourceUpdateService(),
    dataOperations: AppDataOperations(),
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 250 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(done(), isTrue);
}

void main() {
  App.dataPath = Directory.systemTemp.path;
  setUp(() {
    final previous = Log.isMuted;
    Log.isMuted = true;
    registerShowMessageHandler((_, _) {});
    addTearDown(() => Log.isMuted = previous);
  });

  testWidgets('initial save is owned before didChangeDependencies', (
    tester,
  ) async {
    final registry = SelectionTaskRegistry();
    final completion = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionTasksScope(
          registry: registry,
          child: _Page(initialSave: () => completion.future),
        ),
      ),
    );
    var closed = false;
    final closing = registry.closeAndWait().then((_) => closed = true);
    await tester.pump();
    expect(closed, isFalse);
    completion.complete();
    await tester.pump();
    await closing;
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'registration reentry closes without starting a save or leaking it',
    (tester) async {
      final registry = _ClosingRegistry();
      final key = GlobalKey<_PageState>();
      await tester.pumpWidget(_app(registry, key));
      expect(
        await key.currentState!.saveSetting(
          'field',
          () async => fail('Save started after rejection'),
        ),
        isFalse,
      );
      await registry.closeAndWait();
      expect(key.currentState!.savingSettings, isFalse);
      expect(key.currentState!.hasSettingsSaveError, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'accepted old-host repair releases only its own failure after reparenting',
    (tester) async {
      final old = SelectionTaskRegistry(), next = SelectionTaskRegistry();
      final key = GlobalKey<_PageState>();
      await tester.pumpWidget(_app(old, key));
      final state = key.currentState!;
      await state.saveSetting(
        'field',
        () async => throw StateError('old assignment'),
      );
      final completion = Completer<void>();
      var callbacks = 0;
      final repair = state.saveSetting(
        'field',
        () => completion.future,
        onSaved: () => callbacks++,
      );
      await tester.pumpWidget(_app(next, key));
      final newError = StateError('new host failure');
      await state.saveSetting('field', () async => throw newError);
      completion.complete();
      expect(await repair, isTrue);
      await old.closeAndWait();
      expect(callbacks, 0);
      await expectLater(
        next.closeAndWait(),
        throwsA(
          isA<SelectionCleanupFailure>().having(
            (failure) =>
                (failure.failures.single as ({Object error, StackTrace stack}))
                    .error,
            'new host error',
            same(newError),
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final detached in [false, true]) {
    testWidgets(
      'actual standalone settings save precedes core close; detached=$detached',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync('settings-host-');
        final oldPath = App.dataPath;
        final oldSettings =
            jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map;
        App.dataPath = directory.path;
        appdata.settings['disableSyncFields'] = '';
        var closes = 0;
        final host = await _host(() => closes++);
        final key = GlobalKey<_PageState>();
        final release = Completer<void>();
        Future<void>? exclusive;
        try {
          await tester.pumpWidget(_app(host.selections, key));
          exclusive = AppDataOperations.instance.run(() => release.future);
          var callbacks = 0;
          final state = key.currentState!;
          final saving = state.saveSetting(
            'proxy',
            () => appdata.updateSettings((draft) {
              draft['proxy'] = 'system';
            }),
            onSaved: () => callbacks++,
          );
          if (detached) await tester.pumpWidget(const SizedBox());
          var done = false;
          final closing = host.close().then((_) => done = true);
          expect(state.acceptsSettingsChanges, isFalse);
          expect(
            await state.saveSetting(
              'late',
              () async => fail('New save admitted'),
            ),
            isFalse,
          );
          await tester.pump();
          expect(done, isFalse);
          expect(closes, 0);
          release.complete();
          await _pumpUntil(tester, () => done);
          await closing;
          expect(await saving, isTrue);
          expect(closes, 1);
          expect(callbacks, 0);
          final stored =
              jsonDecode(
                    File('${directory.path}/appdata.json').readAsStringSync(),
                  )
                  as Map;
          expect((stored['settings'] as Map)['proxy'], 'system');
          expect(tester.takeException(), isNull);
        } finally {
          if (!release.isCompleted) release.complete();
          if (exclusive != null) await exclusive;
          await tester.pumpWidget(const SizedBox());
          await host.sync.closeAndWait();
          App.dataPath = oldPath;
          oldSettings.forEach((key, value) => appdata.settings[key] = value);
          directory.deleteSync(recursive: true);
        }
      },
    );
  }

  testWidgets(
    'detached failed assignment retains original error without host replay',
    (tester) async {
      var closes = 0;
      final host = await _host(() => closes++);
      final key = GlobalKey<_PageState>();
      final completion = Completer<void>();
      final error = StateError('settings disk failure');
      final stack = StackTrace.fromString('settings original stack');
      var attempts = 0;
      await tester.pumpWidget(_app(host.selections, key));
      final saving = key.currentState!.saveSetting('field', () {
        attempts++;
        return completion.future;
      });
      await tester.pumpWidget(const SizedBox());
      completion.completeError(error, stack);
      expect(await saving, isFalse);
      for (var i = 0; i < 2; i++) {
        ApplicationCloseFailure? failure;
        var done = false;
        final closing = host
            .close()
            .catchError((Object error) {
              failure = error as ApplicationCloseFailure;
            })
            .whenComplete(() => done = true);
        await _pumpUntil(tester, () => done);
        await closing;
        final selection =
            failure!.failures.single.error as SelectionCleanupFailure;
        final original =
            selection.failures.single as ({Object error, StackTrace stack});
        expect(original.error, same(error));
        expect(original.stack, same(stack));
        expect(attempts, 1);
        expect(closes, 0);
      }
      await host.sync.closeAndWait();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('new host cannot acknowledge or retry old same-key failure', (
    tester,
  ) async {
    final old = SelectionTaskRegistry(), next = SelectionTaskRegistry();
    final key = GlobalKey<_PageState>();
    final completion = Completer<void>();
    final error = StateError('old host');
    var oldCalls = 0, callbacks = 0;
    await tester.pumpWidget(_app(old, key));
    final state = key.currentState!;
    final original = state.saveSetting('mode', () {
      oldCalls++;
      return completion.future;
    }, onSaved: () => callbacks++);
    await tester.pumpWidget(_app(next, key));
    expect(key.currentState, same(state));
    expect(await state.saveSetting('mode', () async {}), isTrue);
    completion.completeError(error);
    expect(await original, isFalse);
    await state.retrySettingsSave();
    expect(oldCalls, 1);
    expect(callbacks, 0);
    await next.closeAndWait();
    await expectLater(
      old.closeAndWait(),
      throwsA(
        isA<SelectionCleanupFailure>().having(
          (failure) =>
              (failure.failures.single as ({Object error, StackTrace stack}))
                  .error,
          'original',
          same(error),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'late prior failure is repaired only by a new latest assignment',
    (tester) async {
      final registry = SelectionTaskRegistry();
      final key = GlobalKey<_PageState>();
      await tester.pumpWidget(_app(registry, key));
      final state = key.currentState!;
      final completion = Completer<void>();
      var oldWrites = 0, newWrites = 0;
      final error = StateError('late original failure');
      final old = state.saveSetting('mode', () {
        oldWrites++;
        return completion.future;
      });
      expect(
        await state.saveSetting('mode', () async {
          newWrites++;
        }),
        isTrue,
      );
      completion.completeError(error);
      expect(await old, isFalse);
      await expectLater(state.waitForSettingsSave(), throwsA(same(error)));
      expect(state.hasSettingsSaveError, isTrue);
      await state.retrySettingsSave();
      expect(oldWrites, 1);
      expect(newWrites, 2);
      expect(state.hasSettingsSaveError, isFalse);
      await registry.closeAndWait();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'persist reentry into host close waits for the accepted assignment',
    (tester) async {
      var closes = 0, callbacks = 0;
      final host = await _host(() => closes++);
      final key = GlobalKey<_PageState>();
      await tester.pumpWidget(_app(host.selections, key));
      final completion = Completer<void>();
      late Future<void> closing;
      var done = false;
      final saving = key.currentState!.saveSetting('mode', () {
        closing = host.close().then((_) => done = true);
        return completion.future;
      }, onSaved: () => callbacks++);
      await tester.pump();
      expect(done, isFalse);
      expect(closes, 0);
      completion.complete();
      await _pumpUntil(tester, () => done);
      await closing;
      expect(await saving, isTrue);
      expect(callbacks, 0);
      expect(closes, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('closed registry rejects new settings before persist', (
    tester,
  ) async {
    final registry = SelectionTaskRegistry();
    await registry.closeAndWait();
    final key = GlobalKey<_PageState>();
    await tester.pumpWidget(_app(registry, key));
    expect(key.currentState!.acceptsSettingsChanges, isFalse);
    expect(
      await key.currentState!.saveSetting(
        'mode',
        () async => fail('unexpected save'),
      ),
      isFalse,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'different targets keep independent errors and skip stale retry',
    (tester) async {
      final registry = SelectionTaskRegistry();
      final key = GlobalKey<_PageState>();
      await tester.pumpWidget(_app(registry, key));
      var target = 'one';
      var attempts = 0;
      final error = StateError('first target');
      final state = key.currentState!;
      await state.saveSetting(('one', 'mode'), () async {
        if (++attempts == 1) throw error;
      }, isCurrent: () => target == 'one');
      target = 'two';
      await state.saveSetting(('two', 'mode'), () async {});
      await state.retrySettingsSave();
      expect(attempts, 1);
      await expectLater(state.waitForSettingsSave(), throwsA(same(error)));
      target = 'one';
      await state.retrySettingsSave();
      expect(attempts, 2);
      await registry.closeAndWait();
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class _ClosingRegistry extends SelectionTaskRegistry {
  @override
  VoidCallback retain({
    required VoidCallback cancel,
    required Future<void> Function() close,
  }) {
    final release = super.retain(cancel: cancel, close: close);
    unawaited(closeAndWait());
    return release;
  }
}
