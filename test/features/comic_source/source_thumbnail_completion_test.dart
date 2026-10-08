import 'dart:io';
import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/features/comic_source/source_images_parser.dart';
import 'package:venera_next/features/comic_source/source_parser_context.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:venera_next/features/comic_details/thumbnail_pages.dart';
import 'package:venera_next/foundation/selection_operation.dart';

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
    'owned thumbnail results',
    () {
      late JsEngine engine;
      late JsCallbackScope callbacks;
      late SourceImagesParser parser;
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
        engine.runCode(
          'void (ComicSource.sources.thumbnail_completion={comic:{loadThumbnails:(id,next)=>{$body}}});',
        );
        parser = SourceImagesParser(
          SourceParserContext(
            key: 'thumbnail_completion',
            name: 'Thumbnail test',
            callbacks: callbacks,
          ),
        );
      }

      test(
        'valid cursor and thumbnail order detach from unused references',
        () async {
          install(
            "const callback=()=>42;return {thumbnails:[id,next ?? 'first',id],next:'',unused:[callback,{alias:callback}]};",
          );
          final result = await parser.parseThumbnailLoader()!('book', null);
          expect(result.error, isFalse);
          expect(result.data, ['book', 'first', 'book']);
          expect(result.subData, '');
          expect(engine.debugOwnedReferenceCount, 0);
        },
      );
      for (final cursor in ['7', '()=>42']) {
        test(
          'invalid cursor is a structured failure and releases references: $cursor',
          () async {
            install('return {thumbnails:["page"],next:$cursor,unused:()=>42};');
            final result = await parser.parseThumbnailLoader()!('book', null);
            expect(result.error, isTrue);
            expect(result.failure!.cause, isA<FormatException>());
          },
        );
      }
      test(
        'invalid image list and thrown graphs release native references',
        () async {
          install('return {thumbnails:[()=>42],extra:()=>42};');
          expect(
            (await parser.parseThumbnailLoader()!('book', null)).error,
            isTrue,
          );
          install('return Promise.reject({extra:()=>42});');
          final result = await parser.parseThumbnailLoader()!('book', null);
          final failure = result.failure!.cause as Map;
          expect(
            () => (failure['extra'] as JSInvokable)([]),
            throwsA(isA<JsDisposedError>()),
          );
        },
      );
      for (final reject in [false, true]) {
        test(
          'cancelled thumbnail read joins its original promise: reject=$reject',
          () async {
            install(
              'return new Promise((resolve,reject)=>{globalThis.finishThumbnail=resolve;globalThis.failThumbnail=reject;});',
            );
            final scope = RequestScope();
            var settled = false;
            final pending = scope.runToCompletion(
              () => parser.parseThumbnailLoader()!('book', null),
            );
            final checked = expectLater(
              pending,
              throwsA(isA<RequestCancelled>()),
            ).then((_) => settled = true);
            scope.cancel();
            await pumpEventQueue();
            expect(settled, isFalse);
            engine.runCode(
              reject
                  ? 'void failThumbnail({extra:()=>42})'
                  : 'void finishThumbnail({thumbnails:["late"],unused:()=>42})',
            );
            await checked;
            expect(engine.debugOwnedReferenceCount, 0);
            scope.dispose();
          },
        );
      }
      test(
        'application registry drains real thumbnail JS through its page owner',
        () async {
          install(
            'return new Promise(resolve=>{globalThis.finishThumbnail=resolve;});',
          );
          final registry = SelectionTaskRegistry();
          final pages = ComicThumbnailPages(
            comicId: 'book',
            initial: [],
            load: parser.parseThumbnailLoader(),
            canLoad: () => true,
            onChanged: () {},
            retain: (scope, settled) => registry.retain(
              cancel: scope.cancel,
              close: () {
                scope.cancel();
                return settled;
              },
            ),
          );
          final read = pages.loadNext();
          await pumpEventQueue();
          var closed = false;
          final close = registry.closeAndWait().then((_) => closed = true);
          await pumpEventQueue();
          expect(closed, isFalse);
          engine.runCode(
            'void finishThumbnail({thumbnails:["late"],extra:()=>42})',
          );
          await close;
          await read;
          expect(pages.items, isEmpty);
          expect(pages.failure!.failure!.kind, FailureKind.cancelled);
          expect(pages.failure!.failure!.cause, isA<RequestCancelled>());
          expect(pages.failure!.failure!.stackTrace, isNotNull);
          expect(engine.debugOwnedReferenceCount, 0);
          await pages.closeAndWait();
        },
      );
      test('retired source cannot publish a late thumbnail result', () async {
        install(
          'return new Promise(resolve=>{globalThis.finishThumbnail=resolve;});',
        );
        final pending = parser.parseThumbnailLoader()!('book', null);
        callbacks.dispose();
        engine.runCode(
          'void finishThumbnail({thumbnails:["late"],extra:()=>42})',
        );
        final result = await pending;
        expect(result.error, isTrue);
        expect(result.failure, isNotNull);
      });
    },
    skip: !nativeAvailable ? 'QuickJS native library unavailable' : false,
  );
}
