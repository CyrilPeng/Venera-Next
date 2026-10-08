import 'dart:ffi';
import 'dart:io';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/request_scope.dart';

const _key = 'action_completion';
const _comicId = 'book"名\nline';
const _text = 'text\\"内容';

enum _Action {
  likeComic,
  starRating,
  sendComment,
  sendChapterComment,
  voteComment,
  likeComment,
  addOrDelFavorite,
  addFolder,
  deleteFolder;

  bool get numeric => this == voteComment || this == likeComment;

  Future<Res<Object?>> call(ComicSource source) => switch (this) {
    likeComic => source.likeOrUnlikeComic!(_comicId, true),
    starRating => source.starRatingFunc!(_comicId, 7),
    sendComment => source.sendCommentFunc!(_comicId, null, _text, 'reply'),
    sendChapterComment => source.sendChapterCommentFunc!(
      _comicId,
      'chapter',
      _text,
      null,
    ),
    voteComment => source.voteCommentFunc!(
      _comicId,
      null,
      'comment',
      false,
      true,
    ),
    likeComment => source.likeCommentFunc!(
      _comicId,
      'chapter',
      'comment',
      false,
    ),
    addOrDelFavorite => source.favoriteData!.addOrDelFavorite!(
      _comicId,
      'folder',
      true,
      'unused-legacy-id',
    ),
    addFolder => source.favoriteData!.addFolder!(_text),
    deleteFolder => source.favoriteData!.deleteFolder!('folder'),
  };

  List<Object?> get arguments => switch (this) {
    likeComic => [_comicId, true],
    starRating => [_comicId, 7],
    sendComment => [_comicId, null, _text, 'reply'],
    sendChapterComment => [_comicId, 'chapter', _text, null],
    voteComment => [_comicId, null, 'comment', false, true],
    likeComment => [_comicId, 'chapter', 'comment', false],
    addOrDelFavorite => [_comicId, 'folder', true],
    addFolder => [_text],
    deleteFolder => ['folder'],
  };
}

