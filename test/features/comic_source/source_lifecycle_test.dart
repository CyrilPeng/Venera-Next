import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/request_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  bool nativeAvailable;
  try {
    if (Platform.isWindows) {
      final build = Directory('build/windows/x64/runner/Release').absolute.path;
      if (File('$build/flutter_windows.dll').existsSync()) {
        DynamicLibrary.open('$build/flutter_windows.dll');
        DynamicLibrary.open('$build/flutter_qjs_plugin.dll');
      }
    }
    DynamicLibrary.open(
      Platform.isWindows
          ? 'flutter_qjs_plugin.dll'
          : Platform.isLinux
          ? 'libflutter_qjs_plugin.so'
          : 'flutter_qjs.framework/flutter_qjs',
    );
    nativeAvailable = true;
  } catch (_) {
    nativeAvailable = false;
  }

  group(
    'source runtime transactions',
    () {
      late Directory directory;
      late Map<String, dynamic> settings;
      final manager = ComicSourceManager();
      setUp(() async {
        directory = Directory.systemTemp.createTempSync(
          'venera-source-transaction-',
        );
        Directory('${directory.path}/comic_source').createSync();
        App.dataPath = directory.path;
        App.cachePath = directory.path;
        App.version = '9.0.0';
        settings = jsonDecode(jsonEncode(appdata.toJson()['settings']));
        Log.isMuted = true;
        JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
        await JsEngine().init();
      });
      tearDown(() async {
        for (final key in ['transaction_a', 'transaction_b']) {
          manager.remove(key);
        }
        await appdata.saveData(false);
        JsEngine().dispose();
        settings.forEach((key, value) => appdata.settings[key] = value);
        Log.isMuted = false;
        directory.deleteSync(recursive: true);
      });

      Future<ComicSource> install(String key) => manager.installScript(
        js: script(key),
        fileName: '$key.js',
        origin: const SourceOrigin(kind: 'file'),
        beforeInstall: () {},
      );

      test(
        'failed parse and failed init preserve installed source and unrelated runtime',
        () async {
          final original = await install('transaction_a');
          final other = await install('transaction_b');
          final oldText = await File(original.filePath).readAsString();
          original.data['token'] = 'keep';
          await original.saveData();
          JsEngine().runCode('ComicSource.sources.transaction_b.marker = 42');
          for (final replacement in [
            'broken JavaScript',
            script(
              original.key,
              version: '2.0.0',
              init:
                  'this.saveData("token", "bad"); throw new Error("init failed");',
            ),
          ]) {
            await expectLater(
              manager.replaceScript(original, replacement, validate: () {}),
              throwsA(anything),
            );
            expect(manager.find(original.key), same(original));
            expect(await File(original.filePath).readAsString(), oldText);
            expect(
              JsEngine().runCode('ComicSource.sources.transaction_a.version'),
              '1.0.0',
            );
            expect(
              jsonDecode(
                await File(
                  '${directory.path}/comic_source/${original.key}.data',
                ).readAsString(),
              )['token'],
              'keep',
            );
            expect(manager.find(other.key), same(other));
            expect(
              JsEngine().runCode('ComicSource.sources.transaction_b.marker'),
              42,
            );
          }
          await manager.replaceScript(
            original,
            script(original.key, version: '2.0.0'),
            validate: () {},
          );
          expect(manager.find(original.key)!.version, '2.0.0');
          expect(
            JsEngine().runCode('ComicSource.sources.transaction_b.marker'),
            42,
          );
          expect(
            await File(original.filePath).readAsString(),
            contains('2.0.0'),
          );
        },
      );

      test('duplicate import preserves the working source', () async {
        final original = await install('transaction_a');
        await expectLater(
          install('transaction_a'),
          throwsA(isA<SourceAlreadyInstalledException>()),
        );
        expect(manager.find(original.key), same(original));
        expect(
          JsEngine().runCode('ComicSource.sources.transaction_a.version'),
          '1.0.0',
        );
      });

      test('reloading persists new search page registration', () async {
        final original = await install('transaction_a');
        final replacement = script(original.key).replaceFirst(
          'comic =',
          'search = {load: async () => ({comics: []})}; comic =',
        );
        await manager.replaceScript(original, replacement, validate: () {});
        final saved = jsonDecode(
          await File('${directory.path}/appdata.json').readAsString(),
        );
        expect(saved['settings']['searchSources'], contains(original.key));
      });

      test(
        'failed staged data write rolls back script, runtime and origin',
        () async {
          final original = await install('transaction_a');
          original.data['token'] = 'keep';
          await original.saveData();
          final blocker = Directory(
            '${directory.path}/comic_source/${original.key}.data.update',
          )..createSync();
          await expectLater(
            manager.replaceScript(
              original,
              script(
                original.key,
                version: '2.0.0',
                init: 'this.saveData("token", "bad");',
              ),
              validate: () {},
              origin: const SourceOrigin(
                kind: 'url',
                url: 'https://example.test/test.js',
              ),
            ),
            throwsA(isA<FileSystemException>()),
          );
          expect(manager.find(original.key), same(original));
          expect(
            JsEngine().runCode('ComicSource.sources.transaction_a.version'),
            '1.0.0',
          );
          expect(
            await File(original.filePath).readAsString(),
            contains('1.0.0'),
          );
          expect(
            SourceRepositories.instance.originFor(original.key)!.kind,
            'file',
          );
          expect(
            jsonDecode(
              await File(
                '${directory.path}/comic_source/${original.key}.data',
              ).readAsString(),
            )['token'],
            'keep',
          );
          blocker.deleteSync();
          await manager.replaceScript(
            original,
            script(
              original.key,
              version: '2.0.0',
              init: 'this.saveData("token", "new");',
            ),
            validate: () {},
          );
          expect(
            jsonDecode(
              await File(
                '${directory.path}/comic_source/${original.key}.data',
              ).readAsString(),
            )['token'],
            'new',
          );
        },
      );

      test(
        'read bridge retries transient errors at most twice and stops on cancellation',
        () async {
          JsEngine().runCode('this.readAttempts = 0;');
          const operation =
              '(() => { this.readAttempts++; throw new Error("connection reset"); })()';
          await expectLater(
            JsEngine().runReadCode(operation),
            throwsA(anything),
          );
          expect(JsEngine().runCode('this.readAttempts'), 3);
          JsEngine().runCode('this.readAttempts = 0;');
          final scope = RequestScope();
          final reading = scope.run(() => JsEngine().runReadCode(operation));
          final cancelled = expectLater(
            reading,
            throwsA(isA<RequestCancelled>()),
          );
          scope.cancel();
          await cancelled;
          expect(JsEngine().runCode('this.readAttempts'), 1);
          scope.dispose();
        },
      );
    },
    skip: nativeAvailable
        ? false
        : 'QuickJS native library unavailable; run with platform build DLLs on PATH.',
  );
}

String script(String key, {String version = '1.0.0', String init = ''}) =>
    '''
  class TestSource extends ComicSource {
    name = "Test Source";
    key = "$key";
    version = "$version";
    minAppVersion = "1.0.0";
    comic = {loadInfo: async () => ({title: "Comic", cover: "", tags: {}}), loadEp: async () => []};
    init() { $init }
  }
''';
