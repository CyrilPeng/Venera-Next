import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/webdav_library.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/settings/webdav_settings.dart';
import 'package:venera_next/features/webdav_library/webdav_library_api.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:window_manager/window_manager.dart';

final _gates = <Completer<void>>[];
Completer<void> _gate() {
  final gate = Completer<void>();
  _gates.add(gate);
  return gate;
}

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

Future<void> _flush(WidgetTester tester, Future<void> work) async {
  var done = false;
  Object? failure;
  work.then<void>(
    (_) => done = true,
    onError: (Object error) {
      failure = error;
      done = true;
    },
  );
  await _until(tester, () => done);
  expect(failure, isNull);
}

Future<({Directory root, WebDavLibraryServices library, _Ops ops})> _prepare(
  WidgetTester tester,
) async {
  final root = Directory.systemTemp.createTempSync('webdav-form-');
  final oldPath = App.dataPath;
  final old = jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map;
  App.dataPath = root.path;
  appdata.settings['language'] = 'en-US';
  appdata.settings['disableSyncFields'] = '';
  appdata.settings['backupWebdav'] = ['https://old.example', '', ''];
  appdata.settings['backupWebdavSyncEnabled'] = false;
  appdata.settings['webdavComicLibrary'] = ['https://old.example', '', ''];
  appdata.settings['webdavComicLibraryAutoSync'] = false;
  appdata.settings['explore_pages'] = ['Other'];
  final manager = ComicSourceManager();
  final ops = _Ops();
  final library = createWebDavLibraryServices(
    dataPath: root.path,
    manager: manager,
    ops: ops,
  );
  registerShowMessageHandler((_, _) {});
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (_) async => false,
  );
  addTearDown(() async {
    for (final gate in _gates) {
      if (!gate.isCompleted) gate.complete();
    }
    _gates.clear();
    await tester.pumpWidget(const SizedBox());
    await _flush(tester, appdata.saveData(false));
    await _flush(tester, library.source.closeAndWait());
    await _flush(tester, manager.closeAndWait());
    old.forEach((key, value) => appdata.settings[key] = value);
    App.dataPath = oldPath;
    root.deleteSync(recursive: true);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
  });
  return (root: root, library: library, ops: ops);
}

Widget _host(Widget form) => MaterialApp(home: Scaffold(body: form));
SettingsSaveState _owner(WidgetTester tester, Type type) =>
    tester.state<SettingsSaveState>(find.byType(type));
Map _saved(Directory root) =>
    (jsonDecode(File('${root.path}/appdata.json').readAsStringSync())
            as Map)['settings']
        as Map;

