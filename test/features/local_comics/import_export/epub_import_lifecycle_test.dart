import 'package:venera_next/foundation/persistence_failure.dart';
import 'dart:async';
import 'dart:convert';
import 'package:archive/archive_io.dart' as archive;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/import_export/epub_import.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/local_comics/local_storage_guard.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/file_system.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalManager manager;
  late File epub;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('epub-lifecycle-');
    App.dataPath = root.path;
    App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
    LocalManager.resetForTesting();
    LocalManager.debugSkipComicSourceInit = true;
    manager = LocalManager();
    await manager.init();
    final contents = archive.Archive();
    final entries = {
      'META-INF/container.xml':
          '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
      'book.opf':
          '<package><metadata><title>Lifecycle</title></metadata><manifest><item id="page" href="page.jpg" media-type="image/jpeg"/></manifest><spine><itemref idref="page"/></spine></package>',
      'page.jpg': 'synthetic page',
    };
    for (final entry in entries.entries) {
      final bytes = utf8.encode(entry.value);
      contents.addFile(archive.ArchiveFile(entry.key, bytes.length, bytes));
    }
    epub = File('${root.path}/book.epub')
      ..writeAsBytesSync(archive.ZipEncoder().encodeBytes(contents));
  });
  tearDown(() async {
    await manager.pendingDownloadTaskWrites;
    LocalManager.resetForTesting();
    root.deleteSync(recursive: true);
  });

  test(
    'EPUB waits for storage and protects output through registration',
    () async {
      final migrationGate = Completer<void>();
      final registerGate = Completer<void>();
      final registering = Completer<LocalComic>();
      final exclusive = manager.runWithExclusiveStorage(
        () => migrationGate.future,
      );
      final importing = EpubComicImporter.import(
        epub,
        registerComic: (comic) async {
          registering.complete(comic);
          await registerGate.future;
          await manager.add(comic, comic.id);
        },
      );
      addTearDown(() async {
        if (!migrationGate.isCompleted) migrationGate.complete();
        if (!registerGate.isCompleted) registerGate.complete();
        await exclusive;
        await importing;
      });
      await pumpEventQueue();
      expect(Directory(App.cachePath).listSync(), isEmpty);
      expect(registering.isCompleted, isFalse);
      migrationGate.complete();
      await exclusive;
      final comic = await registering.future;
      final output = Directory('${manager.path}/${comic.directory}');
      expect(output.listSync().whereType<File>(), hasLength(2));
      await expectLater(
        manager.runWithExclusiveStorage(() async {}),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      expect(manager.findByName('Lifecycle'), isNull);
      registerGate.complete();
      await importing;
      expect(manager.findByName('Lifecycle'), isNotNull);
      expect(Directory(App.cachePath).listSync(), isEmpty);
      await manager.runWithExclusiveStorage(() async {});
    },
  );

  test('EPUB registration failure removes output and permits retry', () async {
    final error = PersistenceFailure(
      commitState: PersistenceCommitState.notCommitted,
      cause: StateError('registration failed'),
      stackTrace: StackTrace.current,
    );
    await expectLater(
      EpubComicImporter.import(epub, registerComic: (_) async => throw error),
      throwsA(same(error)),
    );
    expect(manager.directory.listSync().whereType<Directory>(), isEmpty);
    expect(manager.findByName('Lifecycle'), isNull);
    expect(Directory(App.cachePath).listSync(), isEmpty);
    await manager.runWithExclusiveStorage(() async {});
    final comic = await EpubComicImporter.import(
      epub,
      registerComic: (comic) => manager.add(comic, comic.id),
    );
    expect(manager.findByName(comic.title), isNotNull);
  });
}
