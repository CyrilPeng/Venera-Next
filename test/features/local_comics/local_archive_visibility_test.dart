import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart' as archive;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/features/local_comics/import_export/cbz.dart';
import 'package:venera_next/features/local_comics/import_export/comic_import_service.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/local_comics/local_comics_page.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/file_selection.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/routing/app_navigation.dart';

const _names = [
  'Sample24.zip',
  'Sample.Artist.V.24.black.and.white.part01.53p.zip.zip',
];
const _selectionChannel = MethodChannel('venera/select_file');

class _Library {
  _Library(this.root);

  final Directory root;
  late LocalManager manager;
  late Directory inputs;
  late Uint8List coverBytes;
  final sourceBytes = <int>[];
  final prepared = <String>[];
  final released = <String>[];
  final receipts = <String, File>{};

  ComicImportService get service => ComicImportService(
    localManager: () => manager,
    favoritesManager: () => throw StateError('No favorites are imported'),
  );

  Future<void> initialize() async {
    LocalManager(initializeSources: () async {});
    manager = LocalManager();
    await manager.init();
    inputs = Directory('${root.path}/inputs')..createSync();
    final contents = archive.Archive();
    final page = image.Image(width: 8, height: 12);
    coverBytes = image.encodePng(page);
    for (final entry in {
      'wrapped/1.png': coverBytes,
      'wrapped/2.jpg': image.encodeJpg(page),
    }.entries) {
      contents.addFile(
        archive.ArchiveFile(entry.key, entry.value.length, entry.value),
      );
    }
    sourceBytes.addAll(archive.ZipEncoder().encodeBytes(contents));
    for (final name in _names) {
      File('${inputs.path}/$name').writeAsBytesSync(sourceBytes);
    }
  }

  Future<void> import(String mode, List<String> names) async {
    if (mode == 'batch') {
      final result = await service.archives(inputs);
      expect(result.succeeded, isTrue);
      expect(result.importedCount, 2);
      expect(result.issues, isEmpty);
      return;
    }
    for (final name in names) {
      final operation = SelectionOperation();
      await operation.run((operation) async {
        final selected = await operation.pickFile(
          () async => mode == 'local'
              ? FileSelection('${inputs.path}/$name')
              : FileSelection.androidDocument(
                  uri: 'content://synthetic/${_names.indexOf(name)}',
                  name: name,
                ),
        );
        await operation.useFile(
          selected!,
          (file) => CBZ.import(file, registerComic: service.registerComic),
        );
      });
      expect(operation.hasPendingCleanup, isFalse);
    }
  }

  void mockAndroidPreparation(WidgetTester tester, {required bool temporary}) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _selectionChannel,
      (call) async {
        if (call.method == 'prepareFile') {
          final uri = call.arguments as String;
          final name = _names[int.parse(Uri.parse(uri).pathSegments.last)];
          prepared.add(name);
          if (!temporary) {
            return {'path': '${inputs.path}/$name', 'temporary': false};
          }
          final token = 'copy-${prepared.length}';
          final directory = Directory('${root.path}/selected/$token')
            ..createSync(recursive: true);
          final copy = await File(
            '${inputs.path}/$name',
          ).copy('${directory.path}/$name');
          receipts[token] = copy;
          return {'path': copy.path, 'temporary': true, 'token': token};
        }
        if (call.method == 'releaseFile') {
          final receipt = Map<String, String>.from(call.arguments as Map);
          final copy = receipts.remove(receipt['token'])!;
          expect(receipt['path'], copy.path);
          released.add(copy.path);
          await copy.delete();
          await copy.parent.delete();
          return null;
        }
        throw StateError('Unexpected selection method: ${call.method}');
      },
    );
  }

  Future<void> expectReadable() async {
    final comics = manager.getComics(LocalSortType.name);
    expect(comics, hasLength(2));
    expect(comics.map((comic) => comic.id).toSet(), hasLength(2));
    expect(comics.map((comic) => comic.directory).toSet(), hasLength(2));
    expect(
      comics.map((comic) => comic.title),
      unorderedEquals(_names.map((name) => name.substring(0, name.length - 4))),
    );
    for (final comic in comics) {
      expect(manager.findByName(comic.title)?.id, comic.id);
      final pages = await manager.getImages(comic.id, ComicType.local, 1);
      expect(pages, hasLength(2));
      for (final file in [
        comic.coverFile,
        ...pages.map((path) => File(path.replaceFirst('file://', ''))),
      ]) {
        final codec = await ui.instantiateImageCodec(await file.readAsBytes());
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 8);
        expect(frame.image.height, 12);
        frame.image.dispose();
        codec.dispose();
      }
    }
    for (final name in _names) {
      expect(File('${inputs.path}/$name').readAsBytesSync(), sourceBytes);
    }
    expect(receipts, isEmpty);
  }

  Future<void> reopen() async {
    await manager.pendingDownloadTaskWrites;
    manager.dispose();
    manager = LocalManager(initializeSources: () async {});
    await manager.init();
  }
}

