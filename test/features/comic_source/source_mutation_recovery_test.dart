import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/comic_source/source_data_storage.dart';
import '../../support/source_data_files.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_source/source_configuration.dart';
import 'package:venera_next/features/comic_source/source_mutation_failure.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/features/comic_source/source_script_checkpoint.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/js_engine.dart';

String script(
  String key, {
  String version = '1.0.0',
  String init = '',
  bool search = false,
}) =>
    '''
class TestSource extends ComicSource {
  key = '$key'; name = '$key'; version = '$version'; minAppVersion = '1.0.0';
  async init() { $init }
  ${search ? 'search = {load: async () => ({comics: []})};' : ''}
  comic = {loadInfo: async () => ({title: 'Comic', cover: '', tags: {}}), loadEp: async () => []};
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
  group(
    'source mutation recovery',
    () {
      late Directory root;
      late JsEngine engine;
      late ComicSourceManager manager;
      late ControlledSourceDataFiles files;
      setUp(() async {
        if (Platform.isWindows) {
          final native = Directory(
            'build/windows/x64/runner/Release',
          ).absolute.path;
          DynamicLibrary.open('$native/flutter_windows.dll');
          DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
        }
        root = Directory.systemTemp.createTempSync('source-mutation-');
        Directory('${root.path}/comic_source').createSync();
        App.dataPath = root.path;
        App.cachePath = root.path;
        App.version = '9.0.0';
        App.isInitialized = false;
        await appdata.init();
        await appdata.updateSettings((draft) {
          for (final key in [
            'explore_pages',
            'categories',
            'favorites',
            'searchSources',
          ]) {
            draft[key] = <String>[];
          }
          draft['comicSourceOrigins'] = <String, dynamic>{};
        }, sync: false);
        JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
        engine = JsEngine();
        await engine.init();
        files = ControlledSourceDataFiles();
        manager = ComicSourceManager(
          dataStorage: SourceDataStorage(files: files),
        );
      });
      Object? expectedRetiredFailure;
      tearDown(() async {
        configureComicSourceDataSavedHandler(null);
        if (expectedRetiredFailure == null) {
          await manager.closeAndWait();
        } else {
          await expectLater(
            manager.closeAndWait(),
            throwsA(
              isA<JsResourceReleaseFailure>().having(
                (failure) => failure.failures.single.error,
                'retired save failure',
                same(expectedRetiredFailure),
              ),
            ),
          );
          expectedRetiredFailure = null;
        }
        engine.dispose();
        await appdata.saveData(false);
        await root.delete(recursive: true);
      });

      Future<ComicSource> install(
        String key, {
        String init = '',
        bool search = false,
      }) => manager.installScript(
        js: script(key, init: init, search: search),
        fileName: '$key.js',
        origin: const SourceOrigin(kind: 'file'),
        beforeInstall: () {},
      );

      Future<void> waitForInit() async {
        final limit = DateTime.now().add(const Duration(seconds: 5));
        while (engine.runCode('typeof finishInit === "function"') != true) {
          if (DateTime.now().isAfter(limit)) {
            fail('Source init did not reach its barrier');
          }
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      }

      Map<String, dynamic> persisted() =>
          (jsonDecode(File('${root.path}/appdata.json').readAsStringSync())
                  as Map<String, dynamic>)['settings']
              as Map<String, dynamic>;

      Map<String, dynamic> durableIntent() {
        final db = sqlite3.open(
          '${root.path}/.source-transactions/transactions.sqlite',
          mode: OpenMode.readOnly,
        );
        try {
          return jsonDecode(
                db.select('SELECT payload FROM mutations').single['payload']
                    as String,
              )
              as Map<String, dynamic>;
        } finally {
          db.dispose();
        }
      }

      test(
        'installation owns script intent before executing source init',
        () async {
          final installing = install(
            'one',
            init:
                'await new Promise(resolve => globalThis.finishInit = resolve);',
          );
          await waitForInit();
          final intent = durableIntent();
          expect(intent['phase'], 'preparing');
          final entry = (intent['entries'] as List).single as Map;
          expect(entry['kind'], 'script');
          expect(entry['before'], isNull);
          expect(
            base64Decode((entry['after'] as List).single as String),
            File('${root.path}/comic_source/one.js').readAsBytesSync(),
          );
          engine.runCode('finishInit();');
          await installing;
        },
      );

      test(
        'replacement persists frozen memory when init does not save',
        () async {
          final original = await install('one');
          await original.editData((draft) {
            draft
              ..clear()
              ..addAll({'token': 'disk'});
          });
          final saveFailure = const FileSystemException('save unavailable');
          expectedRetiredFailure = saveFailure;
          files.beforeWrite = (_, _) => throw saveFailure;
          await expectLater(
            original.editData((draft) => draft['token'] = 'memory'),
            throwsA(isA<FileSystemException>()),
          );
          files.beforeWrite = null;
          await manager.replaceScript(
            original,
            script('one', version: '2.0.0'),
            validate: () {},
          );
          expect(manager.find('one')!.data, {'token': 'memory'});
          expect(
            jsonDecode(
              File('${root.path}/comic_source/one.data').readAsStringSync(),
            ),
            {'token': 'memory'},
          );
        },
      );

      for (final missingFile in [false, true]) {
        test(
          'failed installation recovers older metadata; missingFile=$missingFile',
          () async {
            final metadata = File('${root.path}/appdata.json');
            final backup = File('${metadata.path}.bak');
            final oldBackup = backup.existsSync()
                ? backup.readAsBytesSync()
                : null;
            final contents = jsonDecode(metadata.readAsStringSync()) as Map;
            (contents['settings'] as Map).remove('searchSources');
            metadata.writeAsStringSync(jsonEncode(contents));
            if (missingFile) metadata.deleteSync();
            final failure = const FileSystemException(
              'first data write failed',
            );
            files.beforeWrite = (_, _) => throw failure;
            await expectLater(
              install(
                'one',
                search: true,
                init: 'this.saveData("token", "new");',
              ),
              throwsA(same(failure)),
            );
            expect(manager.find('one'), isNull);
            expect(backup.existsSync(), oldBackup != null);
            if (oldBackup != null) {
              expect(backup.readAsBytesSync(), oldBackup);
            }
            files.beforeWrite = null;
            await install('one');
          },
        );
      }

      test(
        'late native JS saves during commit drain before installation completes',
        () async {
          final entered = Completer<void>();
          final release = Completer<void>();
          final snapshots = <Object?>[];
          files.beforeWrite = (_, contents) {
            final intent = durableIntent();
            expect(intent['phase'], 'applying');
            final entries = intent['entries'] as List;
            expect(
              entries.where((entry) => entry['kind'] == 'settings'),
              isNotEmpty,
            );
            final entry =
                entries.singleWhere((entry) => entry['kind'] == 'data') as Map;
            final after = entry['after'] as List;
            expect(after.length, snapshots.length + 1);
            expect(utf8.decode(base64Decode(after.last as String)), contents);
          };
          files.beforeReplace = (temporary, _) async {
            snapshots.add(jsonDecode(await temporary.readAsString()));
            if (snapshots.length == 1) {
              entered.complete();
              await release.future;
            }
          };
          addTearDown(() {
            if (!release.isCompleted) release.complete();
          });
          final installing = install(
            'one',
            init:
                'this.saveData("token", "initial"); globalThis.saveLater = () => this.saveData("token", "late");',
          );
          await entered.future;
          // Execute outside the manager's Dart Zone, as a native completion would.
          engine.runCode('saveLater();');
          release.complete();
          final current = await installing;
          expect(current.data, {'token': 'late'});
          expect(snapshots, [
            {'token': 'initial'},
            {'token': 'late'},
          ]);
          expect(
            jsonDecode(
              File('${root.path}/comic_source/one.data').readAsStringSync(),
            ),
            {'token': 'late'},
          );
        },
      );

      test(
        'replacement keeps new script after first data commit and later write failure',
        () async {
          final original = await install('one');
          await original.editData((draft) {
            draft
              ..clear()
              ..addAll({'token': 'old'});
          });
          final entered = Completer<void>();
          final release = Completer<void>();
          var writes = 0;
          files.beforeReplace = (_, _) async {
            if (++writes == 1) {
              entered.complete();
              await release.future;
            } else {
              throw const FileSystemException('late write denied');
            }
          };
          addTearDown(() {
            if (!release.isCompleted) release.complete();
          });
          final replacing = expectLater(
            manager.replaceScript(
              original,
              script(
                'one',
                version: '2.0.0',
                init:
                    'this.saveData("token", "first"); globalThis.saveLater = () => this.saveData("token", "second");',
              ),
              validate: () {},
              origin: const SourceOrigin(
                kind: 'url',
                url: 'https://one.example',
              ),
            ),
            throwsA(
              isA<SourceMutationFailure>().having(
                (e) => e.state,
                'state',
                SourceMutationState.applied,
              ),
            ),
          );
          await entered.future;
          engine.runCode('saveLater();');
          release.complete();
          await replacing;
          final current = manager.find('one')!;
          expect(current, isNot(same(original)));
          expect(current.version, '2.0.0');
          expect(engine.runCode('ComicSource.sources.one.version'), '2.0.0');
          expect(
            File(original.filePath).readAsStringSync(),
            contains("version = '2.0.0'"),
          );
          expect(SourceRepositories.instance.originFor('one')!.kind, 'url');
          expect(current.data['token'], 'second');
          expect(
            jsonDecode(
              File('${root.path}/comic_source/one.data').readAsStringSync(),
            )['token'],
            'first',
          );
          files.beforeReplace = null;
          await current.saveData();
          expect(
            jsonDecode(
              File('${root.path}/comic_source/one.data').readAsStringSync(),
            )['token'],
            'second',
          );
        },
      );

      test(
        'replacement freezes old writes but does not wait on old notifications',
        () async {
          final source = await install('one');
          final notifying = Completer<void>();
          final release = Completer<void>();
          var notices = 0;
          configureComicSourceDataSavedHandler(() async {
            if (++notices == 1) {
              notifying.complete();
              await release.future;
            }
          });
          final saving = source.editData((draft) {
            draft
              ..clear()
              ..addAll({'token': 'accepted'});
          });
          try {
            await notifying.future;
            final replacing = manager.replaceScript(
              source,
              script(
                'one',
                version: '2.0.0',
                init: '''
            await new Promise(resolve => { globalThis.finishInit = resolve; });
            this.saveData('new', true);
          ''',
              ),
              validate: () {},
            );
            await waitForInit();
            expect(
              () => source.editDataSync((draft) => draft['token'] = 'blocked'),
              throwsStateError,
            );
            // Direct edits cannot change the captured snapshot or create a later old write.
            expect(
              () => source.data['token'] = 'unsaved legacy edit',
              throwsUnsupportedError,
            );
            await expectLater(source.saveData(), throwsStateError);
            engine.runCode('finishInit();');
            await replacing.timeout(const Duration(seconds: 5));
            expect(manager.find('one')!.data, {
              'token': 'accepted',
              'new': true,
            });
            expect(
              jsonDecode(
                File('${root.path}/comic_source/one.data').readAsStringSync(),
              ),
              {'token': 'accepted', 'new': true},
            );
          } finally {
            if (!release.isCompleted) release.complete();
            await saving;
          }
        },
      );

      test(
        'failed replacement restores old instance write admission',
        () async {
          final source = await install('one');
          await source.editData((draft) {
            draft
              ..clear()
              ..addAll({'token': 'old'});
          });
          await expectLater(
            manager.replaceScript(
              source,
              script(
                'one',
                version: '2.0.0',
                init: 'throw new Error("init failed");',
              ),
              validate: () {},
            ),
            throwsA(anything),
          );
          expect(manager.find('one'), same(source));
          source.editDataSync((draft) => draft['token'] = 'retried');
          await source.saveData();
          expect(
            jsonDecode(
              File('${root.path}/comic_source/one.data').readAsStringSync(),
            ),
            {'token': 'retried'},
          );
        },
      );

      test(
        'failed reload restores the original source and resumes its writes',
        () async {
          final source = await install('one');
          final file = File(source.filePath);
          final original = file.readAsStringSync();
          file.writeAsStringSync('class Invalid extends ComicSource {}');
          try {
            await expectLater(manager.reload(), throwsA(anything));
            expect(manager.find('one'), same(source));
            expect(engine.runCode('ComicSource.sources.one.key'), 'one');
            source.editDataSync((draft) => draft['recovered'] = true);
            await source.saveData();
            expect(
              jsonDecode(
                File('${root.path}/comic_source/one.data').readAsStringSync(),
              ),
              {'recovered': true},
            );
          } finally {
            file.writeAsStringSync(original);
          }
        },
      );

      test(
        'failed install does not restore page settings from before asynchronous init',
        () async {
          final failed = expectLater(
            install(
              'one',
              search: true,
              init:
                  'await new Promise(r => globalThis.finishInit = r); throw new Error("init failed");',
            ),
            throwsA(anything),
          );
          await waitForInit();
          await appdata.updateSettings(
            (draft) => draft['searchSources'] = ['later'],
            sync: false,
          );
          engine.runCode('finishInit();');
          await failed;
          expect(appdata.settings['searchSources'], ['later']);
          expect(persisted()['searchSources'], ['later']);
          expect(manager.find('one'), isNull);
          expect(
            File('${root.path}/comic_source/one.js').existsSync(),
            isFalse,
          );
        },
      );

      test(
        'origin changed during replacement init is preserved along with newer pages',
        () async {
          final original = await install('one');
          final failed = expectLater(
            manager.replaceScript(
              original,
              script(
                'one',
                version: '2.0.0',
                search: true,
                init: 'await new Promise(r => globalThis.finishInit = r);',
              ),
              validate: () {},
              origin: const SourceOrigin(
                kind: 'url',
                url: 'https://old.example/a.js',
              ),
            ),
            throwsA(anything),
          );
          await waitForInit();
          await SourceRepositories.instance.setOrigin(
            'one',
            const SourceOrigin(kind: 'url', url: 'https://new.example/a.js'),
          );
          await appdata.updateSettings(
            (draft) => draft['searchSources'] = ['later'],
            sync: false,
          );
          engine.runCode('finishInit();');
          await failed;
          expect(manager.find('one'), same(original));
          expect(
            File(original.filePath).readAsStringSync(),
            contains("version = '1.0.0'"),
          );
          expect(appdata.settings['searchSources'], ['later']);
          expect(
            SourceRepositories.instance.originFor('one')!.url,
            'https://new.example/a.js',
          );
        },
      );

      test(
        'configuration rollback preserves conflicting pages and unrelated origin edits',
        () async {
          final source = await install('one', search: true);
          await appdata.updateSettings(
            (draft) => draft['searchSources'] = <String>[],
            sync: false,
          );
          final change = SourceConfigurationChange.register(
            source,
            origin: const SourceOrigin(kind: 'url', url: 'https://one.example'),
            dataPath: root.path,
          );
          await change.apply();
          await appdata.updateSettings((draft) {
            draft['searchSources'] = ['one', 'later'];
            draft['comicSourceOrigins'] = {
              ...draft['comicSourceOrigins'] as Map,
              'other': {'kind': 'file'},
            };
          }, sync: false);
          await expectLater(
            change.rollback(),
            throwsA(
              isA<SourceConfigurationConflict>().having(
                (error) => error.fields,
                'conflicts',
                ['searchSources'],
              ),
            ),
          );
          expect(persisted()['searchSources'], ['one', 'later']);
          expect(SourceRepositories.instance.originFor('one')!.kind, 'file');
          expect(SourceRepositories.instance.originFor('other')!.kind, 'file');
        },
      );

      test(
        'configuration recovery reports both persistence failure and newer-field conflict',
        () async {
          final source = await install('one', search: true);
          await appdata.updateSettings(
            (draft) => draft['searchSources'] = <String>[],
            sync: false,
          );
          final change = SourceConfigurationChange.register(
            source,
            dataPath: root.path,
          );
          await change.apply();
          await appdata.updateSettings(
            (draft) => draft['searchSources'] = ['one', 'later'],
            sync: false,
          );
          final blocker = Directory('${root.path}/appdata.json.tmp')
            ..createSync();
          try {
            await expectLater(
              change.rollback(),
              throwsA(
                isA<SourceMutationFailure>().having(
                  (error) => error.failures.map((item) => item.error),
                  'both failures',
                  allOf(
                    contains(isA<FileSystemException>()),
                    contains(isA<SourceConfigurationConflict>()),
                  ),
                ),
              ),
            );
            expect(appdata.settings['searchSources'], ['one', 'later']);
          } finally {
            blocker.deleteSync();
          }
        },
      );

      test(
        'data notification failure keeps committed script data origin and callbacks',
        () async {
          final original = await install('one');
          await original.editData((draft) => draft['token'] = 'old');
          final failure = StateError('publish unavailable');
          configureComicSourceDataSavedHandler(() async => throw failure);
          await expectLater(
            manager.replaceScript(
              original,
              script(
                'one',
                version: '2.0.0',
                search: true,
                init: 'this.saveData("token", "new");',
              ),
              validate: () {},
              origin: const SourceOrigin(
                kind: 'url',
                url: 'https://one.example',
              ),
            ),
            throwsA(
              isA<SourceMutationFailure>().having(
                (error) => error.state,
                'commit state',
                SourceMutationState.applied,
              ),
            ),
          );
          final current = manager.find('one')!;
          expect(current.version, '2.0.0');
          expect(
            File(current.filePath).readAsStringSync(),
            contains("version = '2.0.0'"),
          );
          expect(
            jsonDecode(
              File('${root.path}/comic_source/one.data').readAsStringSync(),
            )['token'],
            'new',
          );
          expect(SourceRepositories.instance.originFor('one')!.kind, 'url');
          expect(persisted()['searchSources'], ['one']);
          expect(original.createSettingsCallbackScope, throwsStateError);
          configureComicSourceDataSavedHandler(null);
          await current.editData((draft) => draft['later'] = true);
          expect(
            jsonDecode(
              File('${root.path}/comic_source/one.data').readAsStringSync(),
            )['later'],
            isTrue,
          );
        },
      );

      test(
        'replacement rollback attempts settings after script restoration fails and retains original backup',
        () async {
          final original = await install('one');
          await original.editData((draft) => draft['token'] = 'old');
          files.beforeReplace = (_, _) =>
              throw const FileSystemException('replacement denied');
          var edited = false;
          void editScript() {
            if (!edited &&
                (appdata.settings['searchSources'] as List).contains('one')) {
              edited = true;
              File(original.filePath).writeAsStringSync('// external edit');
            }
          }

          appdata.settings.addListener(editScript);
          Object? observed;
          try {
            await manager.replaceScript(
              original,
              script(
                'one',
                version: '2.0.0',
                search: true,
                init: 'this.saveData("token", "new");',
              ),
              validate: () {},
              origin: const SourceOrigin(
                kind: 'url',
                url: 'https://one.example',
              ),
            );
          } catch (error) {
            observed = error;
          } finally {
            appdata.settings.removeListener(editScript);
            files.beforeReplace = null;
          }
          expect(observed, isA<SourceMutationFailure>());
          final failure = observed! as SourceMutationFailure;
          expect(failure.state, SourceMutationState.recoveryRequired);
          expect(
            failure.failures.map((item) => item.stage),
            containsAll(['replace source', 'restore source script']),
          );
          expect(
            File('${failure.recoveryPath}/original.js').readAsStringSync(),
            contains("version = '1.0.0'"),
          );
          expect(
            File(original.filePath).readAsStringSync(),
            '// external edit',
          );
          expect(persisted()['searchSources'], isEmpty);
          expect(SourceRepositories.instance.originFor('one')!.kind, 'file');
          expect(manager.find('one'), same(original));
        },
      );

      test(
        'failed uninstall configuration keeps script runtime and callbacks',
        () async {
          final source = await install('one', search: true);
          final blocker = Directory('${root.path}/appdata.json.tmp')
            ..createSync();
          try {
            await expectLater(
              manager.uninstallScript(source),
              throwsA(
                isA<SourceMutationFailure>().having(
                  (error) => error.failures.length,
                  'operation and recovery errors',
                  2,
                ),
              ),
            );
            expect(manager.find('one'), same(source));
            expect(File(source.filePath).existsSync(), isTrue);
            expect(engine.runCode('ComicSource.sources.one.version'), '1.0.0');
            final callbacks = source.createSettingsCallbackScope();
            callbacks.dispose();
            expect(appdata.settings['searchSources'], ['one']);
            source.editDataSync(
              (draft) => draft['afterFailedUninstall'] = true,
            );
            await source.saveData();
          } finally {
            blocker.deleteSync();
          }
        },
      );

      test(
        'uninstall persists page pruning and origin removal while retaining source data',
        () async {
          final one = await install('one', search: true);
          await install('two', search: true);
          await one.editData((draft) => draft['token'] = 'retained');
          await manager.uninstallScript(one);
          expect(manager.find('one'), isNull);
          expect(
            engine.runCode('ComicSource.sources.one === undefined'),
            isTrue,
          );
          expect(File(one.filePath).existsSync(), isFalse);
          expect(
            jsonDecode(
              File('${root.path}/comic_source/one.data').readAsStringSync(),
            )['token'],
            'retained',
          );
          expect(persisted()['searchSources'], ['two']);
          expect(SourceRepositories.instance.originFor('one'), isNull);
          expect(one.createSettingsCallbackScope, throwsStateError);
        },
      );

      test(
        'stale source objects cannot replace or uninstall a newer instance at the same path',
        () async {
          final old = await install('one');
          await manager.replaceScript(
            old,
            script('one', version: '2.0.0'),
            validate: () {},
          );
          final current = manager.find('one');
          await expectLater(
            manager.uninstallScript(old),
            throwsA(isA<ComicSourceParseException>()),
          );
          await expectLater(
            manager.replaceScript(
              old,
              script('one', version: '3.0.0'),
              validate: () {},
            ),
            throwsA(isA<ComicSourceParseException>()),
          );
          expect(manager.find('one'), same(current));
          expect(
            File(old.filePath).readAsStringSync(),
            contains("version = '2.0.0'"),
          );
        },
      );

      test(
        'timed-out replacement waits for its actual init before restoring the old key-based data bridge',
        () async {
          final original = await install('one');
          await original.editData((draft) => draft['token'] = 'old');
          var settled = false;
          final operation = manager.replaceScript(
            original,
            script(
              'one',
              version: '2.0.0',
              init:
                  'await new Promise(r => globalThis.finishInit = r); this.saveData("token", "late");',
            ),
            validate: () {},
          );
          final observed = expectLater(
            operation,
            throwsA(isA<TimeoutException>()),
          ).whenComplete(() => settled = true);
          await waitForInit();
          await Future<void>.delayed(const Duration(milliseconds: 15100));
          expect(settled, isFalse);
          expect(manager.find('one')!.version, '2.0.0');
          engine.runCode('finishInit();');
          await observed;
          expect(manager.find('one'), same(original));
          expect(original.data['token'], 'old');
          expect(
            jsonDecode(
              File('${root.path}/comic_source/one.data').readAsStringSync(),
            )['token'],
            'old',
          );
        },
      );

      test(
        'uninstall restores its script and configuration when JS refuses removal',
        () async {
          final original = await install('one', search: true);
          engine.runCode(
            'void Object.defineProperty(ComicSource.sources, "one", {configurable: false, writable: false});',
          );
          await expectLater(
            manager.uninstallScript(original),
            throwsStateError,
          );
          // Drop the deliberately frozen property descriptor before fixture close.
          engine.runCode(
            'void (ComicSource.sources = {...ComicSource.sources});',
          );
          expect(manager.find('one'), same(original));
          expect(
            File(original.filePath).readAsStringSync(),
            contains("version = '1.0.0'"),
          );
          expect(persisted()['searchSources'], ['one']);
          expect(SourceRepositories.instance.originFor('one')!.kind, 'file');
        },
      );

      test(
        'external script edit during initialization is not overwritten by replacement',
        () async {
          final original = await install('one');
          final failed = expectLater(
            manager.replaceScript(
              original,
              script(
                'one',
                version: '2.0.0',
                init: 'await new Promise(r => globalThis.finishInit = r);',
              ),
              validate: () {},
            ),
            throwsA(isA<FileSystemException>()),
          );
          await waitForInit();
          await File(original.filePath).writeAsString('// changed externally');
          engine.runCode('finishInit();');
          await failed;
          expect(
            File(original.filePath).readAsStringSync(),
            '// changed externally',
          );
          expect(manager.find('one'), same(original));
        },
      );

      test(
        'script checkpoint restores only its own replacement and protects later file contents',
        () async {
          final target = File('${root.path}/comic_source/checkpoint.js')
            ..writeAsStringSync('old');
          final checkpoint = await SourceScriptCheckpoint.prepare(
            dataPath: root.path,
            target: target,
            before: utf8.encode('old'),
            after: utf8.encode('new'),
          );
          addTearDown(checkpoint.close);
          await target.writeAsString('new');
          await checkpoint.restore();
          expect(target.readAsStringSync(), 'old');
          await target.writeAsString('later');
          await expectLater(
            checkpoint.restore(),
            throwsA(isA<FileSystemException>()),
          );
          expect(target.readAsStringSync(), 'later');
          expect(
            File('${checkpoint.directory.path}/original.js').readAsStringSync(),
            'old',
          );
          await expectLater(
            checkpoint.discard(),
            throwsA(isA<SourceMutationFailure>()),
          );
          expect(
            File('${checkpoint.directory.path}/original.js').existsSync(),
            isTrue,
          );
          // Recovery evidence is discarded only after the conflict is resolved.
          await target.writeAsString('old');
          await checkpoint.discard();
        },
      );
    },
    skip: nativeAvailable
        ? false
        : 'QuickJS native library is unavailable on this host',
  );
}
