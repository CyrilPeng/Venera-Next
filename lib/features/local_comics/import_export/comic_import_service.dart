import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/features/favorites/favorites_api.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/sqlite_transaction.dart';

import '../local.dart';
import '../local_storage_guard.dart';
import 'comic_directory_copy.dart';
import 'comic_copy_metadata.dart';
import 'comic_copy_record.dart';
import 'cbz.dart';

void _checkCopyLocation(String directoryPath, String libraryPath) {
  final directory = Directory(directoryPath);
  final library = Directory(libraryPath);
  final actualDirectory = directory is AndroidDirectory
      ? directory.path
      : directory.resolveSymbolicLinksSync();
  final actualLibrary = library is AndroidDirectory
      ? library.path
      : library.resolveSymbolicLinksSync();
  if (!path.equals(
    actualDirectory,
    path.join(actualLibrary, path.basename(directoryPath)),
  )) {
    throw StateError('Copy recovery output is outside the original library');
  }
}

Future<String> _verifyCopyRecord(
  ({String directory, String library}) request,
) => overrideIO(() async {
  _checkCopyLocation(request.directory, request.library);
  final directory = Directory(request.directory);
  final record = ComicCopyRecord.read(directory);
  await record.verifyComplete();
  return record.intentDigest;
});

Future<({String digest, ComicCopyRecoveryKind kind})> _inspectCopyRecord(
  ({String directory, String library}) request,
) => overrideIO(() async {
  _checkCopyLocation(request.directory, request.library);
  final record = ComicCopyRecord.read(Directory(request.directory));
  final kind = record.canResume && !record.hasCompletion
      ? ComicCopyRecoveryKind.resumable
      : ComicCopyRecoveryKind.complete;
  if (kind == ComicCopyRecoveryKind.resumable) {
    await record.verifyResumable();
  } else {
    await record.verifyComplete();
  }
  _checkCopyLocation(request.directory, request.library);
  return (digest: record.intentDigest, kind: kind);
});

Future<String> _unverifiedCopyDigest(
  ({String directory, String library}) request,
) => overrideIO(() async {
  _checkCopyLocation(request.directory, request.library);
  final digest = await ComicCopyRecord.unverifiedDigest(
    Directory(request.directory),
  );
  _checkCopyLocation(request.directory, request.library);
  return digest;
});

Future<void> _resumeCopyRecord(
  ({String directory, String library, String digest}) request,
) => overrideIO(() async {
  _checkCopyLocation(request.directory, request.library);
  final record = ComicCopyRecord.read(Directory(request.directory));
  if (record.intentDigest != request.digest) {
    throw StateError('Copy intent changed after the recovery selection');
  }
  await record.resume();
  _checkCopyLocation(request.directory, request.library);
});

enum ComicImportIssueKind {
  invalidComic,
  localPathNotFound,
  noValidComics,
  scanFailed,
  copyFailed,
  registrationFailed,
  archiveFailed,
  copyRecoveryRequired,
}

class ComicImportIssue {
  const ComicImportIssue(this.kind, [this.error, this.stackTrace]);
  final ComicImportIssueKind kind;
  final Object? error;
  final StackTrace? stackTrace;
}

class PendingComicCopy {
  PendingComicCopy._(
    this._owner, {
    required this.directory,
    required this.title,
    required this.folder,
    required this.intentDigest,
    this.kind = ComicCopyRecoveryKind.complete,
  }) : _library = _owner.path;
  final LocalManager _owner;
  final String _library;
  final String directory;
  final String title;
  final String? folder;
  final String intentDigest;
  final ComicCopyRecoveryKind kind;
}

class ComicCopyRecoveryFolders {
  ComicCopyRecoveryFolders._(this._owner)
    : _generation = _owner.connectionGeneration,
      folders = List.unmodifiable(_owner.folderNames);
  final LocalFavoritesManager _owner;
  final int _generation;
  final List<String> folders;
}

class ComicImportResult {
  ComicImportResult({
    required this.succeeded,
    this.importedCount = 0,
    Iterable<ComicImportIssue> issues = const [],
    Iterable<PendingComicCopy> pendingCopies = const [],
  }) : issues = List.unmodifiable(issues),
       pendingCopies = List.unmodifiable(pendingCopies);