Future<void> _press(WidgetTester tester, String text) async {
  final button = find.widgetWithText(FilledButton, text);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  App.dataPath = Directory.systemTemp.path;

  testWidgets(
    'failed backup connection leaves configuration untouched and form editable',
    (tester) async {
      final fixture = await _prepare(tester);
      await tester.pumpWidget(
        _host(
          BackupWebdavSetting(
            testConnection: (_) async => const Res.error('offline'),
          ),
        ),
      );
      await tester.enterText(
        find.byType(TextField).first,
        'https://new.example',
      );
      tester.widget<Switch>(find.byType(Switch)).onChanged!(true);
      await _press(tester, 'Continue');
      await _flush(
        tester,
        _owner(tester, BackupWebdavSetting).waitForSettingsSave(),
      );
      expect(appdata.settings['backupWebdavSyncEnabled'], isFalse);
      expect(appdata.settings['backupWebdav'], ['https://old.example', '', '']);
      expect(find.text('offline'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).enabled,
        isTrue,
      );
      expect(File('${fixture.root.path}/appdata.json').existsSync(), isFalse);
    },
  );

  testWidgets(
    'backup check releases storage admission and back waits for grouped save',
    (tester) async {
      final fixture = await _prepare(tester);
      final checked = _gate();
      var checks = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => BackupWebdavSetting(
                        testConnection: (_) async {
                          checks++;
                          await checked.future;
                          return const Res(true);
                        },
                      ),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'https://new.example',
      );
      tester.widget<Switch>(find.byType(Switch)).onChanged!(true);
      await _press(tester, 'Continue');
      expect(checks, 1);
      final release = _gate();
      var admitted = false;
      final exclusive = AppDataOperations.instance.run(() {
        admitted = true;
        return release.future;
      });
      await tester.pump();
      expect(admitted, isTrue);
      checked.complete();
      final owner = _owner(tester, BackupWebdavSetting);
      await tester.pump();
      unawaited(
        Navigator.of(
          tester.element(find.byType(BackupWebdavSetting)),
        ).maybePop(),
      );
      await tester.pump();
      expect(find.byType(BackupWebdavSetting), findsOneWidget);
      expect(appdata.settings['backupWebdavSyncEnabled'], isFalse);
      release.complete();
      await _flush(
        tester,
        Future.wait([exclusive, owner.waitForSettingsSave()]),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BackupWebdavSetting), findsNothing);
      expect(_saved(fixture.root)['backupWebdavSyncEnabled'], isTrue);
      expect(_saved(fixture.root)['backupWebdav'], [
        'https://new.example',
        '',
        '',
      ]);
    },
  );

  testWidgets('backup persistence retry reuses the checked fixed input', (
    tester,
  ) async {
    final fixture = await _prepare(tester);
    final blocker = Directory('${fixture.root.path}/appdata.json')
      ..createSync();
    var checks = 0;
    await tester.pumpWidget(
      _host(
        BackupWebdavSetting(
          testConnection: (_) async {
            checks++;
            return const Res(true);
          },
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).first, 'https://new.example');
    await _press(tester, 'Continue');
    await _until(tester, () => find.text('Retry').evaluate().isNotEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).enabled,
      isFalse,
    );
    blocker.deleteSync();
    final owner = _owner(tester, BackupWebdavSetting);
    await _flush(tester, owner.retrySettingsSave());
    expect(checks, 1);
    expect(_saved(fixture.root)['backupWebdav'], [
      'https://new.example',
      '',
      '',
    ]);
  });

  for (final isLibrary in [false, true]) {
    testWidgets(
      '${isLibrary ? 'library' : 'backup'} removal hands pending check and save to original window',
      (tester) async {
        final fixture = await _prepare(tester);
        final checked = _gate();
        fixture.ops.check = checked.future;
        var shown = true;
        var exits = 0;
        late StateSetter update;
        final form = isLibrary
            ? WebDavComicLibrarySetting(fixture.library)
            : BackupWebdavSetting(
                testConnection: (_) async {
                  await checked.future;
                  return const Res(true);
                },
              );
        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) => WindowFrame(
              Padding(padding: const EdgeInsets.only(top: 48), child: child!),
              onExit: () async {
                exits++;
              },
            ),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (_, setState) {
                  update = setState;
                  return shown ? form : const SizedBox();
                },
              ),
            ),
          ),
        );
        await tester.enterText(
          find.byType(TextField).first,
          'https://new.example',
        );
        await _press(tester, isLibrary ? 'Save and sync' : 'Continue');
        final owner = _owner(
          tester,
          isLibrary ? WebDavComicLibrarySetting : BackupWebdavSetting,
        );
        update(() => shown = false);
        await tester.pump();
        (tester.state(find.byType(WindowFrame)) as WindowListener)
            .onWindowClose();
        await tester.pump();
        expect(exits, 0);
        checked.complete();
        await _flush(tester, owner.waitForSettingsSave());
        await _until(tester, () => exits == 1);
        expect(
          _saved(fixture.root)[isLibrary
              ? 'webdavComicLibrary'
              : 'backupWebdav'],
          ['https://new.example', '', ''],
        );
        expect(
          fixture.ops.reads,
          0,
          reason: 'An unmounted form cannot dispatch a new sync',
        );
      },
    );
  }

  testWidgets(
    'library retry saves before dispatching a single sync without rechecking',
    (tester) async {
      final fixture = await _prepare(tester);
      final blocker = Directory('${fixture.root.path}/appdata.json')
        ..createSync();
      await tester.pumpWidget(
        _host(WebDavComicLibrarySetting(fixture.library)),
      );
      await tester.enterText(
        find.byType(TextField).first,
        'https://new.example',
      );
      await _press(tester, 'Save and sync');
      await _until(tester, () => find.text('Retry').evaluate().isNotEmpty);
      expect(fixture.ops.checks, 1);
      expect(fixture.ops.reads, 0);
      blocker.deleteSync();
      await _flush(
        tester,
        _owner(tester, WebDavComicLibrarySetting).retrySettingsSave(),
      );
      expect(fixture.ops.checks, 1);
      expect(fixture.ops.reads, 1);
      expect(_saved(fixture.root)['explore_pages'], [
        'Other',
        WebDavLibrarySource.explorePageTitle,
      ]);
    },
  );

  testWidgets(
    'replaced library service receives neither an old save nor old synchronization',
    (tester) async {
      final fixture = await _prepare(tester);
      final checked = _gate();
      fixture.ops.check = checked.future;
      final nextOps = _Ops();
      final next = createWebDavLibraryServices(
        dataPath: fixture.root.path,
        manager: ComicSourceManager(),
        ops: nextOps,
      );
      addTearDown(() => _flush(tester, next.source.closeAndWait()));
      var active = fixture.library;
      late StateSetter update;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return WebDavComicLibrarySetting(active);
            },
          ),
        ),
      );
      await tester.enterText(
        find.byType(TextField).first,
        'https://new.example',
      );
      await _press(tester, 'Save and sync');
      final owner = _owner(tester, WebDavComicLibrarySetting);
      update(() => active = next);
      await tester.pump();
      checked.complete();
      await _flush(tester, owner.waitForSettingsSave());
      expect(next.settings.read().connection.url, 'https://old.example');
      expect(nextOps.checks, 0);
      expect(nextOps.reads, 0);
      expect(fixture.ops.reads, 0);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'https://old.example',
      );
    },
  );

  testWidgets(
    'forms fit narrow and landscape layouts with large text and reduced motion',
    (tester) async {
      final fixture = await _prepare(tester);
      addTearDown(() => tester.view.resetPhysicalSize());
      addTearDown(() => tester.view.resetDevicePixelRatio());
      tester.view.devicePixelRatio = 1;
      for (final size in [const Size(375, 700), const Size(700, 375)]) {
        tester.view.physicalSize = size;
        for (final form in [
          const BackupWebdavSetting(),
          WebDavComicLibrarySetting(fixture.library),
        ]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData.dark(),
              builder: (_, child) => MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: const TextScaler.linear(3.2),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: Scaffold(body: form),
            ),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.byType(FilledButton));
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '$size ${form.runtimeType}',
          );
        }
      }
    },
  );

  testWidgets(
    'leaving the library waits for its save without dispatching a new sync',
    (tester) async {
      final fixture = await _prepare(tester);
      final checked = _gate();
      fixture.ops.check = checked.future;
      await tester.pumpWidget(
        _host(WebDavComicLibrarySetting(fixture.library)),
      );
      await tester.enterText(
        find.byType(TextField).first,
        'https://new.example',
      );
      await _press(tester, 'Save and sync');
      final owner = _owner(tester, WebDavComicLibrarySetting);
      final leaving = owner.leaveSettings();
      await tester.pump();
      expect(owner.savingSettings, isTrue);
      checked.complete();
      await _flush(tester, leaving);
      expect(_saved(fixture.root)['webdavComicLibrary'], [
        'https://new.example',
        '',
        '',
      ]);
      expect(fixture.ops.reads, 0);
    },
  );

  testWidgets(
    'a later published connection is never used for the previous form sync',
    (tester) async {
      final fixture = await _prepare(tester);
      final services = WebDavLibraryServices(
        source: fixture.library.source,
        settings: WebDavLibrarySettingsStore(
          readValue: (key) => appdata.settings[key],
          persist: (configuration) async {
            await fixture.library.settings.save(configuration);
            await appdata.updateSettings((draft) {
              draft['webdavComicLibrary'] = ['https://later.example', '', ''];
            }, sync: false);
          },
        ),
      );
      await tester.pumpWidget(_host(WebDavComicLibrarySetting(services)));
      await tester.enterText(
        find.byType(TextField).first,
        'https://new.example',
      );
      await _press(tester, 'Save and sync');
      await _flush(
        tester,
        _owner(tester, WebDavComicLibrarySetting).waitForSettingsSave(),
      );
      expect(fixture.ops.reads, 0);
      expect(_saved(fixture.root)['webdavComicLibrary'], [
        'https://later.example',
        '',
        '',
      ]);
    },
  );
}

class _Ops extends WebDavLibraryOps {
  Future<void>? check;
  int checks = 0;
  int reads = 0;
  @override
  Future<void> test(WebDavLibraryConfig config) async {
    checks++;
    await check;
  }

  @override
  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String remotePath,
  ) async {
    reads++;
    return [];
  }

  @override
  Future<String> readText(
    WebDavLibraryConfig config,
    String remotePath,
  ) async => '{}';
}
