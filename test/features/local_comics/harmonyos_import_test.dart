import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart' as archive;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/local_comics/import_export/comic_import_service.dart';
import 'package:venera_next/features/local_comics/import_export/import_comic.dart';
import 'package:venera_next/features/local_comics/import_export/import_presentation.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/local_comics/local_comics_summary.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/harmonyos.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/routing/app_navigation.dart';

class _Messages extends ImportComicPresentation {
  final messages = <String>[];
  final results = <({int imported, List<String> details})>[];
  @override
  void showMessage({required String message}) => messages.add(message);
  @override
  Future<void> showResult({
    required int imported,
    required List<String> details,
  }) async {
    results.add((imported: imported, details: details));
  }
}

class _BrokenPresentation extends ImportComicPresentation {
  @override
  Future<void> showResult({
    required int imported,
    required List<String> details,
  }) async {
    throw StateError('synthetic presentation failure');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const token = '12345678-1234-4234-8234-123456789abc';
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j9ZkAAAAASUVORK5CYII=',
  );
  late Directory root;
  late LocalManager manager;
  late LocalFavoritesManager favorites;
  late ComicImportService service;
  final calls = <MethodCall>[];
  Object? oldLanguage;

  setUpAll(() async {
    for (final entry in {
      'HarmonyImportPreview':
          Platform.environment['HARMONYOS_IMPORT_TEST_FONT'],
      'Ahem': Platform.environment['HARMONYOS_IMPORT_TEST_FONT'],
      'MaterialIcons': Platform.environment['HARMONYOS_IMPORT_TEST_ICONS'],
    }.entries) {
      if (entry.value == null) continue;
      await (FontLoader(entry.key)..addFont(
            File(
              entry.value!,
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          ))
          .load();
    }
  });

  setUp(() async {
    root = Directory.systemTemp.createTempSync('harmonyos-import-');
    App.dataPath = root.path;
    App.cachePath = p.join(root.path, 'cache');
    Directory(App.cachePath).createSync();
    HarmonyOS.debugIsCurrent = true;
    calls.clear();
    oldLanguage = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
    await AppTranslation.init();
    LocalManager.current?.dispose();
    manager = LocalManager(initializeSources: () async {});
    await manager.init();
    favorites = LocalFavoritesManager();
    await favorites.init();
    service = ComicImportService(
      localManager: () => manager,
      favoritesManager: () => favorites,
    );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(HarmonyOS.channel, null);
    await manager.pendingDownloadTaskWrites;
    manager.dispose();
    await favorites.debugWaitForHashedIdsRefresh();
    await appdata.saveData(false);
    favorites.close();
    HarmonyOS.debugIsCurrent = null;
    appdata.settings['language'] = oldLanguage;
    root.deleteSync(recursive: true);
  });

  void mock(Future<Object?> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(HarmonyOS.channel, (call) async {
          calls.add(call);
          return handler(call);
        });
  }

  Future<void> capturePreview(
    WidgetTester tester,
    GlobalKey key,
    String name,
  ) async {
    final output = Platform.environment['HARMONYOS_IMPORT_SCREENSHOT_DIR'];
    if (output == null) return;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(p.join(output, name));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  Map<String, String> selectedDirectory(Directory source) => {
    'path': p.join(
      App.cachePath,
      'selected_directories',
      token,
      'contents',
      p.basename(source.path),
    ),
    'name': p.basename(source.path),
    'token': token,
  };

  void mockDirectory(Directory source) {
    final receipt = selectedDirectory(source);
    mock((call) async {
      if (call.method == 'selectDirectory') return receipt;
      final target = Directory(receipt['path']!);
      if (call.method == 'prepareDirectory') {
        await target.create(recursive: true);
        await copyDirectory(source, target);
      }
      if (call.method == 'releaseDirectory') {
        final owner = target.parent.parent;
        expect(p.isWithin(App.cachePath, owner.path), isTrue);
        await owner.delete(recursive: true);
      }
      return null;
    });
  }

  for (final single in [true, false]) {
    test(
      'folder import forces durable app copies and survives restart; single=$single',
      () async {
        final source = Directory(
          p.join(root.path, 'original', single ? 'Book' : 'Collection'),
        )..createSync(recursive: true);
        final titles = single ? ['Book'] : ['Book A', 'Book B'];
        for (final title in titles) {
          final dir = single ? source : Directory(p.join(source.path, title))
            ..createSync();
          File(p.join(dir.path, '1.png')).writeAsBytesSync(png);
        }
        mockDirectory(source);
        final messages = _Messages();
        final operation = SelectionOperation();
        expect(
          await operation.run(
            (op) => ImportComic(
              service: service,
              copyToLocal: false,
              presentation: messages,
            ).directory(single, op),
          ),
          isTrue,
        );
        expect(operation.hasPendingCleanup, isFalse);
        expect(
          calls
              .map((call) => call.method)
              .where((method) => method != 'directoryCopyProgress'),
          ['selectDirectory', 'prepareDirectory', 'releaseDirectory'],
        );
        expect(
          Directory(selectedDirectory(source)['path']!).existsSync(),
          isFalse,
        );
        expect(messages.results.single.imported, titles.length);
        expect(messages.results.single.details, isEmpty);
        for (final title in titles) {
          final comic = manager.findByName(title)!;
          expect(p.isWithin(manager.path, comic.baseDir), isTrue);
          expect(File(p.join(comic.baseDir, '1.png')).readAsBytesSync(), png);
        }
        await manager.pendingDownloadTaskWrites;
        manager.dispose();
        manager = LocalManager(initializeSources: () async {});
        await manager.init();
        expect(manager.count, titles.length);
        for (final title in titles) {
          final comic = manager.findByName(title)!;
          final pages = await manager.getImages(comic.id, ComicType.local, 0);
          expect(pages, hasLength(1));
          expect(
            File(pages.single.replaceFirst('file://', '')).readAsBytesSync(),
            png,
          );
          expect(
            File(
              p.join(
                single ? source.path : p.join(source.path, title),
                '1.png',
              ),
            ).readAsBytesSync(),
            png,
          );
        }
      },
    );
  }

  test(
    'cancelled folder selection releases a late receipt without copying',
    () async {
      final response = Completer<Object?>();
      final entered = Completer<void>();
      final source = Directory(p.join(root.path, 'Book'))..createSync();
      mock((call) async {
        if (call.method == 'selectDirectory') {
          entered.complete();
          return response.future;
        }
        return null;
      });
      final operation = SelectionOperation();
      final importing = operation.run(
        (op) => ImportComic(service: service).directory(true, op),
      );
      final rejected = expectLater(
        importing,
        throwsA(isA<SelectionCancelled>()),
      );
      await entered.future;
      operation.cancel();
      response.complete(selectedDirectory(source));
      await rejected;
      expect(calls.map((call) => call.method), [
        'selectDirectory',
        'releaseDirectory',
      ]);
      expect(manager.count, 0);
    },
  );

  for (final broken in [false, true]) {
    test(
      'archive multi-select uses files, keeps partial results and releases all; broken=$broken',
      () async {
        final archiveContents = archive.Archive()
          ..addFile(archive.ArchiveFile('1.png', png.length, png));
        final zip = archive.ZipEncoder().encodeBytes(archiveContents);
        final names = broken
            ? ['First.cbz', 'Broken.zip', 'Second.zip']
            : ['First.cbz', 'Second.zip'];
        final receipts = <Map<String, String>>[];
        final released = <String>[];
        mock((call) async {
          if (call.method == 'selectFiles') {
            expect((call.arguments as Map)['multiple'], isTrue);
            for (var i = 0; i < names.length; i++) {
              final id = token.replaceFirst('12345678', '1234567$i');
              final file = File(
                p.join(App.cachePath, 'selected_files', id, names[i]),
              )..createSync(recursive: true);
              file.writeAsBytesSync(names[i] == 'Broken.zip' ? [1, 2, 3] : zip);
              receipts.add({'path': file.path, 'name': names[i], 'token': id});
            }
            return receipts;
          }
          if (call.method == 'releaseFile') {
            final actual = call.arguments as Map;
            released.add(actual['token'] as String);
            await File(actual['path'] as String).parent.delete(recursive: true);
          }
          return null;
        });
        final messages = _Messages();
        final operation = SelectionOperation();
        expect(
          await operation.run(
            (op) => ImportComic(
              service: service,
              presentation: messages,
            ).multipleCbz(op),
          ),
          isTrue,
        );
        expect(manager.count, 2);
        expect(manager.findByName('First'), isNotNull);
        expect(manager.findByName('Second'), isNotNull);
        expect(released.toSet(), receipts.map((r) => r['token']).toSet());
        expect(
          calls.where((call) => call.method == 'selectDirectory'),
          isEmpty,
        );
        expect(operation.hasPendingCleanup, isFalse);
        if (broken) {
          expect(
            messages.messages.any((message) => message.contains('Broken.zip')),
            isTrue,
          );
          expect(messages.messages, contains('Success: 2, Failed: 1'));
        }
      },
    );
  }

  test(
    'empty or entirely invalid archive selections never report success',
    () async {
      mock((_) async => []);
      expect(
        await SelectionOperation().run(
          (op) => ImportComic(service: service).multipleCbz(op),
        ),
        isFalse,
      );
      expect(manager.count, 0);
      final file = File(
        p.join(App.cachePath, 'selected_files', token, 'Broken.cbz'),
      )..createSync(recursive: true);
      file.writeAsStringSync('invalid');
      mock((call) async {
        if (call.method == 'selectFiles') {
          return [
            {'path': file.path, 'name': 'Broken.cbz', 'token': token},
          ];
        }
        if (call.method == 'releaseFile') {
          await file.parent.delete(recursive: true);
        }
        return null;
      });
      expect(
        await SelectionOperation().run(
          (op) => ImportComic(service: service).multipleCbz(op),
        ),
        isFalse,
      );
      expect(manager.count, 0);
      expect(file.existsSync(), isFalse);
    },
  );

  for (final mixed in [false, true]) {
    test(
      'folder result explains every rejected child and never claims zero success; mixed=$mixed',
      () async {
        final source = Directory(p.join(root.path, 'Collection'))..createSync();
        Directory(p.join(source.path, 'Empty book')).createSync();
        final deep = File(
          p.join(source.path, 'Too deep', 'Chapter', 'More', '1.png'),
        )..createSync(recursive: true);
        deep.writeAsBytesSync(png);
        if (mixed) {
          File(p.join(source.path, 'Good book', '1.png'))
            ..createSync(recursive: true)
            ..writeAsBytesSync(png);
        }
        mockDirectory(source);
        final messages = _Messages();
        final operation = SelectionOperation();
        expect(
          await operation.run(
            (op) => ImportComic(
              service: service,
              presentation: messages,
            ).directory(false, op),
          ),
          mixed,
        );
        expect(manager.count, mixed ? 1 : 0);
        expect(messages.results.single.imported, mixed ? 1 : 0);
        expect(
          messages.results.single.details,
          contains('Skipped Empty book: No supported images found'),
        );
        expect(
          messages.results.single.details,
          contains(
            'Skipped Too deep: Expected images or chapter folders, but found additional directory levels',
          ),
        );
        if (!mixed) {
          expect(
            messages.results.single.details,
            contains('No valid comics found'),
          );
        }
        expect(operation.hasPendingCleanup, isFalse);
        expect(deep.existsSync(), isTrue);
      },
    );
  }

  test(
    'reimported folders report duplicates without losing the existing comic',
    () async {
      final source = Directory(p.join(root.path, 'Collection'))..createSync();
      File(p.join(source.path, 'Book', '1.png'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(png);
      mockDirectory(source);
      final messages = _Messages();
      final importer = ImportComic(service: service, presentation: messages);
      expect(
        await SelectionOperation().run((op) => importer.directory(false, op)),
        isTrue,
      );
      expect(
        await SelectionOperation().run((op) => importer.directory(false, op)),
        isFalse,
      );
      expect(messages.results.last.imported, 0);
      expect(
        messages.results.last.details,
        contains('Skipped Book: A comic with this title already exists'),
      );
      expect(manager.count, 1);
    },
  );

  test(
    'native preparation failures retain their phase/code in a persistent result',
    () async {
      final source = Directory(p.join(root.path, 'Book'))..createSync();
      mock((call) async {
        if (call.method == 'selectDirectory') return selectedDirectory(source);
        if (call.method == 'prepareDirectory') {
          throw PlatformException(
            code: 'harmonyos_operation_failed',
            message: 'prepareDirectory (13900011): no space',
          );
        }
        return null;
      });
      final messages = _Messages();
      final operation = SelectionOperation();
      expect(
        await operation.run(
          (op) => ImportComic(
            service: service,
            presentation: messages,
          ).directory(true, op),
        ),
        isFalse,
      );
      expect(messages.results.single.imported, 0);
      expect(
        messages.results.single.details.single,
        contains('prepareDirectory (13900011)'),
      );
      expect(
        calls.where((call) => call.method == 'releaseDirectory'),
        hasLength(1),
      );
      expect(manager.count, 0);
      expect(operation.hasPendingCleanup, isFalse);
    },
  );

  test(
    'result presentation failure cannot report a committed import as zero',
    () async {
      final source = Directory(p.join(root.path, 'Book'))..createSync();
      File(p.join(source.path, '1.png')).writeAsBytesSync(png);
      mockDirectory(source);
      expect(
        await SelectionOperation().run(
          (op) => ImportComic(
            service: service,
            presentation: _BrokenPresentation(),
          ).directory(true, op),
        ),
        isTrue,
      );
      expect(manager.count, 1);
    },
  );

  void mockCollection(List<int> zip) {
    mock((call) async {
      final file = File(
        p.join(App.cachePath, 'selected_files', token, 'Collection.zip'),
      );
      if (call.method == 'selectFiles') {
        expect((call.arguments as Map)['extensions'], ['zip']);
        expect((call.arguments as Map)['multiple'], isFalse);
        file.createSync(recursive: true);
        file.writeAsBytesSync(zip);
        return [
          {'path': file.path, 'name': 'Collection.zip', 'token': token},
        ];
      }
      if (call.method == 'releaseFile') {
        await file.parent.delete(recursive: true);
      }
      return null;
    });
  }

  test(
    'explicit collection ZIP imports separate comics with chapters and durable favorites',
    () async {
      await favorites.createFolder('Imported');
      mockCollection(
        archive.ZipEncoder().encodeBytes(
          archive.Archive()
            ..addFile(archive.ArchiveFile('Book A/1.png', png.length, png))
            ..addFile(
              archive.ArchiveFile('Book B/Chapter 1/1.png', png.length, png),
            )
            ..addFile(archive.ArchiveFile.directory('Empty/')),
        ),
      );
      final messages = _Messages();
      final operation = SelectionOperation();
      expect(
        await operation.run(
          (op) => ImportComic(
            service: service,
            presentation: messages,
            selectedFolder: 'Imported',
          ).collectionArchive(op),
        ),
        isTrue,
      );
      expect(manager.count, 2);
      expect(messages.results.single.imported, 2);
      expect(
        messages.results.single.details,
        contains('Skipped Empty: No supported images found'),
      );
      expect(manager.findByName('Book B')!.chapters!.allChapters.values, [
        'Chapter 1',
      ]);
      expect(operation.hasPendingCleanup, isFalse);
      expect(
        Directory(App.cachePath).listSync().whereType<Directory>().where(
          (d) => p.basename(d.path).startsWith('selected-directory-'),
        ),
        isEmpty,
      );
      expect(calls.where((call) => call.method == 'selectDirectory'), isEmpty);
      await manager.pendingDownloadTaskWrites;
      manager.dispose();
      manager = LocalManager(initializeSources: () async {});
      await manager.init();
      expect(manager.count, 2);
      for (final title in ['Book A', 'Book B']) {
        final comic = manager.findByName(title)!;
        final pages = await manager.getImages(
          comic.id,
          ComicType.local,
          comic.chapters == null ? 0 : 1,
        );
        expect(
          File(pages.single.replaceFirst('file://', '')).readAsBytesSync(),
          png,
        );
        expect(favorites.find(comic.id, ComicType.local), contains('Imported'));
      }
    },
  );

  for (final invalid in ['root page', 'not ZIP', 'empty']) {
    test(
      'invalid collection reports no imports and releases its owned workspaces; $invalid',
      () async {
        mockCollection(switch (invalid) {
          'not ZIP' => [1, 2, 3],
          'root page' => archive.ZipEncoder().encodeBytes(
            archive.Archive()
              ..addFile(archive.ArchiveFile('1.png', png.length, png)),
          ),
          _ => archive.ZipEncoder().encodeBytes(archive.Archive()),
        });
        final messages = _Messages();
        final operation = SelectionOperation();
        expect(
          await operation.run(
            (op) => ImportComic(
              service: service,
              presentation: messages,
            ).collectionArchive(op),
          ),
          isFalse,
        );
        expect(manager.count, 0);
        expect(messages.results.single.imported, 0);
        expect(messages.results.single.details, isNotEmpty);
        expect(operation.hasPendingCleanup, isFalse);
        expect(
          calls.where((call) => call.method == 'releaseFile'),
          hasLength(1),
        );
        expect(
          Directory(App.cachePath).listSync().whereType<Directory>().where(
            (d) => p.basename(d.path).startsWith('selected-directory-'),
          ),
          isEmpty,
        );
      },
    );
  }

  testWidgets('copy progress transitions to a persistent real import result', (
    tester,
  ) async {
    final source = Directory(p.join(root.path, 'Book'))..createSync();
    final receipt = selectedDirectory(source);
    final completeCopy = Completer<void>();
    mock((call) async {
      if (call.method == 'selectDirectory') return receipt;
      if (call.method == 'directoryCopyProgress') {
        return {'processed': 4, 'total': 10};
      }
      final target = Directory(receipt['path']!);
      if (call.method == 'prepareDirectory') {
        await completeCopy.future;
        target.createSync(recursive: true);
        File(p.join(target.path, '1.png')).writeAsBytesSync(png);
      }
      if (call.method == 'releaseDirectory') {
        target.parent.parent.deleteSync(recursive: true);
      }
      return null;
    });
    late Future<bool> result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () {
                final task = WindowSelectionTask(context);
                result = task.run(
                  (op) => ImportComic(
                    service: service,
                    presentation: ImportComicPresentation.forTask(task),
                  ).directory(true, op),
                );
              },
              child: const Text('Begin'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Begin'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Preparing selected folder'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.4,
    );
    completeCopy.complete();
    for (
      var i = 0;
      i < 100 && find.text('Imported 1 comics').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Imported 1 comics'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(manager.count, 1);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => result), isTrue);
    expect(
      calls.where((call) => call.method == 'releaseDirectory'),
      hasLength(1),
    );
    expect(find.text('Begin'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final built in [false, true]) {
    testWidgets(
      'result drains if its original navigator unmounts; built=$built',
      (tester) async {
        late VoidCallback show;
        var settled = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                show = () {
                  final task = WindowSelectionTask(context);
                  unawaited(
                    ImportComicPresentation.forTask(task)
                        .showResult(imported: 1, details: const [])
                        .then((_) => settled = true),
                  );
                };
                return const SizedBox();
              },
            ),
          ),
        );
        show();
        if (built) await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(
          settled,
          isTrue,
          reason: 'Forced disposal must release the awaiting import',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final layout in [
    (const Size(375, 812), 1.0, Brightness.light),
    (const Size(1200, 800), 1.0, Brightness.dark),
    (const Size(812, 375), 1.8, Brightness.light),
  ]) {
    testWidgets(
      'import UI describes copy/multi-select without a reference toggle; $layout',
      (tester) async {
        appdata.settings['language'] = 'zh-CN';
        tester.view.physicalSize = layout.$1;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: FavoritesScope(
              manager: favorites,
              child: MaterialApp(
                navigatorKey: appNavigation.rootNavigatorKey,
                theme: ThemeData(
                  brightness: layout.$3,
                  fontFamily:
                      Platform.environment.containsKey(
                        'HARMONYOS_IMPORT_TEST_FONT',
                      )
                      ? 'HarmonyImportPreview'
                      : null,
                ),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(layout.$2),
                    disableAnimations: true,
                  ),
                  child: child!,
                ),
                home: const Scaffold(
                  body: CustomScrollView(slivers: [LocalComicsSummary()]),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Import'.tl));
        await tester.pumpAndSettle();
        expect(find.byType(CheckboxListTile), findsNothing);
        expect(
          find.text(
            'On HarmonyOS, folders are copied into the app. Originals are not changed. You can also use Comic collection ZIP or Multiple archive files.'
                .tl,
          ),
          findsOneWidget,
        );
        final pdf = tester.widget<RadioListTile<int>>(
          find.widgetWithText(RadioListTile<int>, 'PDF comic files'.tl),
        );
        expect(pdf.enabled, isFalse);
        await tester.ensureVisible(find.text('Multiple archive files'.tl));
        await tester.tap(find.text('Multiple archive files'.tl));
        await tester.pumpAndSettle();
        expect(
          find.text('Select multiple archive files (cbz, zip, 7z, cb7).'.tl),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Comic collection ZIP'.tl));
        await tester.tap(find.text('Comic collection ZIP'.tl));
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Select a ZIP whose root contains one folder per comic. Do not include an extra outer folder. Ordinary CBZ imports are unchanged.'
                .tl,
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        final output = Platform.environment['HARMONYOS_IMPORT_SCREENSHOT_DIR'];
        if (output != null) {
          await tester.ensureVisible(
            find.text(
              'Select a ZIP whose root contains one folder per comic. Do not include an extra outer folder. Ordinary CBZ imports are unchanged.'
                  .tl,
            ),
          );
          await tester.pumpAndSettle();
          await capturePreview(
            tester,
            capture,
            'import-${layout.$1.width.toInt()}-${layout.$2}.png',
          );
        }
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'persistent result remains selectable, bounded and owned by its original page; $layout',
      (tester) async {
        appdata.settings['language'] = 'zh-CN';
        tester.view.physicalSize = layout.$1;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        late WindowSelectionTask task;
        Future<void>? showing;
        final navigatorKey = GlobalKey<NavigatorState>();
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              navigatorKey: navigatorKey,
              theme: ThemeData(
                brightness: layout.$3,
                fontFamily:
                    Platform.environment.containsKey(
                      'HARMONYOS_IMPORT_TEST_FONT',
                    )
                    ? 'HarmonyImportPreview'
                    : null,
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(layout.$2),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => FilledButton(
                    onPressed: () {
                      task = WindowSelectionTask(context);
                      showing = ImportComicPresentation.forTask(task).showResult(
                        imported: 2,
                        details: List.generate(
                          105,
                          (index) =>
                              'Skipped folder $index: No supported images found',
                        ),
                      );
                    },
                    child: const Text('Show'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Show'));
        await tester.pumpAndSettle();
        expect(find.byType(SelectableText), findsOneWidget);
        final text = tester
            .widget<SelectableText>(find.byType(SelectableText))
            .data!;
        expect(
          text,
          contains('Showing @a of @b details'.tlParams({'a': 100, 'b': 105})),
        );
        expect(text, isNot(contains('folder 100:')));
        expect(task.canPresent, isTrue);
        expect(tester.takeException(), isNull);
        final staleConfirm = tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'OK'.tl))
            .onPressed!;
        await capturePreview(
          tester,
          capture,
          'result-${layout.$1.width.toInt()}-${layout.$2}.png',
        );
        navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Other page')),
          ),
        );
        await tester.pumpAndSettle();
        staleConfirm();
        await tester.pumpAndSettle();
        expect(find.text('Other page'), findsOneWidget);
        task.cancel();
        await tester.pumpAndSettle();
        await showing;
        expect(find.byType(SelectableText), findsNothing);
        expect(find.text('Other page'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