  /// The operation reached its normal end. A batch may still have skipped
  /// individual comics; callers must also inspect [importedCount] and [issues].
  final bool succeeded;
  final int importedCount;
  final List<ComicImportIssue> issues;
  final List<PendingComicCopy> pendingCopies;
}

/// Resolves dependencies only after data/storage admission, then keeps the same
/// local manager throughout scanning, copying, registration and compensation.
class ComicImportService {
  const ComicImportService({
    required this.localManager,
    required this.favoritesManager,
  });

  final LocalManager Function() localManager;
  final LocalFavoritesManager Function() favoritesManager;

  Future<ComicImportResult> archives(
    Directory directory, {
    String? folder,
  }) async {
    final files = (await directory.list().toList()).whereType<File>().where(
      (file) => isComicArchiveFileName(file.name),
    );
    final issues = <ComicImportIssue>[];
    var count = 0;
    for (final file in files) {
      try {
        await CBZ.import(
          file,
          registerComic: (comic) => registerComic(comic, folder: folder),
        );
        count++;
      } catch (error, stack) {
        issues.add(
          ComicImportIssue(ComicImportIssueKind.archiveFailed, error, stack),
        );
      }
    }
    if (count == 0) {
      issues.add(const ComicImportIssue(ComicImportIssueKind.noValidComics));
    }
    return ComicImportResult(
      succeeded: true,
      importedCount: count,
      issues: issues,
    );
  }

  Future<T> _withOperation<T>(
    LocalManager manager,
    Future<T> Function(ComicImportOperation operation) action, {
    bool recovery = false,
  }) async {
    manager.requireStorageAccess();
    final operation = ComicImportOperation._(
      manager,
      favoritesManager,
      recovery,
    );
    try {
      return await action(operation);
    } finally {
      operation._active = false;
    }
  }

  /// The caller may prepare a selected directory within this reservation.
  /// Await all work before returning; the operation cannot be reused afterward.
  Future<T> runImport<T>(
    Future<T> Function(ComicImportOperation operation) action,
  ) => LocalComicStorageGuard.instance.runImport(
    () => _withOperation(localManager(), action),
  );

  Future<T> runRecovery<T>(
    Future<T> Function(ComicImportOperation operation) action,
  ) => AppDataOperations.instance.access(() {
    final manager = localManager();
    return manager.runWithExclusiveStorage(
      () => _withOperation(manager, action, recovery: true),
    );
  });

  /// Document converters already hold their import reservation. The data
  /// barrier also protects callers that only need to register an existing file.
  Future<void> registerComic(LocalComic comic, {String? folder}) =>
      AppDataOperations.instance.access(
        () => _withOperation(
          localManager(),
          (operation) => operation._registerComic(comic, folder: folder),
        ),
      );
}

class ComicImportOperation {
  ComicImportOperation._(this._manager, this._favoritesManager, this._recovery);
  final LocalManager _manager;
  final LocalFavoritesManager Function() _favoritesManager;
  final bool _recovery;
  bool _active = true;

  void _checkActive() {
    if (!_active) throw StateError('Comic import operation has ended');
  }

  Future<ComicImportResult> directory(
    Directory directory, {
    required bool single,
    required bool copy,
    String? folder,
  }) async {
    _checkActive();
    final imported = <String?, List<LocalComic>>{folder: []};
    final issues = <ComicImportIssue>[];
    try {
      if (single) {
        final comic = await _checkSingleComic(directory);
        if (comic == null) {
          return ComicImportResult(
            succeeded: false,
            issues: [const ComicImportIssue(ComicImportIssueKind.invalidComic)],
          );
        }
        imported[folder]!.add(comic);
      } else {
        await for (final entry in directory.list()) {
          if (entry is Directory) {
            final comic = await _checkSingleComic(entry);
            if (comic != null) imported[folder]!.add(comic);
          }
        }
      }
    } catch (error, stack) {
      issues.add(
        ComicImportIssue(ComicImportIssueKind.scanFailed, error, stack),
      );
    }
    return _registerComics(imported, copy, issues);
  }

