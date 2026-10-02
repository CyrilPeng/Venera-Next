import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/init.dart';
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

      test(
        'capability callbacks retain source identity when parser is reused',
        () async {
          final parser = ComicSourceParser();
          final first = await parser.parse(
            capabilityScript('transaction_a'),
            '${directory.path}/a.js',
          );
          manager.add(first);
          final second = await parser.parse(
            capabilityScript('transaction_b'),
            '${directory.path}/b.js',
          );
          manager.add(second);
          for (final source in [first, second]) {
            source.data['account'] = ['user', 'password'];
            expect(
              (await source.searchPageData!.loadPage!('query', 1, [])).subData,
              9,
            );
            expect(
              source.onTagSuggestionSelected!('namespace', 'tag'),
              source.key,
            );
            expect(source.categoryData!.title, 'Categories');
            expect((await source.favoriteData!.loadComic!(1)).subData, 4);
            expect((await source.explorePages.single.loadPage!(1)).subData, 5);

            expect((await source.loadComicInfo!('id')).data.title, source.key);
            expect((await source.loadComicPages!('id', 'ep')).data, [
              '${source.key}/image',
            ]);
            expect(
              (await source.loadComicThumbnail!('id', null)).subData,
              'next',
            );
            expect(
              (await source.getImageLoadingConfig!('image', 'id', 'ep'))['url'],
              source.key,
            );
            expect(
              source.getThumbnailLoadingConfig!('image')['url'],
              source.key,
            );
            expect(
              (await source.commentsLoader!('id', null, 1, null)).subData,
              7,
            );
            expect(
              (await source.chapterCommentsLoader!(
                'id',
                'ep',
                1,
                null,
              )).subData,
              8,
            );
            expect(
              (await source.sendCommentFunc!('id', null, 'text', null)).success,
              isTrue,
            );
            expect(
              (await source.sendChapterCommentFunc!(
                'id',
                'ep',
                'text',
                null,
              )).success,
              isTrue,
            );
          }
          expect(
            JsEngine().runCode('ComicSource.sources.transaction_a.sent'),
            2,
          );
          expect(
            JsEngine().runCode('ComicSource.sources.transaction_b.sent'),
            2,
          );
        },
      );

      test(
        'capability failures preserve error results and absent optional hooks',
        () async {
          final source = await ComicSourceParser().parse(
            script('transaction_a'),
            '${directory.path}/a.js',
          );
          manager.add(source);
          expect(source.commentsLoader, isNull);
          expect(source.getImageLoadingConfig, isNull);
          expect(source.searchPageData, isNull);
          JsEngine().runCode(
            'void (ComicSource.sources.transaction_a.comic.loadEp = async () => ({invalid: true}))',
          );
          expect(
            (await source.loadComicPages!('id', 'ep')).errorMessage,
            'Invalid data',
          );
          JsEngine().runCode(
            'void (ComicSource.sources.transaction_a.comic.loadInfo = () => { throw new Error("source failure"); })',
          );
          expect(
            (await source.loadComicInfo!('id')).errorMessage,
            contains('source failure'),
          );
        },
      );

      test(
        'JS initialization failure is observable and can be explicitly retried',
        () async {
          JsEngine().dispose();
          final engine = JsEngine();
          JsEngine.cacheJsInit(utf8.encode('throw new Error("broken init");'));
          await expectLater(engine.init(), throwsA(anything));
          expect(engine.initializationState, InitializationState.failed);
          JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
          await engine.retryInit();
          expect(engine.initializationState, InitializationState.ready);
          expect(engine.runCode('1 + 1'), 2);
        },
      );

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

String capabilityScript(String key) =>
    '''
class CapabilitySource extends ComicSource {
  name = "Capability";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  sent = 0;
  search = {load: async () => ({comics: [], maxPage: 9}), onTagSuggestionSelected: () => "$key"};
  category = {title: "Categories", parts: []};
  favorites = {multiFolder: false, loadComics: async () => ({comics: [], maxPage: 4})};
  explore = [{title: "Explore", type: "multiPageComicList", load: async () => ({comics: [], maxPage: 5})}];
  comic = {
    loadInfo: async () => ({title: "$key", cover: "", tags: {}}),
    loadEp: async () => ({images: ["$key/image"]}),
    loadThumbnails: async () => ({thumbnails: ["thumbnail"], next: "next"}),
    onImageLoad: async () => ({url: "$key"}),
    onThumbnailLoad: () => ({url: "$key"}),
    loadComments: async () => ({comments: [], maxPage: 7}),
    loadChapterComments: async () => ({comments: [], maxPage: 8}),
    sendComment: async () => { this.sent++; },
    sendChapterComment: async () => { this.sent++; }
  };
}
''';
