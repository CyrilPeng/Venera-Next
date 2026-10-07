import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/comic_source/source_comments_parser.dart';
import 'package:venera_next/features/comic_source/source_parser_context.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/request_scope.dart';

const _key = 'comments_completion_test';

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

  for (final chapter in [false, true]) {
    group(
      'owned comments; chapter=$chapter',
      () {
        late JsEngine engine;
        late JsCallbackScope callbacks;
        late Future<Res<List<Comment>>> Function() load;
        setUp(() async {
          App.version = 'test';
          App.isInitialized = false;
          Log.isMuted = true;
          JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
          engine = JsEngine();
          await engine.init();
          callbacks = JsCallbackScope();
        });
        tearDown(() {
          expect(engine.debugOwnedReferenceCount, 0);
          callbacks.dispose();
          engine.dispose();
          Log.isMuted = false;
        });

        void install(String body) {
          final method = chapter ? 'loadChapterComments' : 'loadComments';
          engine.runCode('''
          void (ComicSource.sources.$_key = {comic: {
            $method: (id, subId, page, replyTo) => { $body }
          }});
        ''');
          final parser = SourceCommentsParser(
            SourceParserContext(
              key: _key,
              name: 'Owned comments',
              callbacks: callbacks,
            ),
          );
          final capability = chapter
              ? parser.parseChapterCommentsLoader()!
              : parser.parseCommentsLoader()!;
          load = () => capability('book', 'chapter', 2, 'reply');
        }

        test(
          'detaches comments and releases unused and aliased references',
          () async {
            install('''
          const extra = () => 42;
          return {comments: [{id: replyTo, userName: id, content: subId,
            score: page, extra}], maxPage: 3, unused: [extra, {alias: extra}]};
        ''');
            final result = await load();
            expect(result.error, false);
            expect(result.subData, 3);
            expect(result.data.single.id, 'reply');
            expect(result.data.single.userName, 'book');
            expect(result.data.single.content, 'chapter');
            expect(result.data.single.score, 2);
            expect(engine.debugOwnedReferenceCount, 0);
          },
        );

        for (final data in [
          '{comments: callback, extra: callback}',
          '{comments: [{userName: callback, content: "text"}], extra: callback}',
          '{comments: [], maxPage: callback, extra: callback}',
        ]) {
          test('invalid result releases its complete graph: $data', () async {
            install('const callback = () => 42; return $data;');
            final result = await load();
            expect(result.error, true);
            expect(result.failure, isNotNull);
            expect(engine.debugOwnedReferenceCount, 0);
          });
        }

        for (final asynchronous in [false, true]) {
          test(
            'thrown graph is released; asynchronous=$asynchronous',
            () async {
              install(
                asynchronous
                    ? 'return Promise.reject({callback: () => 42});'
                    : 'throw {callback: () => 42};',
              );
              final result = await load();
              expect(result.error, true);
              final error = result.failure!.cause as Map;
              expect(error['callback'], isA<JSInvokable>());
              expect(
                () => (error['callback'] as JSInvokable)([]),
                throwsA(isA<JsDisposedError>()),
              );
              expect(engine.debugOwnedReferenceCount, 0);
            },
          );
        }

        for (final reject in [false, true]) {
          test(
            'cancellation joins actual Promise without retry; reject=$reject',
            () async {
              engine.runCode('void (globalThis.commentCalls = 0)');
              install('''
            ++commentCalls;
            return new Promise((resolve, reject) => {
              globalThis.finishComments = resolve;
              globalThis.failComments = reject;
            });
          ''');
              final scope = RequestScope();
              Res<List<Comment>>? observed;
              var settled = false;
              final pending = scope.runToCompletion(() async {
                observed = await load();
              });
              final checked = expectLater(
                pending,
                throwsA(isA<RequestCancelled>()),
              ).then((_) => settled = true);
              expect(engine.runCode('commentCalls'), 1);
              scope.cancel();
              await pumpEventQueue();
              expect(settled, false);
              engine.runCode(
                reject
                    ? 'void failComments("Connection reset by peer")'
                    : 'void finishComments({comments: [], extra: () => 42})',
              );
              await checked;
              expect(observed!.error, true);
              expect(
                observed!.failure!.cause,
                reject ? 'Connection reset by peer' : isA<RequestCancelled>(),
              );
              expect(engine.runCode('commentCalls'), 1);
              expect(engine.debugOwnedReferenceCount, 0);
              scope.dispose();
            },
          );
        }

        test(
          'source replacement retires captured loader and releases late data',
          () async {
            install(
              'return new Promise(resolve => globalThis.finishComments = resolve);',
            );
            final pending = load();
            engine.runCode('void (ComicSource.sources.$_key = {})');
            engine.runCode(
              'void finishComments({comments: [], extra: () => 42})',
            );
            expect((await pending).error, true);
            expect((await load()).error, true);
            expect(engine.debugOwnedReferenceCount, 0);
          },
        );

        test(
          'disposed callback scope returns a failure before calling JS',
          () async {
            install('return {comments: []};');
            callbacks.dispose();
            expect((await load()).error, true);
          },
        );
      },
      skip: !nativeAvailable ? 'QuickJS native library unavailable' : false,
    );
  }
}