  Future<ComicImportResult> localDownloads({
    required bool Function() isCancelled,
    void Function()? onScanComplete,
  }) async {
    _checkActive();
    if (!_recovery) {
      throw StateError(
        'Local downloads require an exclusive recovery operation',
      );
    }
    final localDir = _manager.directory;
    final imported = <String?, List<LocalComic>>{null: []};
    final issues = <ComicImportIssue>[];
    final records = <LocalComic, ComicCopyRecord>{};
    final pendingCopies = <PendingComicCopy>[];
    try {
      if (!await localDir.exists()) {
        return ComicImportResult(
          succeeded: false,
          issues: [
            const ComicImportIssue(ComicImportIssueKind.localPathNotFound),
          ],
        );
      }
      final registeredDirectories = _manager.registeredComicDirectories;
      await for (final entry in localDir.list()) {
        if (isCancelled()) break;
        if (entry is Directory) {
          if (registeredDirectories.any(
            (registered) => path.equals(
              path.absolute(registered),
              path.absolute(entry.path),
            ),
          )) {
            if (ComicCopyRecord.exists(entry)) {
              try {
                await _cleanupRegisteredCopy(entry);
              } catch (error, stack) {
                issues.add(
                  ComicImportIssue(
                    ComicImportIssueKind.copyRecoveryRequired,
                    error,
                    stack,
                  ),
                );
              }
            }
            continue;
          }
          if (ComicCopyRecord.exists(entry)) {
            try {
              final record = ComicCopyRecord.read(entry);
              // Recovery performs the expensive payload verification off the UI
              // isolate. The exclusive storage owner stays held until it ends.
              final verified = await compute(_inspectCopyRecord, (
                directory: entry.path,
                library: localDir.path,
              ));
              if (verified.digest != record.intentDigest) {
                throw StateError('Copy intent changed during recovery');
              }
              final metadata = record.metadata;
              if (metadata == null) {
                throw StateError(
                  'Copy recovery is missing the original comic metadata',
                );
              }
              final saved = decodeComicCopyMetadata(metadata, entry.path);
              if (saved.folder != null ||
                  verified.kind == ComicCopyRecoveryKind.resumable) {
                pendingCopies.add(
                  PendingComicCopy._(
                    _manager,
                    directory: entry.path,
                    title: saved.comic.title,
                    folder: saved.folder,
                    intentDigest: record.intentDigest,
                    kind: verified.kind,
                  ),
                );
                continue;
              }
              if (_manager.findByName(saved.comic.title) != null) {
                throw StateError(
                  'Copy recovery title is already registered: ${saved.comic.title}',
                );
              }
              imported[null]!.add(saved.comic);
              records[saved.comic] = record;
            } catch (error, stack) {
              issues.add(
                ComicImportIssue(
                  ComicImportIssueKind.copyRecoveryRequired,
                  error,
                  stack,
                ),
              );
            }
            continue;
          }
          try {
            final digest = await compute(_unverifiedCopyDigest, (
              directory: entry.path,
              library: localDir.path,
            ));
            final comic = await _checkSingleComic(
              entry,
              createTime: (await entry.stat()).modified,
              useRelativePath: true,
            );
            if (comic != null) {
              pendingCopies.add(
                PendingComicCopy._(
                  _manager,
                  directory: entry.path,
                  title: comic.title,
                  folder: null,
                  intentDigest: digest,
                  kind: ComicCopyRecoveryKind.unverified,
                ),
              );
            }
          } catch (error, stack) {
            issues.add(
              ComicImportIssue(
                ComicImportIssueKind.copyRecoveryRequired,
                error,
                stack,
              ),
            );
          }
        }
      }
      if (!isCancelled() && imported[null]!.isEmpty && pendingCopies.isEmpty) {
        issues.add(const ComicImportIssue(ComicImportIssueKind.noValidComics));
      }
    } catch (error, stack) {
      issues.add(
        ComicImportIssue(ComicImportIssueKind.scanFailed, error, stack),
      );
    } finally {
      onScanComplete?.call();
    }
    if (isCancelled()) {
      return ComicImportResult(succeeded: false, issues: issues);
    }
    return _registerComics(
      imported,
      false,
      issues,
      records: records,
      pendingCopies: pendingCopies,
    );
  }

  LocalComic _copyRegistration(ComicCopyRecord record) {
    final registered = _manager.comicsAtDirectory(record.directory.path);
    if (registered.length != 1 || record.metadata == null) {
      throw StateError('Copy cleanup requires one exact local registration');
    }
    final intended = decodeComicCopyMetadata(
      record.metadata!,
      record.directory.path,
    ).comic;
    if (!matchesComicCopyMetadata(intended, registered.single)) {
      throw StateError(
        'Copy cleanup metadata differs from the registered comic',
      );
    }
    return registered.single;
  }

