import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/features/sync/app_data_transfer.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/init.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/network/cookie_jar.dart';

String _script(String key, {String init = ''}) =>
    '''
class TestSource extends ComicSource {
  key = '$key'; name = '$key'; version = '1.0.0'; minAppVersion = '1.0.0';
  async init() { $init }
  comic = {loadInfo: async () => ({title: 'Comic', cover: '', tags: {}}),
           loadEp: async () => []};
}
''';

String _barrier(String key) =>
    '''
if (!globalThis.done_$key) {
  await new Promise(resolve => { globalThis.release_$key = resolve; });
  globalThis.done_$key = true;
  sendMessage({method: 'cookie', function: 'set', url: 'https://example.test/',
    cookies: [{name: '$key', value: 'finished'}]});
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  bool nativeAvailable;
  try {
    if (Platform.isWindows) {
      final native = Directory(
        'build/windows/x64/runner/Release',
      ).absolute.path;
      DynamicLibrary.open('$native/flutter_windows.dll');
      DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
    } else {
      DynamicLibrary.open(
        Platform.isLinux
            ? 'libflutter_qjs_plugin.so'
            : 'flutter_qjs.framework/flutter_qjs',
      );
    }
    nativeAvailable = true;
  } catch (_) {
    nativeAvailable = false;
  }
  group('source data admission', () {
    late Directory root;
    late JsEngine engine;
    late ComicSourceManager manager;
    setUp(() async {
      root = Directory.systemTemp.createTempSync('source-admission-');
      App.dataPath = (Directory('${root.path}/data')..createSync()).path;
      App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
      Directory('${App.dataPath}/comic_source').createSync();
      App.version = '9.0.0';
      App.isInitialized = false;
      await appdata.init();
      await appdata.updateSettings((draft) {
        draft['comicSourceOrigins'] = <String, dynamic>{};
      }, sync: false);
      SingleInstanceCookieJar('${App.dataPath}/cookie.db');
      JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
      engine = JsEngine();
      await engine.init();
      manager = ComicSourceManager();
    });
    tearDown(() async {
      // Release test-owned barriers even after an assertion fails.
      engine.runCode('''void Object.keys(globalThis)
        .filter(key => key.startsWith('release_'))
        .forEach(key => globalThis[key]());''');
      await manager.closeAndWait();
      configureComicSourceDataSavedHandler(null);
      configureRuntimeComicSourcesProvider(null);
      engine.dispose();
      SingleInstanceCookieJar.instance?.dispose();
      SingleInstanceCookieJar.instance = null;
      await appdata.saveData(false);
      await root.delete(recursive: true);
    });

    Future<void> waitFor(String expression) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (engine.runCode(expression) != true) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Unreached JS state: $expression');
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    }

    Future<ComicSource> install(
      String key, {
      String init = '',
      void Function()? before,
    }) => manager.installScript(
      js: _script(key, init: init),
      fileName: '$key.js',
      origin: const SourceOrigin(kind: 'file'),
      beforeInstall: before ?? () {},
    );

    File archive() {
      final file = File('${root.path}/incoming.venera');
      file.writeAsBytesSync(
        ZipEncoder().encode(
          Archive()..addFile(
            ArchiveFile.string('comic_source/imported.js', _script('imported')),
          ),
        ),
      );
      return file;
    }

    test(
      'real import waits for earlier installation while native cookies still save',
      () async {
        await manager.init();
        final installing = install('first', init: _barrier('first'));
        await waitFor('typeof release_first === "function"');
        var imported = false;
        final importing = importAppData(archive()).then((state) {
          imported = true;
          return state;
        });
        await appdata.updateSettings(
          (draft) => draft['sourceAdmissionProbe'] = true,
          sync: false,
        );
        expect(imported, isFalse);
        engine.runCode('release_first();');
        await installing.timeout(const Duration(seconds: 5));
        expect(
          await importing.timeout(const Duration(seconds: 5)),
          DataSyncCommitState.applied,
        );
        expect(manager.find('first'), isNull);
        expect(manager.find('imported'), isNotNull);
        expect(
          File('${App.dataPath}/comic_source/first.js').existsSync(),
          isFalse,
        );
        expect(
          SingleInstanceCookieJar.instance!
              .loadForRequest(Uri.parse('https://example.test/'))
              .map((cookie) => cookie.name),
          contains('first'),
        );
        expect(appdata.settings['sourceAdmissionProbe'], isTrue);
      },
    );

    test(
      'import reload does not join a later outside installation queue',
      () async {
        await manager.init();
        final importing = importAppData(archive());
        final installing = install(
          'later',
          before: () {
            expect(manager.find('imported'), isNotNull);
          },
        );
        expect(
          await importing.timeout(const Duration(seconds: 5)),
          DataSyncCommitState.applied,
        );
        await installing.timeout(const Duration(seconds: 5));
        expect(
          manager.all().map((source) => source.key),
          containsAll(['imported', 'later']),
        );
      },
    );

    test(
      'startup returns while sources init concurrently and replacement drains both',
      () async {
        for (final key in ['one', 'two']) {
          File(
            '${App.dataPath}/comic_source/$key.js',
          ).writeAsStringSync(_script(key, init: _barrier(key)));
        }
        await manager.init().timeout(const Duration(seconds: 5));
        await waitFor(
          'typeof release_one === "function" && typeof release_two === "function"',
        );
        // Ready initialization is idempotent even while background preparation
        // remains active. It must not enqueue behind those pending Promises.
        await manager.init().timeout(const Duration(seconds: 1));
        await manager.ensureInit().timeout(const Duration(seconds: 1));
        var imported = false;
        final importing = importAppData(archive()).then((_) => imported = true);
        engine.runCode('release_one();');
        await waitFor('globalThis.done_one === true');
        await pumpEventQueue();
        expect(imported, isFalse);
        engine.runCode('release_two();');
        await importing.timeout(const Duration(seconds: 5));
        expect(manager.find('imported'), isNotNull);
        expect(
          SingleInstanceCookieJar.instance!
              .loadForRequest(Uri.parse('https://example.test/'))
              .map((cookie) => cookie.name),
          containsAll(['one', 'two']),
        );
      },
    );

    test(
      'queued background init skips retired sources and starts after exclusive ends',
      () async {
        final file = File('${App.dataPath}/comic_source/one.js');
        file.writeAsStringSync(
          _script('one', init: 'globalThis.oldRan = true;'),
        );
        await AppDataOperations.instance.run(() async {
          await manager.init();
          expect(engine.runCode('globalThis.oldRan === true'), isFalse);
          file.writeAsStringSync(
            _script('one', init: 'globalThis.newRan = true;'),
          );
          await manager.reload();
          expect(engine.runCode('globalThis.newRan === true'), isFalse);
        });
        await waitFor('globalThis.newRan === true');
        expect(engine.runCode('globalThis.oldRan === true'), isFalse);
      },
    );

    test(
      'exclusive initialization does not await an outside pending admission',
      () async {
        final start = Completer<void>();
        var loads = 0;
        configureRuntimeComicSourcesProvider(() {
          loads++;
          return [];
        });
        final exclusive = AppDataOperations.instance.run(() async {
          await start.future;
          await expectLater(manager.ensureInit(), throwsStateError);
          await manager.init();
          await manager.ensureInit();
        });
        final outside = manager.init();
        expect(manager.init(), same(outside));
        expect(manager.initializationState, InitializationState.notStarted);
        start.complete();
        await Future.wait([
          exclusive,
          outside,
        ]).timeout(const Duration(seconds: 5));
        expect(loads, 1);
      },
    );

    test(
      'close includes accepted work still awaiting global admission',
      () async {
        final release = Completer<void>();
        final exclusive = AppDataOperations.instance.run(() => release.future);
        final starting = manager.init();
        final installing = install('accepted');
        var closed = false;
        final closing = manager.closeAndWait().then((_) => closed = true);
        await pumpEventQueue();
        expect(closed, isFalse);
        release.complete();
        await Future.wait([
          exclusive,
          starting,
          installing,
          closing,
        ]).timeout(const Duration(seconds: 5));
        expect(
          File('${App.dataPath}/comic_source/accepted.js').existsSync(),
          isTrue,
        );
        expect(manager.all(), isEmpty);
      },
    );

    test(
      'registry listeners queue independent reload without borrowing preparation',
      () async {
        await manager.init();
        Future<void>? reloading;
        manager.addListener(() {
          reloading ??= manager.reload();
        });
        await install('one').timeout(const Duration(seconds: 5));
        expect(reloading, isNotNull);
        await reloading!.timeout(const Duration(seconds: 5));
        expect(manager.find('one'), isNotNull);
      },
    );

    test(
      'committed data notification does not lend preparation to sync work',
      () async {
        await manager.init();
        Future<int>? snapshot;
        configureComicSourceDataSavedHandler(() async {
          expect(AppDataOperations.instance.sharingScope, isNull);
          snapshot = AppDataOperations.instance.run(() => manager.all().length);
        });
        await install(
          'saved',
          init: 'this.saveData("token", "saved");',
        ).timeout(const Duration(seconds: 5));
        expect(await snapshot!.timeout(const Duration(seconds: 5)), 1);
      },
    );

    test(
      'initialization rejects access upgrades and preserves explicit retry',
      () async {
        await AppDataOperations.instance.access(() async {
          await expectLater(manager.init(), throwsStateError);
        });
        expect(manager.initializationState, InitializationState.notStarted);
        var attempts = 0;
        configureRuntimeComicSourcesProvider(() {
          if (++attempts == 1) throw StateError('runtime registration failed');
          return [];
        });
        await expectLater(manager.init(), throwsStateError);
        await expectLater(manager.init(), throwsStateError);
        expect(attempts, 1);
        await manager.retryInit();
        expect(attempts, 2);
        expect(manager.initializationState, InitializationState.ready);
      },
    );

    test(
      'close rejects waiting on admissions behind its own exclusive scope',
      () async {
        late Future<void> starting;
        await AppDataOperations.instance.run(() {
          AppDataOperations.instance.publish(() {
            starting = manager.init();
          });
          expect(manager.closeAndWait, throwsStateError);
        });
        await starting;
        await manager.closeAndWait();
        expect(manager.all(), isEmpty);
      },
    );

    test(
      'real import invalidates a save queued from its replaced source',
      () async {
        await manager.init();
        final source = await install('old');
        await source.editData((draft) {
          draft
            ..clear()
            ..addAll({'token': 'before'});
        });
        final release = Completer<void>();
        final importing = AppDataOperations.instance.run(() async {
          await release.future;
          return importAppData(archive());
        });
        final rejected = expectLater(
          source.editData((draft) {
            draft
              ..clear()
              ..addAll({'token': 'queued'});
          }),
          throwsStateError,
        );
        release.complete();
        expect(
          await importing.timeout(const Duration(seconds: 5)),
          DataSyncCommitState.applied,
        );
        await rejected;
        expect(manager.find('old'), isNull);
        expect(manager.find('imported'), isNotNull);
        expect(
          File('${App.dataPath}/comic_source/old.data').existsSync(),
          isFalse,
        );
      },
    );

    test(
      'manager close cannot wait on a source save behind its exclusive owner',
      () async {
        await manager.init();
        final source = await install('one');
        final release = Completer<void>();
        final exclusive = AppDataOperations.instance.run(() async {
          await release.future;
          expect(manager.closeAndWait, throwsStateError);
        });
        final saving = source.editData((draft) {
          draft
            ..clear()
            ..addAll({'token': 'accepted'});
        });
        release.complete();
        await Future.wait([
          exclusive,
          saving,
        ]).timeout(const Duration(seconds: 5));
        await manager.closeAndWait();
        expect(
          File('${App.dataPath}/comic_source/one.data').readAsStringSync(),
          '{"token":"accepted"}',
        );
      },
    );

    test('failed installation releases a queued real import', () async {
      await manager.init();
      final failed = expectLater(
        install(
          'failed',
          init: '${_barrier('failed')} throw new Error("init failure");',
        ),
        throwsA(anything),
      );
      await waitFor('typeof release_failed === "function"');
      final importing = importAppData(archive());
      engine.runCode('release_failed();');
      await failed;
      expect(
        await importing.timeout(const Duration(seconds: 5)),
        DataSyncCommitState.applied,
      );
      expect(manager.find('failed'), isNull);
      expect(manager.find('imported'), isNotNull);
    });
  }, skip: !nativeAvailable);
}
