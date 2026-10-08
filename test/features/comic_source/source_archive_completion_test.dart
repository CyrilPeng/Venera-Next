import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_details/archive_download_dialog.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/comic_source/source.dart';
import 'package:venera_next/features/comic_source/source_comic_parser.dart';
import 'package:venera_next/features/comic_source/source_parser_context.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/network/request_scope.dart';

import '../comic_details/archive_selection_ownership_test.dart'
    show drainArchiveWork, frames;

const _key = 'archive_completion';

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
    'archive source completion',
    () {
      late JsEngine engine;
      late JsCallbackScope callbacks;
      late ArchiveDownloader downloader;
      setUp(() async {
        App.version = 'test';
        App.isInitialized = false;
        Log.isMuted = true;
        JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
        engine = JsEngine();
        await engine.init();
        callbacks = JsCallbackScope();
      });
      tearDown(() async {
        try {
          callbacks.dispose();
          expect(engine.debugOwnedReferenceCount, 0);
          await engine.closeAndWait();
        } finally {
          Log.isMuted = false;
        }
      });

      void install(String body) {
        engine.runCode('''
        void (ComicSource.sources.$_key = {comic: {archive: {
          getArchives: (cid) => { $body },
          getDownloadUrl: (cid, aid) => { $body }
        }}});
        void (globalThis.archiveCalls = 0);
      ''');
        downloader = SourceComicParser(
          SourceParserContext(
            key: _key,
            name: 'Archives',
            callbacks: callbacks,
          ),
        ).parseArchiveDownloader()!;
      }

      Future<Res<Object?>> read(bool url) => url
          ? downloader.getDownloadUrl('comic"名', 'archive\\id')
          : downloader.getArchives('comic"名');

      test(
        'archive models detach while retaining order, duplicates and empty fields',
        () async {
          install('''
        const unused = () => 42;
        return Promise.resolve([
          {id: 'b', title: 'Second', description: '', unused},
          {id: '', title: cid, description: 'Empty id', unused},
          {id: 'b', title: 'Duplicate', description: '', nested: [unused]}
        ]);
      ''');
          final result = await downloader.getArchives('comic"名');
          expect(result.error, isFalse);
          expect(result.data.map((item) => item.id), ['b', '', 'b']);
          expect(result.data.map((item) => item.title), [
            'Second',
            'comic"名',
            'Duplicate',
          ]);
          expect(result.data.map((item) => item.description), [
            '',
            'Empty id',
            '',
          ]);
        },
      );

      test(
        'URL adapter keeps argument escaping, whitespace and empty-string protocol',
        () async {
          install("return cid + ' / ' + aid;");
          expect((await read(true)).data, 'comic"名 / archive\\id');
          for (final value in ["''", "'  https://example.invalid/archive  '"]) {
            install('return $value;');
            expect(
              (await read(true)).data,
              value == "''" ? '' : '  https://example.invalid/archive  ',
            );
          }
        },
      );

      test(
        'invalid consumed and unused values release native references',
        () async {
          install(
            "return [{title:()=>42,id:'id',description:'',extra:()=>42}];",
          );
          expect((await read(false)).error, isTrue);
          install('return {notAUrl:()=>42,nested:[()=>43]};');
          expect((await read(true)).error, isTrue);
        },
      );

      for (final url in [false, true]) {
        test(
          'original thrown and rejected archive graphs are released; URL=$url',
          () async {
            for (final asynchronous in [false, true]) {
              install(
                asynchronous
                    ? 'return Promise.reject({callback:()=>42});'
                    : 'throw {callback:()=>42};',
              );
              final result = await read(url);
              expect(result.error, isTrue);
              final cause = result.failure!.cause as Map;
              expect(result.failure!.stackTrace, isNotNull);
              expect(
                () => (cause['callback'] as JSInvokable)([]),
                throwsA(isA<JsDisposedError>()),
              );
            }
          },
        );

        for (final reject in [false, true]) {
          test(
            'cancelled archive read joins its original Promise; URL=$url, reject=$reject',
            () async {
              install('''
            ++archiveCalls;
            return new Promise((resolve,reject) => {
              globalThis.finishArchive = resolve; globalThis.failArchive = reject;
            });
          ''');
              final scope = RequestScope();
              Res<Object?>? observed;
              var settled = false, released = false;
              final pending = scope.runToCompletion(() async {
                observed = await read(url);
              });
              final checked = expectLater(
                pending,
                throwsA(isA<RequestCancelled>()),
              ).then((_) => settled = true);
              void release() {
                released = true;
                engine.runCode(
                  reject
                      ? 'void failArchive({callback:()=>42})'
                      : url
                      ? 'void finishArchive("late-url")'
                      : 'void finishArchive([{id:"late",title:"Late",description:"",extra:()=>42}])',
                );
              }

              try {
                scope.cancel();
                await pumpEventQueue();
                expect(settled, isFalse);
                release();
                await checked;
                expect(observed!.error, isTrue);
                if (reject) {
                  final error = observed!.failure!.cause as Map;
                  expect(
                    () => (error['callback'] as JSInvokable)([]),
                    throwsA(isA<JsDisposedError>()),
                  );
                } else {
                  expect(observed!.failure!.kind, FailureKind.cancelled);
                  expect(observed!.failure!.cause, isA<RequestCancelled>());
                }
                expect(engine.runCode('archiveCalls'), 1);
              } finally {
                if (!released) release();
                await checked;
                await pumpEventQueue();
                scope.dispose();
              }
            },
          );
        }

        test('read-only transient retry remains bounded; URL=$url', () async {
          install('''
          if (++archiveCalls < 3) throw 'Connection reset by peer';
          return ${url ? "'url'" : "[{id:'id',title:'Name',description:''}]"};
        ''');
          final result = await read(url);
          expect(result.error, isFalse);
          expect(engine.runCode('archiveCalls'), 3);
          if (url) {
            expect(result.data, 'url');
          } else {
            expect((result.data as List<ArchiveInfo>).single.id, 'id');
          }
        });

        test(
          'retired callback owner rejects late archive data; URL=$url',
          () async {
            install(
              'return new Promise(resolve=>{globalThis.finishArchive=resolve;});',
            );
            final pending = read(url);
            callbacks.dispose();
            engine.runCode(
              url
                  ? 'void finishArchive("late")'
                  : 'void finishArchive([{id:"late",title:"Late",description:"",unused:()=>42}])',
            );
            final result = await pending;
            expect(result.error, isTrue);
            expect(result.failure!.cause, isA<StateError>());
          },
        );
      }
      for (final url in [false, true]) {
        for (final reject in [false, true]) {
          testWidgets(
            'removed archive UI joins native ${url ? 'link' : 'list'} ${reject ? 'rejection' : 'resolution'}',
            (tester) async {
              rootBundle.clear();
              final language = appdata.settings['language'];
              appdata.settings['language'] = 'en-US';
              final messages = <String>[];
              registerShowMessageHandler((_, message) => messages.add(message));
              final registry = SelectionTaskRegistry();
              install('''
                archiveCalls++;
                return new Promise((resolve, reject) => {
                  globalThis.finishArchive = resolve;
                  globalThis.failArchive = reject;
                });
              ''');
              if (url) {
                engine.runCode('''
                  void (ComicSource.sources.$_key.comic.archive.getArchives =
                    () => [{id:'choice',title:'Archive choice',description:''}]);
                ''');
              }
              var released = false;
              void release() {
                if (released) return;
                released = true;
                engine.runCode(
                  reject
                      ? 'void (typeof failArchive === "function" && failArchive({message:"native rejection",callback:()=>42}))'
                      : url
                      ? 'void (typeof finishArchive === "function" && finishArchive("synthetic-link"))'
                      : 'void (typeof finishArchive === "function" && finishArchive([{id:"late",title:"Late",description:"",extra:()=>42}]))',
                );
              }

              Future<void> waitFor(bool Function() condition) async {
                for (var i = 0; i < 200 && !condition(); i++) {
                  await tester.runAsync(
                    () =>
                        Future<void>.delayed(const Duration(milliseconds: 10)),
                  );
                  await tester.pump();
                }
                expectSync(condition(), isTrue);
              }

              try {
                await tester.pumpWidget(
                  MaterialApp(
                    home: SelectionTasksScope(
                      registry: registry,
                      child: ArchiveDownloadDialog(
                        downloader: downloader,
                        comicId: 'original',
                      ),
                    ),
                  ),
                );
                await tester.tap(find.text('Archive').first);
                await frames(tester);
                if (url) {
                  await waitFor(
                    () => find.text('Archive choice').evaluate().isNotEmpty,
                  );
                  tester
                      .widget<RadioGroup<int>>(find.byType(RadioGroup<int>))
                      .onChanged(0);
                  await frames(tester);
                  await tester.tap(find.text('Confirm'));
                }
                await waitFor(() => engine.runCode('archiveCalls') == 1);
                await tester.pumpWidget(const SizedBox());
                var closed = false;
                final closing = registry.closeAndWait().then(
                  (_) => closed = true,
                );
                await frames(tester);
                expect(closed, isFalse);
                release();
                await drainArchiveWork(tester, () => closing);
                expect(closed, isTrue);
                expect(engine.runCode('archiveCalls'), 1);
                expect(messages, isEmpty);
                expect(tester.takeException(), isNull);
              } finally {
                release();
                await tester.pumpWidget(const SizedBox());
                await drainArchiveWork(tester, registry.closeAndWait);
                appdata.settings['language'] = language;
                registerShowMessageHandler((_, _) {});
              }
            },
          );
        }
      }
    },
    skip: !nativeAvailable ? 'QuickJS native library unavailable' : false,
  );
}