  Future<void> _cleanupRegisteredCopy(Directory directory) async {
    _checkCopyLocation(directory.path, _manager.path);
    final record = ComicCopyRecord.readForCleanup(directory);
    final registered = comicCopyRegistration(_copyRegistration(record));
    if (!record.hasRegistration(registered)) {
      // Version-1 leftovers have no cleanup receipt. Only a complete, unchanged
      // output matching the actual row can acquire one, never path/title alone.
      final verified = await compute(_verifyCopyRecord, (
        directory: directory.path,
        library: _manager.path,
      ));
      if (verified != record.intentDigest) {
        throw StateError('Copy intent changed during cleanup verification');
      }
    }
    await _manager.checkExclusiveComicDirectory(_copyRegistration(record));
    _checkCopyLocation(directory.path, _manager.path);
    if (comicCopyRegistration(_copyRegistration(record)) != registered) {
      throw StateError('Copy registration changed during cleanup verification');
    }
    record.removeAfterRegistration(registered);
  }

  /// An explicit new decision about the current favorites store. Never replay
  /// the old folder merely because a same-path database or name still exists.
  Future<ComicImportResult> recoverCopy(
    PendingComicCopy selection, {
    required String? folder,
    ComicCopyRecoveryFolders? favorites,
  }) async {
    _checkActive();
    if (!_recovery) {
      throw StateError('Copy recovery requires exclusive storage');
    }
    try {
      if (!identical(selection._owner, _manager) ||
          selection._library != _manager.path) {
        throw StateError('Local library changed after the recovery selection');
      }
      final directory = selection.directory;
      final intentDigest = selection.intentDigest;
      final kind = selection.kind;
      if (folder != null &&
          (favorites == null ||
              !identical(favorites._owner, _favoritesManager()) ||
              favorites._generation != favorites._owner.connectionGeneration ||
              !favorites.folders.contains(folder))) {
        throw StateError('Favorites changed after the recovery selection');
      }
      if (!path.equals(
        path.absolute(path.dirname(directory)),
        path.absolute(_manager.path),
      )) {
        throw StateError('Copy recovery belongs to a different library');
      }
      if (_manager.registeredComicDirectories.any(
        (registered) =>
            path.equals(path.absolute(registered), path.absolute(directory)),
      )) {
        return ComicImportResult(succeeded: true);
      }
      if (kind == ComicCopyRecoveryKind.unverified) {
        final entry = Directory(directory);
        final comic = await _checkSingleComic(
          entry,
          createTime: (await entry.stat()).modified,
          useRelativePath: true,
        );
        final verified = await compute(_unverifiedCopyDigest, (
          directory: directory,
          library: _manager.path,
        ));
        if (verified != intentDigest || comic == null) {
          throw StateError(
            'Available files changed after the recovery selection',
          );
        }
        if (_manager.findByName(comic.title) != null) {
          throw StateError(
            'Copy recovery title is already registered: ${comic.title}',
          );
        }
        return _registerComics(
          {
            folder: [comic],
          },
          false,
          [],
        );
      }
      final record = ComicCopyRecord.read(Directory(directory));
      if (record.intentDigest != intentDigest) {
        throw StateError('Copy intent changed after the recovery selection');
      }
      if (kind == ComicCopyRecoveryKind.resumable && !record.hasCompletion) {
        await compute(_resumeCopyRecord, (
          directory: directory,
          library: _manager.path,
          digest: intentDigest,
        ));
      }
      final verified = await compute(_verifyCopyRecord, (
        directory: directory,
        library: _manager.path,
      ));
      if (verified != record.intentDigest || record.metadata == null) {
        throw StateError('Copy recovery intent is missing or changed');
      }
      final saved = decodeComicCopyMetadata(record.metadata!, directory);
      if (_manager.findByName(saved.comic.title) != null) {
        throw StateError(
          'Copy recovery title is already registered: ${saved.comic.title}',
        );
      }
      return _registerComics(
        {
          folder: [saved.comic],
        },
        false,
        [],
        records: {saved.comic: record},
      );
    } catch (error, stack) {
      return ComicImportResult(
        succeeded: false,
        issues: [
          ComicImportIssue(
            ComicImportIssueKind.copyRecoveryRequired,
            error,
            stack,
          ),
        ],
      );
    }
  }

