import 'package:venera_next/features/local_comics/import_export/comic_import_service.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/import_export/import_comic.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/local_comics/local_storage_guard.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/file_system.dart';

void main() {
  const service = ComicImportService(
    localManager: LocalManager.new,
    favoritesManager: LocalFavoritesManager.new,
  );
  for (final copy in [false, true]) {
    testWidgets(
      'directory registration waits for exclusive storage: copy=$copy',
      (tester) async {
        final root = Directory.systemTemp.createTempSync(
          'directory-registration-',
        );
        App.dataPath = root.path;
        App.cachePath = root.path;
        LocalManager.resetForTesting();
        LocalManager.debugSkipComicSourceInit = true;
        final manager = LocalManager();
        await tester.runAsync(manager.init);
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: App.rootNavigatorKey,
            home: const Scaffold(),
          ),
        );
        try {
          await tester.runAsync(() async {
            final source = Directory('${root.path}/external')..createSync();
            File('${source.path}/1.jpg').writeAsStringSync('page');
            final comic = LocalComic(
              id: '0',
              title: 'External',
              subtitle: '',
              tags: [],
              directory: source.path,
              chapters: null,
              cover: '1.jpg',
              comicType: ComicType.local,
              downloadedChapters: [],
              createdAt: DateTime(2024),
            );
            final gate = Completer<void>();
            final exclusive = manager.runWithExclusiveStorage(
              () => gate.future,
            );
            final importing = service.runImport(
              (operation) => operation.registerComics({
                null: [comic],
              }, copy: copy),
            );
            try {
              await pumpEventQueue();
              expect(manager.findByName('External'), isNull);
              expect(
                manager.directory.listSync().whereType<Directory>(),
                isEmpty,
              );
            } finally {
              gate.complete();
              await exclusive;
            }
            expect(
              (await importing.timeout(const Duration(seconds: 10))).succeeded,
              isTrue,
            );
            expect(manager.findByName('External'), isNotNull);
            final release = await LocalComicStorageGuard.instance
                .prepareForExit();
            try {
              await expectLater(
                service.runImport(
                  (operation) => operation.registerComics({}, copy: copy),
                ),
                throwsA(isA<LocalComicStorageBusy>()),
              );
            } finally {
              release();
            }
            expect(File('${source.path}/1.jpg').readAsStringSync(), 'page');
          });
          await tester.pumpAndSettle();
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async => manager.pendingDownloadTaskWrites);
          LocalManager.resetForTesting();
          root.deleteSync(recursive: true);
        }
      },
    );
  }

  testWidgets(
    'recovery registers under its exclusive guard without self-waiting',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('directory-recovery-');
      App.dataPath = root.path;
      App.cachePath = root.path;
      LocalManager.resetForTesting();
      LocalManager.debugSkipComicSourceInit = true;
      final manager = LocalManager();
      await tester.runAsync(manager.init);
      await tester.pumpWidget(
        MaterialApp(navigatorKey: App.rootNavigatorKey, home: const Scaffold()),
      );
      try {
        final source = Directory('${manager.path}/Recovered')..createSync();
        File('${source.path}/1.jpg').writeAsStringSync('page');
        final result = await tester.runAsync(
          () => const ImportComic().localDownloads().timeout(
            const Duration(seconds: 10),
          ),
        );
        expect(result, isTrue);
        expect(manager.findByName('Recovered'), isNotNull);
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => manager.runWithExclusiveStorage(() async {}),
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async => manager.pendingDownloadTaskWrites);
        LocalManager.resetForTesting();
        root.deleteSync(recursive: true);
      }
    },
  );
}
