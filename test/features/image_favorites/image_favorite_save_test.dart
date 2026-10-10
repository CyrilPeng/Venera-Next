import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/comic_details/cover_viewer.dart';
import 'package:venera_next/features/history/image_favorites_models.dart';
import 'package:venera_next/features/image_favorites/image_favorites_photo_view.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/file_interaction.dart' as interaction;
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:window_manager/window_manager.dart';

const _selector = MethodChannel('plugins.flutter.io/file_selector');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late Directory cache;
  late bool previousLogMuted;
  late String previousData, previousCache;

  setUpAll(() {
    App.dataPath = Directory.systemTemp.path;
    App.cachePath = Directory.systemTemp.path;
  });
  setUp(() {
    root = Directory.systemTemp.createTempSync('favorite-save-ui-');
    cache = Directory(p.join(root.path, 'cache'))..createSync();
    previousData = App.dataPath;
    previousCache = App.cachePath;
    App.dataPath = root.path;
    App.cachePath = cache.path;
    previousLogMuted = Log.isMuted;
    Log.isMuted = true;
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (_) async => false,
    );
  });
  tearDown(() {
    LocalManager.current?.dispose();
    messenger.setMockMethodCallHandler(_selector, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
    App.dataPath = previousData;
    App.cachePath = previousCache;
    Log.isMuted = previousLogMuted;
    root.deleteSync(recursive: true);
  });

  testWidgets(
    'favorite save captures original page and mutable model, then releases PageController',
    (tester) async {
      final red = _png(255, 0, 0);
      final blue = _png(0, 0, 255);
      late Directory pages;
      await tester.runAsync(() async {
        LocalManager.current?.dispose();
        LocalManager(initializeSources: () async {});
        final manager = LocalManager();
        await manager.init();
        pages = Directory(p.join(manager.path, 'book'))
          ..createSync(recursive: true);
        File(p.join(pages.path, '1.png')).writeAsBytesSync(red);
        File(p.join(pages.path, '2.png')).writeAsBytesSync(blue);
        await manager.add(
          LocalComic(
            id: 'book',
            title: 'Book',
            subtitle: '',
            tags: const [],
            directory: 'book',
            chapters: null,
            cover: '',
            comicType: ComicType.local,
            downloadedChapters: const [],
            createdAt: DateTime(2026),
          ),
        );
      });
      final first = ImageFavorite(
        1,
        'original',
        false,
        '',
        'book',
        1,
        'local',
        '',
      );
      final second = first.copyWith(page: 2, imageKey: 'second');
      final comic = ImageFavoritesComic(
        'book',
        [
          ImageFavoritesEp('', 1, [first, second], '', 2),
        ],
        'Book',
        'local',
        [],
        [],
        DateTime(2026),
        '',
        {},
        '',
        2,
      );
      final destination = File(p.join(root.path, 'export.png'));
      String? suggestedName;
      messenger.setMockMethodCallHandler(_selector, (call) async {
        expect(call.method, 'getSavePath');
        suggestedName = call.arguments['suggestedName'] as String;
        return destination.path;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ImageFavoritesPhotoView(comic: comic, imageFavorite: first),
        ),
      );
      await _until(
        tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      final controller = tester
          .widget<PageView>(find.byType(PageView))
          .controller!;
      await tester.tapAt(tester.getCenter(find.byType(PageView)));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      final read = _SaveReadOverrides(pages.path);
      await IOOverrides.runWithIOOverrides(
        () => tester.tap(find.text('Save Image')),
        read,
      );
      await _until(tester, () => read.listEntered.isCompleted);
      controller.jumpToPage(1);
      await tester.pump();
      // The pending save has not selected its file yet. Changing the live model
      // here would change that selection unless the page captured a snapshot.
      first.page = 99;
      first.imageKey = 'changed while saving';
      read.listRelease.complete();
      await _until(tester, () => read.readEntered.isCompleted);
      expect(p.basename(read.readPath!), '1.png');
      expect(suggestedName, isNull);
      read.readRelease.complete();
      await _until(
        tester,
        () => destination.existsSync() && !interaction.IO.isSelectingFiles,
      );
      expect(controller.page, 1);
      expect(suggestedName, '1.png');
      expect(destination.readAsBytesSync(), red);
      expect(cache.listSync().whereType<Directory>(), isEmpty);
      await _disposeImages(tester);
      expect(() => controller.addListener(() {}), throwsFlutterError);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cover provider converts real image and window drains a late picker without writing',
    (tester) async {
      final reply = Completer<String?>();
      final destination = File(p.join(root.path, 'cover.png'));
      String? suggestedName;
      var exits = 0;
      messenger.setMockMethodCallHandler(_selector, (call) {
        expect(call.method, 'getSavePath');
        suggestedName = call.arguments['suggestedName'] as String;
        return reply.future;
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => WindowFrame(child!, onExit: () => exits++),
          home: ComicCoverViewer(
            imageProvider: MemoryImage(_png(23, 45, 67)),
            title: 'Sample',
            heroTag: 'sample cover',
          ),
        ),
      );
      await _until(
        tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      await tester.tap(find.byIcon(Icons.save_alt));
      await _until(tester, () => suggestedName != null);
      expect(suggestedName, 'cover_Sample.png');
      final staged = cache.listSync().whereType<Directory>().single;
      final source = File(p.join(staged.path, 'contents', 'cover_Sample.png'));
      final encoded = image.decodePng(source.readAsBytesSync())!;
      expect([encoded.width, encoded.height], [3, 2]);
      final pixel = encoded.getPixel(1, 1);
      expect([pixel.r, pixel.g, pixel.b], [23, 45, 67]);
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await tester.pump(const Duration(milliseconds: 150));
      expect(exits, 0);
      expect(source.existsSync(), isTrue);
      expect(interaction.IO.isSelectingFiles, isTrue);
      reply.complete(destination.path);
      await _until(tester, () => exits == 1);
      expect(destination.existsSync(), isFalse);
      expect(source.existsSync(), isFalse);
      expect(cache.listSync(), isEmpty);
      await _disposeImages(tester);
      expect(tester.takeException(), isNull);
    },
  );
}

Uint8List _png(int red, int green, int blue) {
  final pixels = image.Image(width: 3, height: 2);
  image.fill(pixels, color: image.ColorRgb8(red, green, blue));
  return Uint8List.fromList(image.encodePng(pixels));
}

Future<void> _until(WidgetTester tester, bool Function() complete) async {
  for (var i = 0; i < 200 && !complete(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(complete(), isTrue);
}

Future<void> _disposeImages(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  PaintingBinding.instance.imageCache.clear();
  PaintingBinding.instance.imageCache.clearLiveImages();
  await tester.pump();
  await tester.runAsync(() async {
    final release = await BaseImageProvider.prepareForExit();
    release();
  });
  await tester.pump(const Duration(milliseconds: 150));
}

final class _SaveReadOverrides extends IOOverrides {
  _SaveReadOverrides(this.directory);
  final _nativeZone = Zone.current;
  final String directory;
  final listEntered = Completer<void>();
  final listRelease = Completer<void>();
  final readEntered = Completer<void>();
  final readRelease = Completer<void>();
  String? readPath;

  // Preserve native type queries while delaying only reads. The default
  // IOOverrides adapter misreports existing Windows paths on Dart 3.11.
  @override
  Future<FileSystemEntityType> fseGetType(String path, bool followLinks) =>
      _nativeZone.run(
        () => FileSystemEntity.type(path, followLinks: followLinks),
      );

  @override
  Directory createDirectory(String path) {
    final raw = super.createDirectory(path);
    return p.equals(p.normalize(path), p.normalize(directory))
        ? _DelayedDirectory(raw, listEntered, listRelease.future)
        : raw;
  }

  @override
  File createFile(String path) {
    final raw = super.createFile(path);
    if (!p.isWithin(directory, path)) return raw;
    return _DelayedFile(raw, () async {
      readPath = path;
      if (!readEntered.isCompleted) readEntered.complete();
      await readRelease.future;
      return raw.readAsBytes();
    });
  }
}

class _DelayedDirectory implements Directory {
  _DelayedDirectory(this.raw, this.entered, this.release);
  final Directory raw;
  final Completer<void> entered;
  final Future<void> release;
  @override
  String get path => raw.path;
  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    if (!entered.isCompleted) entered.complete();
    await release;
    yield* raw.list(recursive: recursive, followLinks: followLinks);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DelayedFile implements File {
  _DelayedFile(this.raw, this.read);
  final File raw;
  final Future<Uint8List> Function() read;
  @override
  String get path => raw.path;
  @override
  Future<Uint8List> readAsBytes() => read();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