  ComicCopyRecoveryFolders copyRecoveryFolders() {
    _checkActive();
    if (!_recovery) {
      throw StateError('Copy recovery requires exclusive storage');
    }
    return ComicCopyRecoveryFolders._(_favoritesManager());
  }

  Future<ComicImportResult> ehViewer(
    File database,
    Directory comicSource, {
    required String defaultFolder,
    required bool copy,
    required bool Function() isCancelled,
    void Function()? onScanComplete,
  }) async {
    _checkActive();
    final imported = <String?, List<LocalComic>>{};
    final issues = <ComicImportIssue>[];
    try {
      final db = sql.sqlite3.open(database.path);
      try {
        final labels = [
          '',
          ...db
              .select('SELECT * FROM DOWNLOAD_LABELS ORDER BY TIME DESC')
              .map((row) => row['LABEL'] as String),
        ];
        for (final label in labels) {
          if (isCancelled()) break;
          final folder = label.isEmpty ? defaultFolder : '(EhViewer)$label';
          final rows = db.select('''
            SELECT * FROM DOWNLOAD_DIRNAME DN
            LEFT JOIN DOWNLOADS DL ON DL.GID = DN.GID
            WHERE DL.LABEL ${label.isEmpty ? 'IS NULL' : '= ?'} AND DL.STATE = 3
            ORDER BY DL.TIME DESC
          ''', label.isEmpty ? const [] : [label]);
          final comics = <LocalComic>[];
          for (final row in rows) {
            if (isCancelled()) break;
            final titleJP = row['TITLE_JPN'] as String? ?? '';
            final time = row['TIME'] as int;
            final comic = await _checkSingleComic(
              Directory(
                FilePath.join(comicSource.path, row['DIRNAME'] as String),
              ),
              title: titleJP.isEmpty ? row['TITLE'] as String : titleJP,
              createTime: time == 0
                  ? DateTime.now()
                  : DateTime.fromMillisecondsSinceEpoch(time),
              tags: [
                const [
                  'MISC',
                  'DOUJINSHI',
                  'MANGA',
                  'ARTISTCG',
                  'GAMECG',
                  'IMAGE SET',
                  'COSPLAY',
                  'ASIAN PORN',
                  'NON-H',
                  'WESTERN',
                ][(log(row['CATEGORY'] as int) / ln2).floor()],
              ],
            );
            if (comic != null) comics.add(comic);
          }
          imported[folder] = comics;
          if (comics.isNotEmpty) {
            final favorites = _favoritesManager();
            if (!favorites.existsFolder(folder)) {
              await favorites.createFolder(folder);
            }
          }
        }
      } finally {
        db.dispose();
      }
    } catch (error, stack) {
      issues.add(
        ComicImportIssue(ComicImportIssueKind.scanFailed, error, stack),
      );
    } finally {
      onScanComplete?.call();
    }
    if (isCancelled()) {
      return ComicImportResult(succeeded: false, issues: issues);
    }
    return _registerComics(imported, copy, issues);
  }

  Future<ComicImportResult> registerComics(
    Map<String?, List<LocalComic>> comics, {
    required bool copy,
  }) {
    _checkActive();
    return _registerComics(comics, copy, []);
  }

  Future<ComicImportResult> _registerComics(
    Map<String?, List<LocalComic>> comics,
    bool copy,
    List<ComicImportIssue> issues, {
    Map<LocalComic, ComicCopyRecord>? records,
    Iterable<PendingComicCopy> pendingCopies = const [],
  }) async {
    var count = 0;
    final ownedRecords = records ?? <LocalComic, ComicCopyRecord>{};
    try {
      if (copy) {
        comics = await _copyComicsToLocalDir(comics, issues, ownedRecords);
      }
      for (final entry in comics.entries) {
        for (final comic in entry.value) {
          ownedRecords[comic]?.checkUnchanged();
          await AppDataOperations.instance.access(
            () => _registerComic(comic, folder: entry.key),
          );
          count++;
          try {
            final record = ownedRecords[comic];
            if (record != null) {
              final registered = _copyRegistration(record);
              final snapshot = comicCopyRegistration(registered);
              await _manager.checkExclusiveComicDirectory(registered);
              if (comicCopyRegistration(_copyRegistration(record)) !=
                  snapshot) {
                throw StateError('Copy registration changed before cleanup');
              }
              record.removeAfterRegistration(snapshot);
            }
          } catch (error, stack) {
            issues.add(
              ComicImportIssue(
                ComicImportIssueKind.copyRecoveryRequired,
                error,
                stack,
              ),
            );
          }
        }
      }
    } catch (error, stack) {
      issues.add(
        ComicImportIssue(ComicImportIssueKind.registrationFailed, error, stack),
      );
      return ComicImportResult(
        succeeded: false,
        importedCount: count,
        issues: issues,
        pendingCopies: pendingCopies,
      );
    }
    return ComicImportResult(
      succeeded: true,
      importedCount: count,
      issues: issues,
      pendingCopies: pendingCopies,
    );
  }

