import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/features/comic_source/source_data_storage.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/js_engine.dart';
import '../../support/source_data_files.dart';

const _script = '''class ClosingSource extends ComicSource {
  name = 'Closing'; key = 'closing'; version = '1.0.0'; minAppVersion = '1.0.0';
  async init() {
    await sendMessage({method: 'delay', time: 200});
    globalThis.sourceFinished = true;
  }
  comic = {loadInfo: async () => ({title: 'Comic', cover: '', tags: {}}), loadEp: async () => []};
}''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('source manager close', () {
    late Directory root;
    late JsEngine engine;
    late ComicSourceManager manager;
    late ControlledSourceDataFiles files;
    setUp(() async {
      final native = Directory(
        'build/windows/x64/runner/Release',
      ).absolute.path;
      DynamicLibrary.open('$native/flutter_windows.dll');
      DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
      root = Directory.systemTemp.createTempSync('source-close-');
      Directory('${root.path}/comic_source').createSync();
      App.dataPath = root.path;
      App.cachePath = root.path;
      App.version = '9.0.0';
      App.isInitialized = false;
      await appdata.init();
      JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
      engine = JsEngine();
      await engine.init();
      files = ControlledSourceDataFiles();
      manager = ComicSourceManager(
        dataStorage: SourceDataStorage(files: files),
      );
    });
    tearDown(() async {
      try {
        await manager.closeAndWait();
      } on JsResourceReleaseFailure {
        // Failure cases assert the shared close result in the test body.
      }
      configureComicSourceDataSavedHandler(null);
      engine.dispose();
      await appdata.saveData(false);
      await root.delete(recursive: true);
    });

    test(
      'close drains background init, detaches listeners and frees callbacks',
      () async {
        await File(
          '${root.path}/comic_source/closing.js',
        ).writeAsString(_script);
        await manager.init();
        final source = manager.find('closing')!;
        var notifications = 0;
        manager.addListener(() => notifications++);
        var finished = false;
        final close = manager.closeAndWait();
        final observed = close.then((_) => finished = true);
        expect(manager.closeAndWait(), same(close));
        expect(ComicSourceManager(), same(manager));
        SourceRepositories.instance.notifyListeners();
        await expectLater(manager.reload(), throwsStateError);
        await expectLater(manager.init(), throwsStateError);
        await expectLater(manager.ensureInit(), throwsStateError);
        await Future<void>.delayed(Duration.zero);
        expect(finished, isFalse);
        await observed;
        expect(notifications, 0);
        expect(engine.runCode('sourceFinished'), isTrue);
        expect(ComicSource.all(), isEmpty);
        expect(
          engine.runCode('ComicSource.sources.closing === undefined'),
          isTrue,
        );
        expect(source.createSettingsCallbackScope, throwsStateError);
        final replacement = ComicSourceManager();
        expect(replacement, isNot(same(manager)));
        await manager.closeAndWait();
        replacement.updateAvailableUpdates({'new': '2'});
        expect(replacement.availableUpdates, {'new': '2'});
        await replacement.closeAndWait();
      },
    );

    test('close drains saves started by a completed source init', () async {
      final notifying = Completer<void>();
      final releaseNotification = Completer<void>();
      configureComicSourceDataSavedHandler(() async {
        notifying.complete();
        await releaseNotification.future;
      });
      final script = _script.replaceFirst(
        'globalThis.sourceFinished = true;',
        'this.saveData("token", "persisted"); globalThis.sourceFinished = true;',
      );
      await File('${root.path}/comic_source/closing.js').writeAsString(script);
      await manager.init();
      final source = manager.find('closing')!;
      final closing = manager.closeAndWait();
      var closed = false;
      final observed = closing.then((_) => closed = true);
      await notifying.future;
      await pumpEventQueue();
      expect(engine.runCode('sourceFinished'), isTrue);
      expect(closed, isFalse);
      expect(ComicSource.find('closing'), same(source));
      expect(
        jsonDecode(
          File('${root.path}/comic_source/closing.data').readAsStringSync(),
        ),
        {'token': 'persisted'},
      );
      releaseNotification.complete();
      await observed;
      expect(ComicSource.all(), isEmpty);
      await expectLater(source.saveData(), throwsStateError);
    });

    test(
      'save failure still drains other sources and releases registrations',
      () async {
        final script = _script.replaceFirst(
          'globalThis.sourceFinished = true;',
          'this.saveData("token", "persisted");',
        );
        await File(
          '${root.path}/comic_source/closing.js',
        ).writeAsString(script);
        await File('${root.path}/comic_source/other.js').writeAsString(
          script
              .replaceAll('ClosingSource', 'OtherSource')
              .replaceAll("'closing'", "'other'"),
        );
        Directory('${root.path}/comic_source/closing.data').createSync();
        await manager.init();
        final sources = manager.all();
        final closing = manager.closeAndWait();
        await expectLater(
          closing,
          throwsA(
            isA<JsResourceReleaseFailure>().having(
              (error) => error.failures.map((failure) => failure.resource),
              'resources',
              contains('closing data'),
            ),
          ),
        );
        expect(manager.closeAndWait(), same(closing));
        expect(ComicSource.all(), isEmpty);
        expect(engine.runCode('Object.keys(ComicSource.sources).length'), 0);
        for (final source in sources) {
          expect(source.createSettingsCallbackScope, throwsStateError);
        }
        expect(
          jsonDecode(
            File('${root.path}/comic_source/other.data').readAsStringSync(),
          ),
          {'token': 'persisted'},
        );
      },
    );

    test('close retains pending persistence from a removed source', () async {
      await File('${root.path}/comic_source/closing.js').writeAsString(_script);
      await manager.init();
      final source = manager.find('closing')!;
      final notifying = Completer<void>();
      final releaseNotification = Completer<void>();
      configureComicSourceDataSavedHandler(() async {
        notifying.complete();
        await releaseNotification.future;
      });
      final saving = source.editData((draft) {
        draft
          ..clear()
          ..addAll({'removed': true});
      });
      await notifying.future;
      manager.remove('closing');
      var closed = false;
      final closing = manager.closeAndWait().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      releaseNotification.complete();
      await Future.wait([saving, closing]);
      expect(
        jsonDecode(
          File('${root.path}/comic_source/closing.data').readAsStringSync(),
        ),
        {'removed': true},
      );
    });

    test('synchronous save-close failure cannot skip source release', () async {
      await File('${root.path}/comic_source/closing.js').writeAsString(_script);
      await manager.init();
      final source = manager.find('closing')!;
      final failingSource = _FailingDataCloseSource();
      manager.add(failingSource);
      await expectLater(
        manager.closeAndWait(),
        throwsA(
          isA<JsResourceReleaseFailure>().having(
            (error) => error.failures.map((failure) => failure.resource),
            'resources',
            contains('sync-failure data'),
          ),
        ),
      );
      expect(failingSource.callbacksReleased, isTrue);
      expect(source.createSettingsCallbackScope, throwsStateError);
      expect(ComicSource.all(), isEmpty);
      expect(engine.runCode('Object.keys(ComicSource.sources).length'), 0);
    });

    test(
      'manager retains native callbacks until runtime cleanup finishes',
      () async {
        await File(
          '${root.path}/comic_source/closing.js',
        ).writeAsString(_script);
        await manager.init();
        final source = manager.find('closing')!;
        files.beforeRemoveDirectory = (_) =>
            throw const FileSystemException('cleanup denied');
        await expectLater(
          source.saveData(),
          throwsA(isA<SourceDataWriteFailure>()),
        );
        final entered = Completer<void>();
        final release = Completer<void>();
        files.beforeRemoveDirectory = (_) async {
          entered.complete();
          await release.future;
        };
        final closing = manager.closeAndWait();
        try {
          await entered.future;
          expect(ComicSource.find('closing'), same(source));
          expect(
            engine.runCode('ComicSource.sources.closing !== undefined'),
            isTrue,
          );
          final scope = source.createSettingsCallbackScope();
          scope.dispose();
        } finally {
          release.complete();
          await closing;
        }
        expect(source.createSettingsCallbackScope, throwsStateError);
        expect(ComicSource.all(), isEmpty);
      },
    );

    test(
      'close still waits for a Promise after the init wait times out',
      () async {
        final script = _script.replaceFirst(
          "await sendMessage({method: 'delay', time: 200});",
          'await new Promise(resolve => { globalThis.finishSourceInit = resolve; });',
        );
        await File(
          '${root.path}/comic_source/closing.js',
        ).writeAsString(script);
        await manager.init();
        await Future<void>.delayed(const Duration(milliseconds: 15100));
        var finished = false;
        final closing = manager.closeAndWait().then((_) => finished = true);
        await pumpEventQueue();
        expect(finished, isFalse);
        engine.runCode('finishSourceInit();');
        await closing;
        expect(engine.runCode('sourceFinished'), isTrue);
        expect(ComicSource.all(), isEmpty);
      },
    );

    test(
      'accepted install finishes before close releases its source',
      () async {
        await manager.init();
        var entered = false;
        final install = manager.installScript(
          js: _script,
          fileName: 'closing.js',
          origin: const SourceOrigin(kind: 'file'),
          beforeInstall: () => entered = true,
        );
        await Future<void>.delayed(Duration.zero);
        expect(entered, isTrue);
        final close = manager.closeAndWait();
        final source = await install;
        await close;
        expect(File(source.filePath).existsSync(), isTrue);
        expect(SourceRepositories.instance.originFor('closing')?.kind, 'file');
        expect(engine.runCode('sourceFinished'), isTrue);
        expect(ComicSource.all(), isEmpty);
        expect(source.createSettingsCallbackScope, throwsStateError);
      },
    );
  }, skip: !Platform.isWindows);
}

class _FailingDataCloseSource extends Fake implements ComicSource {
  @override
  void bindDataOwner() {}

  bool callbacksReleased = false;

  @override
  String get key => 'sync-failure';

  @override
  String get filePath => '';

  @override
  Future<void> closeDataWrites() =>
      throw StateError('Synchronous close failure');

  @override
  void disposeRuntimeCallbacks() => callbacksReleased = true;
}