const _script =
    '''
class ActionCompletionSource extends ComicSource {
  name = 'Actions'; key = '$_key'; version = '1.0.0'; minAppVersion = '1.0.0';
  mode = 'number'; calls = []; logins = 0; expire = false; failLogin = false;
  act(name, args) {
    this.calls.push([name, args]);
    if (this.expire) throw 'Login expired';
    if (this.mode === 'transient') throw 'Connection reset by peer';
    if (this.mode === 'pending') return new Promise((resolve, reject) => {
      globalThis.finishAction = resolve; globalThis.failAction = reject;
    });
    const callback = () => 42;
    const graph = {message: 'action failed', callback, nested: [callback, {callback}]};
    if (this.mode === 'throw') throw graph;
    if (this.mode === 'reject') return Promise.reject(graph);
    if (this.mode === 'graph') return graph;
    if (this.mode === 'asyncGraph') return Promise.resolve(graph);
    if (this.mode === 'null') return null;
    return -8.75;
  }
  account = {
    login: () => {this.logins++; if (this.failLogin) throw 'login failed'; this.expire = false;},
    logout: () => {}
  };
  comic = {
    loadInfo: () => ({title: 'Book', cover: '', tags: {}}), loadEp: () => [],
    likeComic: (...args) => this.act('likeComic', args),
    starRating: (...args) => this.act('starRating', args),
    sendComment: (...args) => this.act('sendComment', args),
    sendChapterComment: (...args) => this.act('sendChapterComment', args),
    voteComment: (...args) => this.act('voteComment', args),
    likeComment: (...args) => this.act('likeComment', args)
  };
  favorites = {
    multiFolder: true,
    addOrDelFavorite: (...args) => this.act('addOrDelFavorite', args),
    addFolder: (...args) => this.act('addFolder', args),
    deleteFolder: (...args) => this.act('deleteFolder', args),
    loadFolders: () => ({folders: {}})
  };
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
    'source action completion',
    () {
      late Directory root;
      late JsEngine engine;
      late ComicSourceManager manager;
      late ComicSource source;

      setUp(() async {
        root = Directory.systemTemp.createTempSync('source-action-');
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
        manager = ComicSourceManager();
        source = await ComicSourceParser().parse(
          _script,
          '${root.path}/comic_source/action.js',
        );
        manager.add(source);
        await source.editData((data) => data['account'] = ['user', 'password']);
      });

      tearDown(() async {
        try {
          await manager.closeAndWait();
          expect(engine.debugOwnedReferenceCount, 0);
          // Native close also checks raw runCode references, which are not
          // counted by debugOwnedReferenceCount until the runtime adopts them.
          await engine.closeAndWait();
        } finally {
          await appdata.saveData(false);
          await root.delete(recursive: true);
          Log.isMuted = false;
        }
      });

      void setMode(String mode) =>
          engine.runCode("void (ComicSource.sources.$_key.mode = '$mode')");
      Object? read(String expression) =>
          engine.runCode('ComicSource.sources.$_key.$expression');

      for (final action in _Action.values) {
        test(
          '${action.name} releases unused sync and Promise result graphs',
          () async {
            for (final mode in ['graph', 'asyncGraph']) {
              setMode(mode);
              final result = await action.call(source);
              expect(result.error, isFalse);
              expect(result.data, action.numeric ? 0 : true);
              expect(engine.debugOwnedReferenceCount, 0);
            }
            expect(read('calls'), [
              [action.name, action.arguments],
              [action.name, action.arguments],
            ]);
          },
        );

        test(
          '${action.name} releases original thrown and rejected references',
          () async {
            for (final mode in ['throw', 'reject']) {
              setMode(mode);
              final result = await action.call(source);
              expect(result.error, isTrue);
              final error = result.failure!.cause as Map;
              expect(error['message'], 'action failed');
              expect(result.failure!.stackTrace, isNotNull);
              expect(
                () => (error['callback'] as JSInvokable)([]),
                throwsA(isA<JsDisposedError>()),
              );
              expect(engine.debugOwnedReferenceCount, 0);
            }
          },
        );
      }

      test(
        'transient failures execute each mutation once and retain the original error',
        () async {
          setMode('transient');
          for (final action in _Action.values) {
            final result = await action.call(source);
            expect(result.error, isTrue);
            expect(result.failure!.cause, 'Connection reset by peer');
          }
          expect(read('calls'), [
            for (final action in _Action.values)
              [action.name, action.arguments],
          ]);
        },
      );

      test(
        'arguments, ignored returns and numeric reaction conversion remain compatible',
        () async {
          for (final mode in ['number', 'null']) {
            setMode(mode);
            for (final action in _Action.values) {
              final result = await action.call(source);
              expect(result.error, isFalse);
              expect(
                result.data,
                action.numeric ? (mode == 'number' ? -8 : 0) : true,
              );
            }
          }
          expect(read('calls'), [
            for (var pass = 0; pass < 2; pass++)
              for (final action in _Action.values)
                [action.name, action.arguments],
          ]);
        },
      );

      for (final failLogin in [false, true]) {
        test(
          'existing login-expired retry is retained; login failure=$failLogin',
          () async {
            const actions = [
              _Action.sendComment,
              _Action.sendChapterComment,
              _Action.addOrDelFavorite,
            ];
            for (final action in actions) {
              engine.runCode('''void Object.assign(ComicSource.sources.$_key, {
            expire: true, failLogin: $failLogin, calls: [], logins: 0
          })''');
              final result = await action.call(source);
              expect(result.error, failLogin);
              expect(read('logins'), 1);
              expect(read('calls'), [
                [action.name, action.arguments],
                if (!failLogin) [action.name, action.arguments],
              ]);
              if (failLogin) {
                expect(
                  result.errorMessage,
                  'Login expired and re-login failed',
                );
              }
            }
          },
        );
      }

      test(
        'accepted mutation joins its Promise without converting its result on scope cancellation',
        () async {
          setMode('pending');
          final scope = RequestScope();
          Res<Object?>? delivered;
          var settled = false;
          final pending = scope.runToCompletion(() async {
            delivered = await _Action.likeComic.call(source);
          });
          final checked = expectLater(
            pending,
            throwsA(isA<RequestCancelled>()),
          ).then((_) => settled = true);
          scope.cancel();
          await pumpEventQueue();
          expect(settled, isFalse);
          engine.runCode('void finishAction({unused: () => 42})');
          await checked;
          expect(delivered!.data, isTrue);
          expect(read('calls.length'), 1);
          scope.dispose();
        },
      );

      for (final reject in [false, true]) {
        test(
          'retired source cannot publish into its same-key replacement; reject=$reject',
          () async {
            setMode('pending');
            final old = source;
            final pending = _Action.starRating.call(old);
            manager.remove(_key);
            source = await ComicSourceParser().parse(
              _script,
              '${root.path}/comic_source/replacement.js',
            );
            manager.add(source);
            engine.runCode(
              reject
                  ? 'void failAction({callback: () => 42})'
                  : 'void finishAction({callback: () => 42})',
            );
            expect((await pending).error, isTrue);
            expect((await _Action.starRating.call(old)).error, isTrue);
            expect(read('calls'), isEmpty);
          },
        );
      }
    },
    skip: !nativeAvailable ? 'QuickJS native library unavailable' : false,
  );
}
