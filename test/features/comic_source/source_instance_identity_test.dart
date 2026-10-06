import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/network/image_loading_config.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_source/source_data_storage.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/features/comic_source/source_parser_context.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import '../../support/source_data_files.dart';

String script({
  String version = '1.0.0',
  String fields = '',
  String init = '',
}) =>
    '''
class IdentitySource extends ComicSource {
  key = 'one'; name = 'One'; version = '$version'; minAppVersion = '1.0.0';
  calls = 0;
  settings = {mode: {type: 'select', default: 'default', options: ['default', 'saved']},
    action: {type: 'callback', callback: () => ++this.calls}};
  raw(method) { return sendMessage({method, key: this.key, data_key: 'token', setting_key: 'mode', data: 'raw'}); }
  account = {login: async () => { this.calls++; }, logout: () => { this.calls++; }};
  comic = {
    loadInfo: async () => {this.calls++; return {title: 'Book', cover: '', tags: {}};},
    loadEp: async () => {this.calls++; return [];},
    onImageLoad: () => {this.calls++; return {headers: {}};},
    likeComic: async () => {this.calls++;},
    loadComments: async () => {this.calls++; return {comments: []};},
    onClickTag: () => {this.calls++; return null;},
    archive: {getArchives: async () => {this.calls++; return [];}}
  };
  search = {load: async () => {this.calls++; return {comics: [], maxPage: 1};}};
  explore = [{title: 'Explore', type: 'multiPageComicList', load: async () => {this.calls++; return {comics: [], maxPage: 1};}}];
  favorites = {multiFolder: false, loadComics: async () => {this.calls++; return {comics: [], maxPage: 1};}};
  $fields
  async init() { $init }
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var nativeAvailable = true;
  try {
    if (Platform.isWindows) {
      final path = Directory('build/windows/x64/runner/Release').absolute.path;
      DynamicLibrary.open('$path/flutter_windows.dll');
      DynamicLibrary.open('$path/flutter_qjs_plugin.dll');
    } else {
      DynamicLibrary.open(
        Platform.isLinux
            ? 'libflutter_qjs_plugin.so'
            : 'flutter_qjs.framework/flutter_qjs',
      );
    }
  } catch (_) {
    nativeAvailable = false;
  }
  group(
    'source instance identity',
    () {
      late Directory root;
      late JsEngine engine;
      late ComicSourceManager manager;
      late ControlledSourceDataFiles files;
      setUp(() async {
        root = Directory.systemTemp.createTempSync('source-instance-');
        Directory('${root.path}/comic_source').createSync();
        App.dataPath = root.path;
        App.cachePath = root.path;
        App.version = '9.0.0';
        App.isInitialized = false;
        Log.isMuted = true;
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
        configureComicSourceDataSavedHandler(null);
        await manager.closeAndWait();
        expect(engine.debugOwnedReferenceCount, 0);
        engine.dispose();
        await appdata.saveData(false);
        await root.delete(recursive: true);
        Log.isMuted = false;
      });
      Future<ComicSource> install({String fields = '', String init = ''}) =>
          manager.installScript(
            js: script(fields: fields, init: init),
            fileName: 'one.js',
            origin: const SourceOrigin(kind: 'file'),
            beforeInstall: () {},
          );
      Future<void> replace(
        ComicSource original, {
        String fields = '',
        String init = '',
      }) => manager.replaceScript(
        original,
        script(version: '2.0.0', fields: fields, init: init),
        validate: () {},
      );
      Map<String, dynamic> saved() =>
          jsonDecode(
                File('${root.path}/comic_source/one.data').readAsStringSync(),
              )
              as Map<String, dynamic>;

      for (final method in [
        'load_data',
        'save_data',
        'delete_data',
        'load_setting',
        'isLogged',
      ]) {
        for (final raw in [false, true]) {
          test(
            'retired ${raw ? 'lexical message' : 'SDK'} $method rejects the new source',
            () async {
              final original = await install();
              await original.editData((draft) {
                draft
                  ..clear()
                  ..addAll({
                    'token': 'old',
                    'settings': {'mode': 'saved'},
                    'account': ['old', 'pw'],
                  });
              });
              engine.runCode(
                'void (globalThis.retired = ComicSource.sources.one);',
              );
              await replace(original, init: "this.saveData('token', 'new');");
              final expression = raw
                  ? "retired.raw('$method')"
                  : switch (method) {
                      'load_data' => "retired.loadData('token')",
                      'save_data' => "retired.saveData('token', 'bad')",
                      'delete_data' => "retired.deleteData('token')",
                      'load_setting' => "retired.loadSetting('mode')",
                      _ => 'retired.isLogged',
                    };
              expect(() => engine.runCode(expression), throwsA(anything));
              expect(manager.find('one')!.data['token'], 'new');
              expect(saved()['token'], 'new');
            },
          );
        }
      }

      test(
        'bare host data messages cannot select an arbitrary current source',
        () async {
          await install();
          expect(
            () => engine.runCode(
              "sendMessage({method: 'save_data', key: 'one', data_key: 'token', data: 'bad'});",
            ),
            throwsA(anything),
          );
          expect(manager.find('one')!.data.containsKey('token'), isFalse);
          engine.runCode("ComicSource.sources.one.raw('save_data');");
          await manager.find('one')!.saveData();
          expect(saved()['token'], 'raw');
        },
      );

      test(
        'derived Promise saves keep their old identity after replacement',
        () async {
          final original = await install(
            init: '''
        globalThis.pendingOld = new Promise(resolve => globalThis.finishOld = resolve)
          .then(() => this.saveData('token', 'late'));
      ''',
          );
          final rejected = expectLater(
            engine.runCode('pendingOld'),
            throwsA(anything),
          );
          await replace(original, init: "this.saveData('token', 'new');");
          engine.runCode('finishOld();');
          await rejected;
          expect(manager.find('one')!.data['token'], 'new');
          expect(saved()['token'], 'new');
        },
      );

      test('late login cannot save credentials into the replacement', () async {
        final original = await install(
          fields: '''
        account = {login: () => new Promise(resolve => globalThis.finishLogin = resolve), logout: () => {}};
      ''',
        );
        final loggingIn = original.account!.login!('old-user', 'old-password');
        expect(engine.runCode('typeof finishLogin'), 'function');
        await replace(original);
        engine.runCode('finishLogin();');
        expect((await loggingIn).error, isTrue);
        expect(manager.find('one')!.data.containsKey('account'), isFalse);
        expect(saved().containsKey('account'), isFalse);
      });

      test(
        'login waits for its actual data file before reporting success',
        () async {
          final original = await install();
          final entered = Completer<void>();
          final release = Completer<void>();
          files.beforeReplace = (_, _) async {
            entered.complete();
            await release.future;
          };
          addTearDown(() {
            if (!release.isCompleted) release.complete();
          });
          var completed = false;
          final loggingIn = original.account!.login!('user', 'password').then((
            value,
          ) {
            completed = true;
            return value;
          });
          await entered.future;
          expect(completed, isFalse);
          release.complete();
          expect((await loggingIn).error, isFalse);
          expect(saved()['account'], ['user', 'password']);
        },
      );

      test(
        'constructor and metadata getters read a snapshot without redirecting old callbacks',
        () async {
          final original = await install();
          await original.editData((draft) {
            draft
              ..clear()
              ..addAll({
                'token': 'old',
                'settings': {'mode': 'saved'},
                'account': ['u', 'p'],
              });
          });
          await replace(
            original,
            fields: '''
        constructed = [this.loadData('token'), this.loadSetting('mode'), this.isLogged,
          sendMessage({method: 'load_data', key: this.key, data_key: 'token'})];
        translationSetup = (() => {Object.defineProperty(this, 'translation', {get: () => ({en: {token: this.loadData('token')}})}); return true;})();
      ''',
          );
          expect(engine.runCode('ComicSource.sources.one.constructed'), [
            'old',
            'saved',
            true,
            'old',
          ]);
          expect(manager.find('one')!.translations!['en']!['token'], 'old');
        },
      );

      test(
        'constructor writes cannot mutate the frozen original source',
        () async {
          final original = await install();
          await original.editData((draft) {
            draft
              ..clear()
              ..addAll({'token': 'old'});
          });
          await expectLater(
            replace(
              original,
              fields: "attempt = this.saveData('token', 'bad');",
            ),
            throwsA(anything),
          );
          expect(manager.find('one'), same(original));
          expect(original.data['token'], 'old');
          expect(saved()['token'], 'old');
          engine.runCode(
            "ComicSource.sources.one.saveData('token', 'resumed');",
          );
          await original.saveData();
          expect(saved()['token'], 'resumed');
        },
      );

      test(
        'rollback revives the original identity and rejects the failed instance',
        () async {
          final original = await install();
          engine.runCode(
            'void (globalThis.originalRuntime = ComicSource.sources.one);',
          );
          await expectLater(
            replace(
              original,
              init:
                  "globalThis.failedRuntime = this; throw new Error('init failed');",
            ),
            throwsA(anything),
          );
          expect(manager.find('one'), same(original));
          expect(
            () => engine.runCode("failedRuntime.loadData('token')"),
            throwsA(anything),
          );
          engine.runCode("originalRuntime.raw('save_data');");
          await original.saveData();
          expect(saved()['token'], 'raw');
          expect((await original.loadComicInfo!('book')).error, isFalse);
        },
      );

      test(
        'retained capability and settings callbacks never invoke new functions',
        () async {
          final original = await install();
          await original.editData((draft) => draft['account'] = ['u', 'p']);
          final scope = original.createSettingsCallbackScope();
          final action =
              original.getSettingsDynamic(
                    callbacks: scope,
                  )!['action']!['callback']
                  as dynamic Function(List<dynamic>);
          await replace(original);
          expect((await original.loadComicInfo!('book')).error, isTrue);
          expect((await original.loadComicPages!('book', '1')).error, isTrue);
          expect(
            (await original.searchPageData!.loadPage!('word', 1, [])).error,
            isTrue,
          );
          expect(
            (await original.explorePages.single.loadPage!(1)).error,
            isTrue,
          );
          expect((await original.favoriteData!.loadComic!(1)).error, isTrue);
          expect(
            (await original.likeOrUnlikeComic!('book', true)).error,
            isTrue,
          );
          expect(
            () => original.handleClickTagEvent!('tag', 'value'),
            throwsA(anything),
          );
          expect(() => action([]), throwsA(anything));
          await expectLater(
            Future.sync(
              () => original.getImageLoadingConfig!('image', 'book', '1'),
            ),
            throwsA(anything),
          );
          expect(engine.runCode('ComicSource.sources.one.calls'), 0);
          scope.dispose();
        },
      );

      test('late details are rejected and release native references', () async {
        final original = await install(
          fields: '''
        comic = {loadInfo: async () => {await new Promise(resolve => globalThis.finishDetails = resolve);
          return {title: 'Old', cover: '', tags: {}, extra: () => 1};}, loadEp: async () => []};
      ''',
        );
        final loading = original.loadComicInfo!('book');
        expect(engine.runCode('typeof finishDetails'), 'function');
        await replace(original);
        engine.runCode('finishDetails();');
        expect((await loading).error, isTrue);
        expect(engine.debugOwnedReferenceCount, 0);
      });

      test(
        'late image configs are rejected and release owned callback graphs',
        () async {
          final original = await install(
            fields: '''
        comic = {loadInfo: async () => ({title:'Book',cover:'',tags:{}}), loadEp: async () => [],
          onImageLoad: async () => {await new Promise(resolve => globalThis.finishImage = resolve);
            const fn = () => 1; return {onResponse: fn, extra: [fn]};}};
      ''',
          );
          final rejected = expectLater(
            Future.sync(
              () => original.getImageLoadingConfig!('image', 'book', '1'),
            ),
            throwsA(anything),
          );
          expect(engine.runCode('typeof finishImage'), 'function');
          await replace(original);
          engine.runCode('finishImage();');
          await rejected;
          expect(engine.debugOwnedReferenceCount, 0);
        },
      );

      for (final chapter in [false, true]) {
        test(
          'late comment expiry does not relogin the replacement: chapter=$chapter',
          () async {
            final original = await install(
              fields:
                  '''
            comic = {loadInfo: async () => ({title:'Book',cover:'',tags:{}}), loadEp: async () => [],
              ${chapter ? 'sendChapterComment' : 'sendComment'}: async () => {
                await new Promise(resolve => globalThis.finishComment = resolve); throw new Error('Login expired');}};
          ''',
            );
            await original.editData((draft) => draft['account'] = ['u', 'p']);
            final sending = chapter
                ? original.sendChapterCommentFunc!('book', '1', 'text', null)
                : original.sendCommentFunc!('book', null, 'text', null);
            expect(engine.runCode('typeof finishComment'), 'function');
            await replace(original);
            engine.runCode('finishComment();');
            expect((await sending).error, isTrue);
            expect(engine.runCode('ComicSource.sources.one.calls'), 0);
          },
        );
      }

      test(
        'reload retires the old instance even when key and script path are identical',
        () async {
          final original = await install();
          engine.runCode(
            'void (globalThis.retired = ComicSource.sources.one);',
          );
          await manager.reload();
          expect(manager.find('one'), isNot(same(original)));
          expect(
            manager.find('one')!.filePath.replaceAll(r"\", '/'),
            original.filePath.replaceAll(r"\", '/'),
          );
          expect(
            () => engine.runCode("retired.saveData('token', 'bad')"),
            throwsA(anything),
          );
          expect((await original.loadComicInfo!('book')).error, isTrue);
          expect(
            (await manager.find('one')!.loadComicInfo!('book')).error,
            isFalse,
          );
        },
      );

      test(
        'delivered image callbacks keep their own lifetime and cannot read replacement data',
        () async {
          final original = await install(
            fields: '''
          comic = {loadInfo: async () => ({title:'Book',cover:'',tags:{}}), loadEp: async () => [],
            onImageLoad: () => ({onResponse: () => this.loadData('token'), modifyImage: () => 42})};
        ''',
          );
          await original.editData((draft) => draft['token'] = 'old');
          final config = await original.getImageLoadingConfig!(
            'image',
            'book',
            '1',
          );
          final read = config['onResponse'] as JSInvokable;
          final pure = config['modifyImage'] as JSInvokable;
          expect(read([]), 'old');
          await replace(original, init: "this.saveData('token','new');");
          expect(() => read([]), throwsA(anything));
          expect(pure([]), 42);
          discardImageLoadingConfig(config);
          expect(engine.debugOwnedReferenceCount, 0);
        },
      );

      test(
        'first construction preserves absent runtime reads and then loads persisted data',
        () async {
          await File(
            '${root.path}/comic_source/one.data',
          ).writeAsString('{"token":"disk"}');
          final source = await install(
            fields: "initialToken = this.loadData('token');",
          );
          expect(
            engine.runCode('ComicSource.sources.one.initialToken'),
            isNull,
          );
          expect(source.data['token'], 'disk');
          expect(
            engine.runCode("ComicSource.sources.one.loadData('token')"),
            'disk',
          );
        },
      );

      test(
        'login reports a persistence failure and retains credentials for retry',
        () async {
          final source = await install();
          files.beforeReplace = (_, _) =>
              throw const FileSystemException('save denied');
          expect(
            (await source.account!.login!('user', 'password')).error,
            isTrue,
          );
          expect(source.data['account'], ['user', 'password']);
          files.beforeReplace = null;
          await source.saveData();
          expect(saved()['account'], ['user', 'password']);
        },
      );

      test(
        'a context captures identity before its first capability call',
        () async {
          final original = await install();
          final callbacks = JsCallbackScope();
          final context = SourceParserContext(
            key: 'one',
            name: 'Old context',
            callbacks: callbacks,
          );
          await replace(original);
          expect(() => context.getValue('version'), throwsA(anything));
          callbacks.dispose();
        },
      );

      test(
        'password save retry reuses authentication and preserves later edits',
        () async {
          final source = await install();
          final attempt = SourceLoginAttempt.password(
            source,
            'user',
            'password',
          );
          files.beforeReplace = (_, _) =>
              throw const FileSystemException('save denied');
          await expectLater(
            attempt.save(),
            throwsA(isA<FileSystemException>()),
          );
          expect(engine.runCode('ComicSource.sources.one.calls'), 1);
          files.beforeReplace = null;
          await source.editData((draft) => draft['later'] = true);
          expect((await attempt.save()).data, isTrue);
          expect(engine.runCode('ComicSource.sources.one.calls'), 1);
          expect(saved(), {
            'account': ['user', 'password'],
            'later': true,
          });
        },
      );

      for (final web in [false, true]) {
        test(
          'account completion waits for its Promise and discards results; web=$web',
          () async {
            final source = await install(
              fields: '''
            account = {login: async () => {}, logout: async () => {
              await new Promise(resolve => globalThis.finishAccount = resolve);
              return {callback: () => 1};
            }, loginWithWebview: {url: 'https://example.test/', checkStatus: () => true,
              onLoginSuccess: async () => {
                await new Promise(resolve => globalThis.finishAccount = resolve);
                return {callback: () => 2};
              }}};
          ''',
            );
            var finished = false;
            final operation = Future<void>.sync(
              web
                  ? source.account!.onLoginWithWebviewSuccess!
                  : source.account!.logout,
            ).then((_) => finished = true);
            await pumpEventQueue();
            expect(finished, isFalse);
            engine.runCode('finishAccount();');
            await operation;
            expect(engine.debugOwnedReferenceCount, 0);
          },
        );
      }

      test(
        'retained settings callbacks reject temporary replacement and resume after rollback',
        () async {
          final original = await install();
          final scope = original.createSettingsCallbackScope();
          final callback =
              original.getSettingsDynamic(
                    callbacks: scope,
                  )!['action']!['callback']
                  as dynamic Function(List<dynamic>);
          engine.runCode(
            'void (globalThis.replacementReady = new Promise(resolve => globalThis.reportReplacement = resolve));',
          );
          final ready = engine.runCode('replacementReady') as Future;
          final rejected = expectLater(
            replace(
              original,
              init: '''
          reportReplacement(); await new Promise((resolve,reject) => globalThis.failReplacement = reject);
        ''',
            ),
            throwsA(anything),
          );
          await ready;
          expect(() => callback([]), throwsA(anything));
          expect(engine.runCode('ComicSource.sources.one.calls'), 0);
          engine.runCode("failReplacement(new Error('restore original'));");
          await rejected;
          expect(manager.find('one'), same(original));
          expect(callback([]), 1);
          scope.dispose();
        },
      );

      test('late favorite expiry does not relogin the replacement', () async {
        final original = await install(
          fields: '''
        favorites = {multiFolder:false, loadComics: async () => {
          await new Promise(resolve => globalThis.finishFavorite = resolve); throw new Error('Login expired');}};
      ''',
        );
        await original.editData((draft) => draft['account'] = ['u', 'p']);
        final loading = original.favoriteData!.loadComic!(1);
        expect(engine.runCode('typeof finishFavorite'), 'function');
        await replace(original);
        engine.runCode('finishFavorite();');
        expect((await loading).error, isTrue);
        expect(engine.runCode('ComicSource.sources.one.calls'), 0);
      });
    },
    skip: nativeAvailable
        ? false
        : 'QuickJS native library is unavailable on this host',
  );
}