  Future<Map<String?, List<LocalComic>>> _copyComicsToLocalDir(
    Map<String?, List<LocalComic>> comics,
    List<ComicImportIssue> issues,
    Map<LocalComic, ComicCopyRecord> records,
  ) async {
    final destination = _manager.path;
    final result = <String?, List<LocalComic>>{};
    for (final entry in comics.entries) {
      final existing = <LocalComic>[];
      final toCopy = <LocalComic>[];
      for (final comic in entry.value) {
        if (path.equals(destination, comic.directory) ||
            path.isWithin(destination, comic.directory)) {
          existing.add(comic);
        } else {
          toCopy.add(comic);
        }
      }
      result[entry.key] = existing;
      if (toCopy.isEmpty) continue;
      try {
        final metadata = <String, String>{};
        for (final comic in toCopy) {
          final encoded = encodeComicCopyMetadata(comic, entry.key);
          final earlier = metadata[comic.directory];
          if (earlier != null && earlier != encoded) {
            throw StateError('Conflicting metadata for the same copy source');
          }
          metadata[comic.directory] = encoded;
        }
        final copied = await compute(
          copyComicDirectories,
          ComicDirectoryCopyRequest(
            directories: toCopy.map((comic) => comic.directory).toList(),
            destination: destination,
            metadata: metadata,
          ),
        );
        final addedSources = <String>{};
        for (final comic in toCopy) {
          if (!addedSources.add(comic.directory)) continue;
          final directory = copied.copies[comic.directory];
          if (directory == null) {
            final failure = copied.failures[comic.directory];
            issues.add(
              ComicImportIssue(
                ComicImportIssueKind.copyFailed,
                failure,
                failure?.stackTrace,
              ),
            );
            continue;
          }
          final saved = decodeComicCopyMetadata(
            metadata[comic.directory]!,
            directory,
          ).comic;
          existing.add(saved);
          records[saved] = ComicCopyRecord.read(Directory(directory));
        }
      } catch (error, stack) {
        issues.add(
          ComicImportIssue(ComicImportIssueKind.copyFailed, error, stack),
        );
        return result;
      }
    }
    return result;
  }

  //Automatically search for cover image and chapters
  Future<LocalComic?> _checkSingleComic(
    Directory directory, {
    String? title,
    List<String>? tags,
    DateTime? createTime,
    bool useRelativePath = false,
  }) async {
    if (!(await directory.exists())) return null;
    if (ComicCopyRecord.exists(directory)) {
      throw StateError(
        'Recover the earlier comic copy before importing this directory: ${directory.path}',
      );
    }
    var name = title ?? directory.name;
    if (_manager.findByName(name) != null) {
      Log.info("Import Comic", "Comic already exists: $name");
      return null;
    }
    final layout = await ComicFileSystemLayout.inspectAsync(directory);
    if (layout.chapters.any(
      (chapter) => ComicCopyRecord.exists(chapter.directory),
    )) {
      throw StateError(
        'A chapter contains an unfinished comic import: ${directory.path}',
      );
    }
    if (layout.nestedDirectories.isNotEmpty) {
      final nested = layout.nestedDirectories.first;
      Log.info(
        "Import Comic",
        "Invalid Chapter: ${nested.parent.name}\nA directory is found in the chapter directory.",
      );
      return null;
    }
    final cover = layout.inferredCover;
    if (!layout.hasImages || cover == null) {
      Log.info("Import Comic", "Invalid Comic: $name\nNo cover image found.");
      return null;
    }
    final chapters = layout.useChapterDirectories
        ? layout.chapters.map((chapter) => chapter.title).toList()
        : const <String>[];
    final coverPath = layout.relativePath(cover);
    var directoryPath = useRelativePath ? directory.name : directory.path;
    return LocalComic(
      id: '0',
      title: name,
      subtitle: '',
      tags: tags ?? [],
      directory: directoryPath,
      chapters: layout.useChapterDirectories
          ? ComicChapters(Map.fromIterables(chapters, chapters))
          : null,
      cover: coverPath,
      comicType: ComicType.local,
      downloadedChapters: chapters,
      createdAt: createTime ?? DateTime.now(),
    );
  }

