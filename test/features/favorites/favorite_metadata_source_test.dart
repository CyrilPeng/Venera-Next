import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/features/comic_source/source_comic_parser.dart';
import 'package:venera_next/features/comic_source/source_parser_context.dart';
import 'package:venera_next/features/favorites/favorite_metadata_update.dart';
import 'package:venera_next/features/favorites/favorite_models.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/operation_failure.dart';

const _key = 'favorite_metadata_native';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  App.dataPath = Directory.systemTemp.path;
  App.cachePath = Directory.systemTemp.path;
  late JsEngine engine;
  late JsCallbackScope callbacks;
  late Directory root;
  late String previousPath;
  late String previousCache;
  late bool muted;
  setUp(() async {
    if (Platform.isWindows) {
      final path = Directory('build/windows/x64/runner/Release').absolute.path;
      DynamicLibrary.open('$path/flutter_windows.dll');
      DynamicLibrary.open('$path/flutter_qjs_plugin.dll');
    }
    previousPath = App.dataPath;
    previousCache = App.cachePath;
    muted = Log.isMuted;
    root = Directory.systemTemp.createTempSync('venera-metadata-source-owned-');
    App.dataPath = root.path;
    App.cachePath = root.path;
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
    App.dataPath = previousPath;
    App.cachePath = previousCache;
    Log.isMuted = muted;
    final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
    final owned = root.resolveSymbolicLinksSync();
    expect(p.isWithin(temporary, owned), isTrue);
    expect(p.basename(owned), startsWith('venera-metadata-source-owned-'));
    root.deleteSync(recursive: true);
  });

  FavoriteMetadataUpdate operation(String body, List<FavoriteItem> saves) {
    engine.runCode('''
      void (globalThis.metadataCalls = 0);
      void (ComicSource.sources.$_key = {comic: {
        loadInfo: () => { ++metadataCalls; $body }
      }});
    ''');
    final parser = SourceComicParser(
      SourceParserContext(
        key: _key,
        name: 'Synthetic metadata source',
        callbacks: callbacks,
      ),
    );
    final load = parser.parseLoadComicFunc()!;
    return FavoriteMetadataUpdate(
      comics: [
        FavoriteItem.withTime(
          id: 'original',
          type: ComicType(_key.hashCode),
          time: 'legacy: preserved',
          name: 'Original',
          author: 'old author',
          coverPath: '',
          tags: ['old tag'],
        ),
      ],
      load: (item) => load(item.id),
      save: (item) async => saves.add(item.detached()),
      checkActive: () {},
    );
  }

  test(
    'metadata service consumes the real source parser and releases native references',
    () async {
      final saves = <FavoriteItem>[];
      final update = operation('''
      return {title: 'Updated', cover: '', tags: {genre: ['tag']},
        unused: {callback: () => 42}};
    ''', saves);
      final result = await update.run();
      expect(result.cancelled, isFalse);
      expect(result.progress.updated, 1);
      expect(result.failures, isEmpty);
      expect(saves.single.id, 'original');
      expect(saves.single.name, 'Updated');
      expect(saves.single.time, 'legacy: preserved');
      expect(saves.single.tags, ['genre:tag']);
      expect(engine.runCode('metadataCalls'), 1);
      expect(engine.debugOwnedReferenceCount, 0);
    },
  );

  for (final reject in [false, true]) {
    test(
      'metadata cancellation joins original native promise; rejection=$reject',
      () async {
        final saves = <FavoriteItem>[];
        final update = operation('''
        return new Promise((resolve, reject) => {
          globalThis.metadataFinish = resolve;
          globalThis.metadataFail = reject;
        });
      ''', saves);
        var settled = false;
        final pending = update.run().then((result) {
          settled = true;
          return result;
        });
        await pumpEventQueue();
        expect(engine.runCode('metadataCalls'), 1);
        update.cancel();
        await pumpEventQueue();
        expect(settled, isFalse);
        engine.runCode(
          reject
              ? 'void metadataFail("original source rejected")'
              : 'void metadataFinish({title: "Late", cover: "", tags: {}, extra: () => 42})',
        );
        final result = await pending;
        expect(result.cancelled, isTrue);
        expect(saves, isEmpty);
        expect(engine.runCode('metadataCalls'), 1);
        expect(engine.debugOwnedReferenceCount, 0);
        if (reject) {
          final failure = result.failures.single;
          expect(failure.kind, FailureKind.failed);
          expect(failure.stage, FavoriteMetadataStage.load);
          expect(
            (failure.cause as FailureDetails).cause,
            'original source rejected',
          );
        } else {
          expect(result.failures, isEmpty);
        }
      },
    );
  }
}
