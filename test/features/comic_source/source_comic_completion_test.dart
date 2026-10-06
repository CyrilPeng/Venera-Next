import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/comic_source/source_comic_parser.dart';
import 'package:venera_next/features/comic_source/source_parser_context.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/request_scope.dart';

const _key = 'comic_completion_test';

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
    'owned comic details',
    () {
      late JsEngine engine;
      late JsCallbackScope callbacks;
      late SourceComicParser parser;
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
        engine.runCode('''
        void (ComicSource.sources.$_key = {comic: {
          loadInfo: () => { $body }
        }});
      ''');
        parser = SourceComicParser(
          SourceParserContext(
            key: _key,
            name: 'Owned details',
            callbacks: callbacks,
          ),
        );
      }

      test(
        'models detach nested collections before unused JS references are released',
        () async {
          install('''
        const extra = () => 42;
        return {
          title: 'Book', cover: 'cover', tags: {genre: ['tag']},
          chapters: {group: {chapter: 'Chapter'}}, thumbnails: ['thumb'],
          recommend: [{id: 'recommended', title: 'Other', cover: 'other', tags: ['rec'], extra}],
          comments: [{userName: 'Reader', content: 'Text', time: 1, extra}],
          unused: [extra, {alias: extra}]
        };
      ''');
          final result = await parser.parseLoadComicFunc()!('book');
          expect(result.error, false);
          expect(engine.debugOwnedReferenceCount, 0);
          final details = result.data;
          expect(details.tags, {
            'genre': ['tag'],
          });
          expect(details.chapters!.ids, ['chapter']);
          expect(details.chapters!.titles, ['Chapter']);
          expect(details.thumbnails, ['thumb']);
          expect(details.recommend!.single.tags, ['rec']);
          expect(details.comments!.single.content, 'Text');
        },
      );

      test(
        'invalid model input releases references in both consumed and unused fields',
        () async {
          install('''
        const callback = () => 42;
        return {title: callback, cover: '', tags: {}, extra: callback};
      ''');
          final result = await parser.parseLoadComicFunc()!('book');
          expect(result.error, true);
          expect(result.failure, isNotNull);
          expect(engine.debugOwnedReferenceCount, 0);
        },
      );

      for (final asynchronous in [false, true]) {
        test(
          'thrown reference graph is released; asynchronous=$asynchronous',
          () async {
            install(
              asynchronous
                  ? 'return Promise.reject({callback: () => 42});'
                  : 'throw {callback: () => 42};',
            );
            final result = await parser.parseLoadComicFunc()!('book');
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
          'cancelled details still join their original Promise; reject=$reject',
          () async {
            engine.runCode('void (globalThis.detailsCalls = 0)');
            install('''
          ++detailsCalls;
          return new Promise((resolve, reject) => {
            globalThis.finishDetails = resolve;
            globalThis.failDetails = reject;
          });
        ''');
            final scope = RequestScope();
            Res<ComicDetails>? observed;
            var settled = false;
            final pending = scope.runToCompletion(() async {
              observed = await parser.parseLoadComicFunc()!('book');
            });
            final checked = expectLater(
              pending,
              throwsA(isA<RequestCancelled>()),
            ).then((_) => settled = true);
            expect(engine.runCode('detailsCalls'), 1);
            scope.cancel();
            await pumpEventQueue();
            expect(settled, false);
            engine.runCode(
              reject
                  ? 'void failDetails("Connection reset by peer")'
                  : 'void finishDetails({title: "Book", cover: "", tags: {}, extra: () => 42})',
            );
            await checked;
            expect(observed!.error, true);
            expect(
              observed!.failure!.cause,
              reject ? 'Connection reset by peer' : isA<RequestCancelled>(),
            );
            expect(engine.runCode('detailsCalls'), 1);
            expect(engine.debugOwnedReferenceCount, 0);
            scope.dispose();
          },
        );
      }
    },
    skip: !nativeAvailable ? 'QuickJS native library unavailable' : false,
  );
}