  Future<void> _registerComic(LocalComic comic, {String? folder}) async {
    _checkActive();
    if (folder != null) return _registerWithFavorite(comic, folder);
    late final String id;
    try {
      id = _manager.findValidId(comic.comicType);
    } catch (error, stack) {
      _registrationFailed(error, stack, PersistenceCommitState.notCommitted);
    }
    try {
      await _manager.add(comic, id);
    } catch (error, stack) {
      var state = error is PersistenceFailure
          ? error.commitState
          : PersistenceCommitState.unknown;
      final diagnostics = <({Object error, StackTrace stackTrace})>[];
      if (error is! PersistenceFailure &&
          error is! SqliteTransactionRollbackError) {
        try {
          if (_manager.find(id, comic.comicType) == null) {
            state = PersistenceCommitState.notCommitted;
          }
        } catch (verificationError, verificationStack) {
          diagnostics.add((
            error: verificationError,
            stackTrace: verificationStack,
          ));
        }
      }
      _registrationFailed(error, stack, state, diagnostics);
    }
  }

  Future<void> _registerWithFavorite(LocalComic comic, String folder) async {
    // The favorites queue may wait. Detach caller-owned lists and chapter maps
    // before admission to it, and allocate the ID only when the write executes.
    final captured = LocalComic(
      id: comic.id,
      title: comic.title,
      subtitle: comic.subtitle,
      tags: List<String>.of(comic.tags),
      directory: comic.directory,
      chapters: ComicChapters.fromJsonOrNull(comic.chapters?.toJson()),
      cover: comic.cover,
      comicType: comic.comicType,
      downloadedChapters: List<String>.of(comic.downloadedChapters),
      createdAt: comic.createdAt,
    );
    var startedWrite = false;
    var committed = false;
    PersistenceFailure? committedFailure;
    try {
      await _favoritesManager().addComicWithStorage(folder, captured.tags, (
        favoritesPath,
        translatedTags,
        append,
      ) {
        final id = _manager.findValidId(captured.comicType);
        final favorite = FavoriteItem(
          id: id,
          name: captured.title,
          coverPath: captured.cover,
          author: captured.subtitle,
          type: captured.comicType,
          tags: captured.tags,
          favoriteTime: captured.createdAt,
        );
        startedWrite = true;
        try {
          _manager.addWithFavorite(
            captured,
            id,
            favoritesPath: favoritesPath,
            folder: folder,
            favorite: favorite,
            translatedTags: translatedTags,
            append: append,
          );
        } on PersistenceFailure catch (error) {
          if (error.commitState != PersistenceCommitState.committed) rethrow;
          committedFailure = error;
        }
        committed = true;
        return favorite;
      });
    } catch (error, stack) {
      _registrationFailed(
        committedFailure ?? error,
        committedFailure?.stackTrace ?? stack,
        committed
            ? PersistenceCommitState.committed
            : error is PersistenceFailure
            ? error.commitState
            : startedWrite
            ? PersistenceCommitState.unknown
            : PersistenceCommitState.notCommitted,
        [if (committedFailure != null) (error: error, stackTrace: stack)],
      );
    }
    if (committedFailure != null) {
      Error.throwWithStackTrace(
        committedFailure!,
        committedFailure!.stackTrace,
      );
    }
  }

  Never _registrationFailed(
    Object error,
    StackTrace stack,
    PersistenceCommitState state, [
    List<({Object error, StackTrace stackTrace})> cleanup = const [],
  ]) {
    final persistence = error is PersistenceFailure ? error : null;
    Error.throwWithStackTrace(
      PersistenceFailure(
        commitState: state,
        cause: persistence?.cause ?? error,
        stackTrace: persistence?.stackTrace ?? stack,
        cleanupFailures: [...?persistence?.cleanupFailures, ...cleanup],
      ),
      persistence?.stackTrace ?? stack,
    );
  }
}
