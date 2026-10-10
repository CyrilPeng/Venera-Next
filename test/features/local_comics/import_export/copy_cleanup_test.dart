import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/local_comics/import_export/comic_copy_metadata.dart';
import 'package:venera_next/features/local_comics/import_export/comic_copy_record.dart';
import 'package:venera_next/features/local_comics/import_export/comic_directory_copy.dart';
import 'package:venera_next/features/local_comics/import_export/comic_import_service.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/file_system.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalManager local;
  const service = ComicImportService(
    localManager: LocalManager.new,
    favoritesManager: LocalFavoritesManager.new,
  );
  setUp(() async {
    root = Directory.systemTemp.createTempSync('copy-cleanup-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    LocalManager.current?.dispose();
    LocalManager(initializeSources: () async {});
    local = LocalManager();
    await local.init();
  });
  tearDown(() async {
    await local.pendingDownloadTaskWrites;
    LocalManager.current?.dispose();
    root.deleteSync(recursive: true);
  });

  Future<({ComicCopyRecord record, LocalComic comic})> copied() async {
    final source = Directory('${root.path}/source')..createSync();
    File('${source.path}/1.jpg').writeAsStringSync('original page');
    final original = LocalComic(
      id: '0',
      title: 'Saved title',
      subtitle: 'Author',
      tags: ['tag'],
      directory: source.path,
      chapters: null,
      cover: '1.jpg',
      comicType: ComicType.local,
      downloadedChapters: [],
      createdAt: DateTime(2024, 1, 2, 3, 4, 5, 6, 7),
    );
    final metadata = encodeComicCopyMetadata(original, null);
    final result = await copyComicDirectories(
      ComicDirectoryCopyRequest(
        directories: [source.path],
        destination: local.path,
        metadata: {source.path: metadata},
      ),
    );
    expect(result.failures, isEmpty);
    final directory = result.copies[source.path]!;
    return (
      record: ComicCopyRecord.read(Directory(directory)),
      comic: decodeComicCopyMetadata(metadata, directory).comic,
    );
  }

  Future<ComicImportResult> scan() => service.runRecovery(
    (operation) => operation.localDownloads(isCancelled: () => false),
  );

  LocalComic row(LocalComic comic, {String? id, String? directory}) =>
      LocalComic(
        id: id ?? comic.id,
        title: comic.title,
        subtitle: comic.subtitle,
        tags: comic.tags,
        directory: directory ?? comic.directory,
        chapters: comic.chapters,
        cover: comic.cover,
        comicType: comic.comicType,
        downloadedChapters: comic.downloadedChapters,
        createdAt: comic.createdAt,
      );

  Future<T> intercept<T>(
    String filename,
    Future<T> Function() action, {
    void Function(File)? write,
    void Function(File)? delete,
  }) {
    final parent = Zone.current;
    return IOOverrides.runZoned(
      action,
      // Intercept only the selected file operation; keep native type/alias
      // checks in the original zone instead of IOOverrides' default adapter.
      fseGetType: (name, followLinks) => parent.run(
        () => FileSystemEntity.type(name, followLinks: followLinks),
      ),
      fseGetTypeSync: (name, followLinks) => parent.run(
        () => FileSystemEntity.typeSync(name, followLinks: followLinks),
      ),
      createFile: (name) {
        final file = parent.run(() => File(name));
        return path.equals(filename, name)
            ? _ControlledFile(file, write: write, delete: delete)
            : file;
      },
    );
  }

  test('registered completed copy retires only its control files', () async {
    final copy = await copied();
    await service.registerComic(copy.comic);
    final result = await scan();
    expect(result.importedCount, 0);
    expect(ComicCopyRecord.exists(copy.record.directory), isFalse);
    expect(local.count, 1);
    expect(
      File('${copy.record.directory.path}/1.jpg').readAsStringSync(),
      'original page',
    );
  });

  test(
    'registered path with changed metadata retains recovery evidence',
    () async {
      final copy = await copied();
      copy.comic.tags.add('different registration');
      await service.registerComic(copy.comic);
      final result = await scan();
      expect(
        result.issues.any(
          (issue) => issue.kind == ComicImportIssueKind.copyRecoveryRequired,
        ),
        isTrue,
      );
      expect(ComicCopyRecord.exists(copy.record.directory), isTrue);
      expect(local.count, 1);
    },
  );

  test(
    'legacy intent without completion cannot be acknowledged by path alone',
    () async {
      final copy = await copied();
      await service.registerComic(copy.comic);
      File(
        '${copy.record.directory.path}/${ComicCopyRecord.completionName}',
      ).deleteSync();
      final result = await scan();
      expect(
        result.issues.any(
          (issue) => issue.kind == ComicImportIssueKind.copyRecoveryRequired,
        ),
        isTrue,
      );
      expect(ComicCopyRecord.exists(copy.record.directory), isTrue);
      expect(local.count, 1);
    },
  );

  for (final relative in [false, true]) {
    test(
      'cleanup resolves exact registration beyond recent rows; relative=$relative',
      () async {
        final copy = await copied();
        await local.add(
          row(
            copy.comic,
            id: '50',
            directory: relative
                ? path.basename(copy.record.directory.path)
                : copy.comic.directory,
          ),
        );
        // Recovery must not depend on getRecent's twenty-row limit.
        for (var i = 0; i < 25; i++) {
          await local.add(
            row(
              copy.comic,
              id: '${100 + i}',
              directory: '${root.path}/unrelated-$i',
            ),
          );
        }
        final result = await scan();
        expect(
          result.issues.where(
            (issue) => issue.kind == ComicImportIssueKind.copyRecoveryRequired,
          ),
          isEmpty,
        );
        expect(ComicCopyRecord.exists(copy.record.directory), isFalse);
        expect(local.count, 26);
      },
    );
  }

  for (final stage in [
    'receipt acknowledgement',
    'completion delete',
    'intent delete',
    'receipt delete',
  ]) {
    test(
      'cleanup retries after $stage failure without registering again',
      () async {
        final copy = await copied();
        await service.registerComic(copy.comic);
        final marker = switch (stage) {
          'completion delete' => ComicCopyRecord.completionName,
          'intent delete' => ComicCopyRecord.intentName,
          _ => ComicCopyRecord.registrationName,
        };
        final error = FileSystemException('injected $stage failure');
        final stack = StackTrace.fromString('original cleanup failure stack');
        final failed = await intercept(
          '${copy.record.directory.path}/$marker',
          scan,
          write: stage == 'receipt acknowledgement'
              ? (file) {
                  Error.throwWithStackTrace(error, stack);
                }
              : null,
          delete: stage == 'receipt acknowledgement'
              ? null
              : (file) {
                  Error.throwWithStackTrace(error, stack);
                },
        );
        final issue = failed.issues.singleWhere(
          (issue) => issue.kind == ComicImportIssueKind.copyRecoveryRequired,
        );
        expect(issue.error, same(error));
        expect(issue.stackTrace.toString(), stack.toString());
        expect(ComicCopyRecord.exists(copy.record.directory), isTrue);
        expect(
          File(
            '${copy.record.directory.path}/${ComicCopyRecord.registrationName}',
          ).existsSync(),
          isTrue,
        );
        if (stage == 'receipt delete') {
          expect(
            File(
              '${copy.record.directory.path}/${ComicCopyRecord.intentName}',
            ).existsSync(),
            isFalse,
          );
          expect(
            File(
              '${copy.record.directory.path}/${ComicCopyRecord.completionName}',
            ).existsSync(),
            isFalse,
          );
        }
        final retried = await scan();
        expect(retried.importedCount, 0);
        expect(
          retried.issues.where(
            (issue) => issue.kind == ComicImportIssueKind.copyRecoveryRequired,
          ),
          isEmpty,
        );
        expect(ComicCopyRecord.exists(copy.record.directory), isFalse);
        expect(local.count, 1);
        expect(
          File('${copy.record.directory.path}/1.jpg').readAsStringSync(),
          'original page',
        );
      },
    );
  }

  test(
    'a receipt for a replaced registration cannot clean the new row',
    () async {
      final copy = await copied();
      await service.registerComic(copy.comic);
      await intercept(
        '${copy.record.directory.path}/${ComicCopyRecord.completionName}',
        scan,
        delete: (_) => throw const FileSystemException('retain receipt'),
      );
      local.remove('1', ComicType.local);
      await local.add(row(copy.comic, id: '2'));
      final result = await scan();
      expect(
        result.issues.any(
          (issue) =>
              issue.error.toString().contains('registration has changed'),
        ),
        isTrue,
      );
      expect(ComicCopyRecord.exists(copy.record.directory), isTrue);
      expect(local.find('2', ComicType.local), isNotNull);
    },
  );

  test(
    'shared directory ownership cannot retire another import intent',
    () async {
      final copy = await copied();
      await local.add(row(copy.comic, id: '1'));
      await local.add(row(copy.comic, id: '2'));
      final result = await scan();
      expect(
        result.issues.any(
          (issue) =>
              issue.error.toString().contains('one exact local registration'),
        ),
        isTrue,
      );
      expect(ComicCopyRecord.exists(copy.record.directory), isTrue);
      expect(local.count, 2);
    },
  );

  test(
    'changed payload cannot acquire a cleanup receipt from an old row',
    () async {
      final copy = await copied();
      await service.registerComic(copy.comic);
      File(
        '${copy.record.directory.path}/1.jpg',
      ).writeAsStringSync('changed page');
      final result = await scan();
      expect(
        result.issues.any(
          (issue) => issue.kind == ComicImportIssueKind.copyRecoveryRequired,
        ),
        isTrue,
      );
      expect(
        File(
          '${copy.record.directory.path}/${ComicCopyRecord.registrationName}',
        ).existsSync(),
        isFalse,
      );
      expect(ComicCopyRecord.exists(copy.record.directory), isTrue);
    },
  );

  test('same title at another directory does not authorize cleanup', () async {
    final copy = await copied();
    await local.add(
      row(copy.comic, id: '1', directory: '${root.path}/another'),
    );
    final result = await scan();
    expect(result.importedCount, 0);
    expect(ComicCopyRecord.exists(copy.record.directory), isTrue);
    expect(local.count, 1);
  });

  test('a cleanup-only receipt cannot register deleted local data', () async {
    final copy = await copied();
    await service.registerComic(copy.comic);
    await intercept(
      '${copy.record.directory.path}/${ComicCopyRecord.registrationName}',
      scan,
      delete: (_) => throw const FileSystemException('retain receipt'),
    );
    local.remove('1', ComicType.local);
    final result = await scan();
    expect(result.importedCount, 0);
    expect(local.count, 0);
    expect(ComicCopyRecord.exists(copy.record.directory), isTrue);
    expect(
      result.issues.any(
        (issue) => issue.kind == ComicImportIssueKind.copyRecoveryRequired,
      ),
      isTrue,
    );
  });

  test(
    'receipt with both originals cannot replay a deleted registration',
    () async {
      final copy = await copied();
      await service.registerComic(copy.comic);
      await intercept(
        '${copy.record.directory.path}/${ComicCopyRecord.completionName}',
        scan,
        delete: (_) => throw const FileSystemException('retain originals'),
      );
      local.remove('1', ComicType.local);
      final result = await scan();
      expect(result.importedCount, 0);
      expect(local.count, 0);
      expect(
        result.issues.any(
          (issue) =>
              issue.error.toString().contains('cannot authorize registration'),
        ),
        isTrue,
      );
      expect(ComicCopyRecord.exists(copy.record.directory), isTrue);
    },
  );

  for (final corruption in ['truncated', 'unknown version', 'changed intent']) {
    test('$corruption receipt preserves all original files', () async {
      final copy = await copied();
      await service.registerComic(copy.comic);
      await intercept(
        '${copy.record.directory.path}/${ComicCopyRecord.completionName}',
        scan,
        delete: (_) => throw const FileSystemException('retain originals'),
      );
      final receipt = File(
        '${copy.record.directory.path}/${ComicCopyRecord.registrationName}',
      );
      final value =
          jsonDecode(receipt.readAsStringSync()) as Map<String, dynamic>;
      if (corruption == 'unknown version') value['version'] = 999;
      if (corruption == 'changed intent') {
        final intent =
            jsonDecode(value['intent'] as String) as Map<String, dynamic>;
        intent['source'] = 'replacement source';
        value['intent'] = jsonEncode(intent);
      }
      receipt.writeAsStringSync(
        corruption == 'truncated' ? '{' : jsonEncode(value),
      );
      final result = await scan();
      expect(
        result.issues.any(
          (issue) => issue.kind == ComicImportIssueKind.copyRecoveryRequired,
        ),
        isTrue,
      );
      for (final name in [
        ComicCopyRecord.intentName,
        ComicCopyRecord.completionName,
        ComicCopyRecord.registrationName,
      ]) {
        expect(
          File('${copy.record.directory.path}/$name').existsSync(),
          isTrue,
        );
      }
      expect(local.count, 1);
      expect(
        File('${copy.record.directory.path}/1.jpg').readAsStringSync(),
        'original page',
      );
    });
  }

  for (final alias in [false, true]) {
    test(
      'retained overlapping ownership blocks cleanup; nativeAlias=$alias',
      () async {
        final copy = await copied();
        await service.registerComic(copy.comic);
        final aliasPath = '${root.path}/retained-alias';
        var aliasCreated = false;
        try {
          if (alias) {
            if (Platform.isWindows) {
              final result = await Process.run('cmd', [
                '/c',
                'mklink',
                '/J',
                aliasPath.replaceAll('/', '\\'),
                copy.record.directory.path.replaceAll('/', '\\'),
              ]);
              expect(
                result.exitCode,
                0,
                reason: '${result.stdout}\n${result.stderr}',
              );
            } else {
              Link(aliasPath).createSync(copy.record.directory.path);
            }
            aliasCreated = true;
          }
          await local.add(
            row(copy.comic, id: '2', directory: alias ? aliasPath : root.path),
          );
          final result = await scan();
          expect(
            result.issues.any(
              (issue) => issue.error.toString().contains(
                'also owned by another record',
              ),
            ),
            isTrue,
          );
          expect(ComicCopyRecord.exists(copy.record.directory), isTrue);
          expect(local.count, 2);
          expect(
            File('${copy.record.directory.path}/1.jpg').readAsStringSync(),
            'original page',
          );
        } finally {
          if (aliasCreated) {
            if (Platform.isWindows) {
              Directory(aliasPath).deleteSync();
            } else {
              Link(aliasPath).deleteSync();
            }
          }
        }
      },
    );
  }
}

class _ControlledFile extends Fake implements File {
  _ControlledFile(this.actual, {this.write, void Function(File)? delete})
    : beforeDelete = delete;
  final File actual;
  final void Function(File)? write;
  final void Function(File)? beforeDelete;
  @override
  String get path => actual.path;
  @override
  bool existsSync() => actual.existsSync();
  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      actual.readAsStringSync(encoding: encoding);
  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    actual.writeAsStringSync(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
    write?.call(actual);
  }

  @override
  void deleteSync({bool recursive = false}) {
    beforeDelete?.call(actual);
    actual.deleteSync(recursive: recursive);
  }
}