Future<_Library> _prepare(WidgetTester tester) async {
  final build = Directory('build').absolute;
  final root = build.createTempSync('archive-visibility-');
  final buildPath = build.resolveSymbolicLinksSync();
  final oldData = App.dataPath;
  final oldCache = App.cachePath;
  final oldImplicit = appdata.implicitData;
  final settings = Map<String, dynamic>.from(
    appdata.toJson()['settings'] as Map,
  );
  final library = _Library(root);
  App.dataPath = root.path;
  App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
  appdata.implicitData = {};
  appdata.settings['language'] = 'en-US';
  appdata.settings['blockedWords'] = <String>[];
  appdata.settings['comicDisplayMode'] = 'detailed';
  tester.view.physicalSize = const Size(375, 812);
  tester.view.devicePixelRatio = 1;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (_) async => false,
  );
  configureComicWidgets(
    tileImageProviderResolver: (_) => MemoryImage(library.coverBytes),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    tester.binding.imageCache.clear();
    tester.binding.imageCache.clearLiveImages();
    await tester.runAsync(() async {
      await library.manager.pendingDownloadTaskWrites;
      library.manager.dispose();
    });
    configureComicWidgets();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _selectionChannel,
      null,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
    settings.forEach((key, value) => appdata.settings[key] = value);
    appdata.implicitData = oldImplicit;
    App.dataPath = oldData;
    App.cachePath = oldCache;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    expect(
      root.resolveSymbolicLinksSync(),
      startsWith('$buildPath${Platform.pathSeparator}'),
    );
    root.deleteSync(recursive: true);
  });
  await tester.runAsync(library.initialize);
  return library;
}

Future<void> _show(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  double textScale = 1,
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: appNavigation.rootNavigatorKey,
      theme: ThemeData(
        platform: TargetPlatform.android,
        brightness: brightness,
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
        ),
        child: child!,
      ),
      home: const LocalComicsPage(),
    ),
  );
  await tester.pumpAndSettle();
}

Map<Comic, bool> _selection(WidgetTester tester) =>
    tester.widget<SliverGridComics>(find.byType(SliverGridComics)).selections!;

