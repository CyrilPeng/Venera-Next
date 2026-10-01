import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/local_storage_migration.dart';
import 'package:venera_next/foundation/file_system.dart';

void main() {
  late Directory root;
  late Directory source;
  late Directory destination;
  late File pathFile;
  late String published;
  late List<Object> cleanupErrors;
  setUp(() {
    root = Directory.systemTemp.createTempSync('local-migration-');
    source = Directory('${root.path}/source')..createSync();
    destination = Directory('${root.path}/destination')..createSync();
    File('${source.path}/page.jpg').writeAsBytesSync([1, 2, 3]);
    pathFile = File('${root.path}/local_path')..writeAsStringSync(source.path);
    published = source.path;
    cleanupErrors = [];
  });
  tearDown(() => root.deleteSync(recursive: true));

  LocalStorageMigration service({
    Future<void> Function(Directory, Directory)? copy,
    Future<void> Function(Directory)? clear,
    Future<String> Function(Directory)? canonical,
  }) => LocalStorageMigration(
    copyContents: copy ?? copyDirectory,
    publishPath: (value) => published = value,
    reportCleanupError: (error, stack) => cleanupErrors.add(error),
    clearContents: clear,
    canonicalPath: canonical,
  );

  test(
    'commits persisted and in-memory path before clearing the old directory',
    () async {
      final migration = service(
        clear: (old) async {
          expect(published, destination.path);
          expect(pathFile.readAsStringSync(), destination.path);
          expect(File('${destination.path}/page.jpg').readAsBytesSync(), [
            1,
            2,
            3,
          ]);
          await old.deleteContents();
        },
      );
      expect(
        await migration.migrate(
          source: source,
          destination: destination,
          pathFile: pathFile,
        ),
        isNull,
      );
      expect(source.listSync(), isEmpty);
      expect(cleanupErrors, isEmpty);
      expect(
        root.listSync().where((entry) => entry.path.contains('.local-path-')),
        isEmpty,
      );
    },
  );

  test(
    'copy failure keeps the old path and source and preserves partial output',
    () async {
      final error = StateError('copy failed');
      final migration = service(
        copy: (old, target) async {
          File('${target.path}/partial').writeAsStringSync('partial');
          throw error;
        },
      );
      await expectLater(
        migration.migrate(
          source: source,
          destination: destination,
          pathFile: pathFile,
        ),
        throwsA(same(error)),
      );
      expect(pathFile.readAsStringSync(), source.path);
      expect(published, source.path);
      expect(File('${source.path}/page.jpg').readAsBytesSync(), [1, 2, 3]);
      expect(File('${destination.path}/partial').existsSync(), isTrue);
    },
  );

  test(
    'path publication failure preserves source and does not publish in memory',
    () async {
      pathFile.deleteSync();
      Directory(pathFile.path).createSync();
      await expectLater(
        service().migrate(
          source: source,
          destination: destination,
          pathFile: pathFile,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(published, source.path);
      expect(File('${source.path}/page.jpg').readAsBytesSync(), [1, 2, 3]);
      expect(File('${destination.path}/page.jpg').readAsBytesSync(), [1, 2, 3]);
      expect(
        root.listSync().where((entry) => entry.path.contains('.local-path-')),
        isEmpty,
      );
    },
  );

  test(
    'source cleanup failure retains the committed destination as authoritative',
    () async {
      final error = StateError('cannot clear source');
      final migration = service(clear: (_) async => throw error);
      expect(
        await migration.migrate(
          source: source,
          destination: destination,
          pathFile: pathFile,
        ),
        isNull,
      );
      expect(pathFile.readAsStringSync(), destination.path);
      expect(published, destination.path);
      expect(File('${source.path}/page.jpg').existsSync(), isTrue);
      expect(File('${destination.path}/page.jpg').readAsBytesSync(), [1, 2, 3]);
      expect(cleanupErrors, [error]);
    },
  );

  test(
    'rejects overlapping, canonical aliases, nonempty and missing destinations before copying',
    () async {
      var copies = 0;
      final migration = service(copy: (old, target) async => copies++);
      final child = Directory('${source.path}/nested')..createSync();
      for (final target in [source, child, root]) {
        expect(
          await migration.migrate(
            source: source,
            destination: target,
            pathFile: pathFile,
          ),
          isNotNull,
        );
      }
      final alias = service(
        copy: (old, target) async => copies++,
        canonical: (_) async => source.path,
      );
      expect(
        await alias.migrate(
          source: source,
          destination: destination,
          pathFile: pathFile,
        ),
        isNotNull,
      );
      File('${destination.path}/keep').writeAsStringSync('keep');
      expect(
        await migration.migrate(
          source: source,
          destination: destination,
          pathFile: pathFile,
        ),
        'Directory is not empty',
      );
      expect(
        await migration.migrate(
          source: source,
          destination: Directory('${root.path}/missing'),
          pathFile: pathFile,
        ),
        'Directory does not exist',
      );
      expect(copies, 0);
      expect(pathFile.readAsStringSync(), source.path);
    },
  );
}