Future<void> _selectFirst(WidgetTester tester) async {
  await tester.longPress(find.byType(ComicTile).first);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  App.dataPath = Directory.systemTemp.path;
  App.cachePath = Directory.systemTemp.path;
  for (final mode in ['local', 'android-borrowed', 'android-copy', 'batch']) {
    for (final reverse in [false, true]) {
      testWidgets(
        'same archive bytes with both names survive import, mobile UI and reopening: $mode reverse=$reverse',
        (tester) async {
          final library = await _prepare(tester);
          library.mockAndroidPreparation(
            tester,
            temporary: mode == 'android-copy',
          );
          final names = reverse ? _names.reversed.toList() : _names;
          if (mode == 'batch' && reverse) {
            for (final name in _names) {
              File('${library.inputs.path}/$name').deleteSync();
            }
            for (final name in names) {
              File(
                '${library.inputs.path}/$name',
              ).writeAsBytesSync(library.sourceBytes);
            }
          }
          await tester.runAsync(() async {
            await library.import(mode, names);
            await library.expectReadable();
          });
          await _show(tester);
          expect(find.byType(ComicTile), findsNWidgets(2));
          await _selectFirst(tester);
          await tester.tap(find.byTooltip('Select All'));
          await tester.pumpAndSettle();
          expect(_selection(tester), hasLength(2));
          expect(_selection(tester).values, everyElement(isTrue));
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            await library.reopen();
            await library.expectReadable();
          });
          await _show(tester);
          expect(find.byType(ComicTile), findsNWidgets(2));
          if (mode.startsWith('android-')) {
            expect(library.prepared, names);
            expect(library.released, hasLength(mode == 'android-copy' ? 2 : 0));
          } else {
            expect(library.prepared, isEmpty);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final action in ['Select All', 'Invert Selection']) {
    testWidgets('bulk action only selects visible archives: $action', (
      tester,
    ) async {
      final library = await _prepare(tester);
      await tester.runAsync(() => library.import('local', _names));
      appdata.settings['blockedWords'] = <String>['black'];
      await _show(tester);
      expect(find.byType(ComicTile), findsOneWidget);
      expect(find.text('Hidden by keyword filters: 1 comics'), findsOneWidget);
      await _selectFirst(tester);
      await tester.tap(find.byTooltip(action));
      await tester.pumpAndSettle();
      final selected = _selection(tester);
      expect(selected, hasLength(action == 'Select All' ? 1 : 0));
      expect(
        selected.keys.any((comic) => comic.title.contains('black')),
        isFalse,
      );
      expect(library.manager.count, 2);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('new keyword exclusions immediately remove hidden selections', (
    tester,
  ) async {
    final library = await _prepare(tester);
    await tester.runAsync(() => library.import('local', _names));
    await _show(tester);
    await _selectFirst(tester);
    await tester.tap(find.byTooltip('Select All'));
    await tester.pumpAndSettle();
    appdata.settings['blockedWords'] = <String>['black'];
    await tester.pumpAndSettle();
    expect(_selection(tester), hasLength(1));
    expect(_selection(tester).keys.single.title, 'Sample24');
    appdata.settings['blockedWords'] = <String>['Sample'];
    await tester.pumpAndSettle();
    expect(_selection(tester), isEmpty);
    expect(find.byTooltip('Select All'), findsNothing);
    expect(find.text('Local'), findsOneWidget);
    expect(library.manager.count, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'abbreviated keyword matches title text, not the content category',
    (tester) async {
      final library = await _prepare(tester);
      await tester.runAsync(() => library.import('local', _names));
      appdata.settings['blockedWords'] = <String>['bl'];
      final longTitle = library.manager
          .getComics(LocalSortType.name)
          .singleWhere((comic) => comic.title.contains('black'));
      expect(isBlocked(longTitle), 'bl');
      await _show(tester);
      expect(find.byType(ComicTile), findsOneWidget);
      expect(find.text('Hidden by keyword filters: 1 comics'), findsOneWidget);
      appdata.settings['blockedWords'] = <String>['BL'];
      await tester.pumpAndSettle();
      expect(isBlocked(longTitle), isNull);
      expect(find.byType(ComicTile), findsNWidgets(2));
      expect(library.manager.count, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('database refresh rebinds selection to the current visible row', (
    tester,
  ) async {
    final library = await _prepare(tester);
    await tester.runAsync(() => library.import('local', _names));
    await _show(tester);
    await _selectFirst(tester);
    final previous = _selection(tester).keys.single as LocalComic;
    await tester.runAsync(() => library.manager.add(previous));
    await tester.pumpAndSettle();
    final current = tester
        .widgetList<ComicTile>(find.byType(ComicTile))
        .singleWhere((tile) => tile.comic.id == previous.id)
        .comic;
    expect(identical(current, previous), isFalse);
    expect(_selection(tester)[current], isTrue);
    expect(_selection(tester), hasLength(1));
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is ComicTile && identical(widget.comic, current),
      ),
    );
    await tester.pumpAndSettle();
    expect(_selection(tester), isEmpty);
    expect(find.byTooltip('Select All'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removed rows cannot leave a phantom selected count', (
    tester,
  ) async {
    final library = await _prepare(tester);
    await tester.runAsync(() => library.import('local', _names));
    await _show(tester);
    await _selectFirst(tester);
    final selected = _selection(tester).keys.single as LocalComic;
    library.manager.remove(selected.id, selected.comicType);
    await tester.pumpAndSettle();
    expect(find.byType(ComicTile), findsOneWidget);
    expect(_selection(tester), isEmpty);
    expect(find.byTooltip('Select All'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('second live import preserves selection of the existing row', (
    tester,
  ) async {
    final library = await _prepare(tester);
    await tester.runAsync(() => library.import('local', [_names.first]));
    await _show(tester);
    await _selectFirst(tester);
    final identity = _selection(tester).keys.single.id;
    await tester.runAsync(() => library.import('local', [_names.last]));
    await tester.pumpAndSettle();
    expect(find.byType(ComicTile), findsNWidgets(2));
    final existing = tester
        .widgetList<ComicTile>(find.byType(ComicTile))
        .singleWhere((tile) => tile.comic.id == identity)
        .comic;
    expect(_selection(tester)[existing], isTrue);
    expect(_selection(tester), hasLength(1));
    await tester.tap(find.byTooltip('Select All'));
    await tester.pumpAndSettle();
    expect(_selection(tester), hasLength(2));
    await tester.runAsync(library.expectReadable);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    for (final landscape in [false, true]) {
      testWidgets(
        'visible selection and hidden notice adapt to large text and reduced motion: $brightness landscape=$landscape',
        (tester) async {
          final library = await _prepare(tester);
          await tester.runAsync(() => library.import('local', _names));
          if (landscape) tester.view.physicalSize = const Size(812, 375);
          appdata.settings['blockedWords'] = <String>['black'];
          await _show(
            tester,
            brightness: brightness,
            textScale: 2,
            reduceMotion: true,
          );
          expect(
            find.text('Hidden by keyword filters: 1 comics'),
            findsOneWidget,
          );
          await _selectFirst(tester);
          await tester.tap(find.byTooltip('Select All'));
          await tester.pumpAndSettle();
          expect(_selection(tester), hasLength(1));
          expect(find.text('1'), findsOneWidget);
          appdata.settings['blockedWords'] = <String>[];
          await tester.pumpAndSettle();
          expect(find.byType(ComicTile), findsNWidgets(2));
          expect(_selection(tester), hasLength(1));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('stale bulk menus cannot act on a newly hidden selection', (
    tester,
  ) async {
    final library = await _prepare(tester);
    await tester.runAsync(() => library.import('local', _names));
    await _show(tester);
    await _selectFirst(tester);
    final entries = tester.widget<MenuButton>(find.byType(MenuButton)).entries;
    appdata.settings['blockedWords'] = <String>['Sample'];
    await tester.pumpAndSettle();
    final barriers = find.byType(ModalBarrier).evaluate().length;
    for (final entry in entries) {
      entry.onClick();
    }
    await tester.pumpAndSettle();
    expect(find.byType(ModalBarrier), findsNWidgets(barriers));
    expect(find.byType(ContentDialog), findsNothing);
    expect(_selection(tester), isEmpty);
    await tester.runAsync(library.expectReadable);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an open delete confirmation rechecks the visible selection', (
    tester,
  ) async {
    final library = await _prepare(tester);
    await tester.runAsync(() => library.import('local', _names));
    await _show(tester);
    await _selectFirst(tester);
    tester
        .widget<MenuButton>(find.byType(MenuButton))
        .entries
        .singleWhere((entry) => entry.text == 'Delete')
        .onClick();
    await tester.pumpAndSettle();
    expect(find.text('Confirm'), findsOneWidget);
    appdata.settings['blockedWords'] = <String>['Sample'];
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm'), findsNothing);
    await tester.runAsync(library.expectReadable);
    expect(tester.takeException(), isNull);
  });
}
