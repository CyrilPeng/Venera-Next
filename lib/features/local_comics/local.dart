import 'package:venera_next/foundation/operation_failure.dart';
import 'local_comic_model.dart';
import 'local_repository.dart';
import 'local_chapter_storage.dart';
import 'local_deletion_paths.dart';
import 'local_related_data.dart';
import 'local_deletion_journal.dart';
import 'local_registration_storage.dart';
import 'package:venera_next/features/favorites/favorites_api.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/sqlite_transaction.dart';
import 'download_task_store.dart';
import 'download_directory_allocator.dart';
import 'local_sort_type.dart';
export 'local_sort_type.dart';
export 'local_comic_model.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/sqlite_connection.dart';
import 'download_task.dart';
import 'download_task_storage.dart';
import 'download_queue.dart';
import 'download_task_codec.dart';
import 'package:venera_next/foundation/file_interaction.dart';

import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/features/history/history_api.dart';

import 'local_storage_guard.dart';
import 'local_storage_migration.dart';
import 'local_storage_relocation.dart';

extension LocalComicFiles on LocalComic {
  File get coverFile => File(FilePath.join(baseDir, cover));

  String get baseDir =>
      _comicLocations[this]?.path ??
      _resolveComicDirectory(directory, LocalManager().path);
}

final _comicLocations = Expando<_ComicLocation>();

/// Shared by models of one registration. It contains no manager or database,
/// and remains detached when that registration or manager is replaced.
class _ComicLocation {
  _ComicLocation(this.stored, this.library, this.access);
  String stored;
  String library;
  final _ComicStorageAccess access;
  String get path {
    access.check();
    return _resolveComicDirectory(stored, library);
  }
}

class _ComicStorageAccess {
  LocalStorageRelocationAttempt? pending;
  void check() {
    if (pending != null) {
      throw const LocalComicStorageBusy(
        'Local library recovery is required. Retry the library move before accessing comics.',
      );
    }
  }
}

String _resolveComicDirectory(String directory, String libraryPath) =>
    (directory.contains('/') || directory.contains('\\'))
    ? directory
    : FilePath.join(libraryPath, directory);

class LocalManager with ChangeNotifier implements DownloadTaskStorage {
  static LocalManager? _instance;

  /// The live default owner, without creating a replacement during shutdown.
  static LocalManager? get current => _instance;

  LocalManager._({
    Database Function(String)? openDatabase,
    Future<void> Function()? initializeSources,
    LocalComicRelatedData? relatedData,
  }) : _openDatabase = openDatabase ?? openSqliteDatabase,
       _initializeSources = initializeSources,
       _providedRelatedData = relatedData;

  /// A caller-owned library that does not replace the application's default.
  factory LocalManager.independent({
    Database Function(String)? openDatabase,
    Future<void> Function()? initializeSources,
    LocalComicRelatedData? relatedData,
  }) => LocalManager._(
    openDatabase: openDatabase,
    initializeSources: initializeSources,
    relatedData: relatedData,
  );

  final Database Function(String) _openDatabase;
  final Future<void> Function()? _initializeSources;
  final LocalComicRelatedData? _providedRelatedData;
  late final _relatedData =
      _providedRelatedData ?? LocalComicRelatedData.managed();
  Future<void>? _initialization;
  Database? _database;
  late File _libraryPathFile;
  final _comicDirectories = <(String, int), _ComicLocation>{};
  final _storageAccess = _ComicStorageAccess();
  bool _disposed = false;
  bool _notifierDisposed = false;

  factory LocalManager({
    Database Function(String)? openDatabase,
    Future<void> Function()? initializeSources,
    LocalComicRelatedData? relatedData,
  }) {
    if (_instance != null &&
        (openDatabase != null ||
            initializeSources != null ||
            relatedData != null)) {
      throw StateError('Local manager dependencies are already bound');
    }
    return _instance ??= LocalManager._(
      openDatabase: openDatabase,
      initializeSources: initializeSources,
      relatedData: relatedData,
    );
  }

  Database get _rawDatabase =>
      _database ?? (throw StateError('Local manager is not initialized'));

  Database get _db {
    _storageAccess.check();
    return _rawDatabase;
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('Local manager is disposed');
  }

  /// path to the directory where all the comics are stored
  @override
  String get path {
    _storageAccess.check();
    return _path;
  }

  late String _path;
  set path(String value) {
    _storageAccess.check();
    _path = value;
  }

  Directory get directory => Directory(path);

  bool get requiresStorageRecovery => _storageAccess.pending != null;

  /// Check the bound library before an importer starts work with its files.
  void requireStorageAccess() {
    _checkNotDisposed();
    _storageAccess.check();
  }

  void _checkNoMedia() {
    if (App.isAndroid) {
      var file = File(FilePath.join(path, '.nomedia'));
      if (!file.existsSync()) {
        file.createSync();
      }
    }
  }

  // return error message if failed
  Future<String?> setNewPath(String newPath) async {
    try {
      final recovering = _storageAccess.pending != null;
      return await _runWithExclusiveStorage(
        () => recovering
            ? Future.value(
                'Local library recovery completed. Try moving the library again.',
              )
            : _setNewPath(newPath),
        recoverAuthority: recovering,
      );
    } on LocalComicStorageBusy catch (error) {
      return error.message.tl;
    } catch (error, stack) {
      Log.error('IO', error, stack);
      return error.toString();
    }
  }

  /// Reconcile the original connection before releasing this library's fence.
  /// Repeated failure keeps the fence; a successful retry does not move again.
  Future<void> recoverStorage() =>
      _runWithExclusiveStorage(() async {}, recoverAuthority: true);

  /// Migration/recovery may not reinterpret directories owned by queued tasks.
  Future<T> runWithExclusiveStorage<T>(Future<T> Function() action) =>
      _runWithExclusiveStorage(action);

  Future<T> _runWithExclusiveStorage<T>(
    Future<T> Function() action, {
    bool recoverAuthority = false,
  }) => LocalComicStorageGuard.instance.runExclusive(() async {
    if (!recoverAuthority) _storageAccess.check();
    if (downloadingTasks.isNotEmpty || _downloadQueue.isSuspended) {
      throw const LocalComicStorageBusy(
        'Wait for downloads to finish or cancel them before changing the local library.',
      );
    }
    final stopped = _downloadQueue.suspend(notify: false);
    try {
      await stopped;
      if (recoverAuthority) {
        await _storageMigration.recover(
          _libraryPathFile,
          attempt: _storageAccess.pending,
        );
      }
      _storageAccess.check();
      await _deletionJournal.recover();
      return await action();
    } finally {
      _downloadQueue.releaseSuspension(stopped, notify: false);
    }
  });

  Future<String?> _setNewPath(String newPath) async {
    try {
      final result = await _storageMigration.migrate(
        source: directory,
        destination: Directory(newPath),
        pathFile: _libraryPathFile,
      );
      if (result != null) return result;
      try {
        _checkNoMedia();
      } catch (error, stack) {
        Log.error('IO', error, stack);
      }
      return null;
    } catch (error, stack) {
      Log.error('IO', error, stack);
      return error.toString();
    }
  }

  void _publishStoragePath(String value) {
    for (final location in _comicDirectories.values) {
      location.library = value;
    }
    _path = value;
    _storageAccess.pending = null;
  }

  LocalStorageMigration get _storageMigration => LocalStorageMigration(
    copyContents: copyDirectoryIsolate,
    publishPath: _publishStoragePath,
    invalidateAuthority: (attempt) => _storageAccess.pending = attempt,
    publishRelocation: (state) {
      if (state.committed) {
        for (final change in state.references) {
          final location =
              _comicDirectories[(change[0] as String, change[1] as int)];
          if (location?.stored == change[2]) {
            location!.stored = change[3] as String;
          }
        }
      }
      _publishStoragePath(state.committed ? state.destination : state.source);
    },
    reportCleanupError: (error, stack) => Log.error('IO', error, stack),
    relocation: LocalStorageRelocation(_rawDatabase),
    checkCopyOwnership: checkExclusiveComicDirectory,
    resolveReference: (value) => Directory(value) is AndroidDirectory
        ? Future.value(value)
        : resolveLocalNativePath(value),
    clearContents: (source) async {
      final allowed = await _resolveDeletionDirectories([source]);
      if (allowed.isEmpty) {
        throw StateError(
          'Old library is still referenced; its files were kept',
        );
      }
      await source.deleteContents();
    },
    canonicalPath: (directory) => directory is AndroidDirectory
        ? Future.value(directory.path)
        : directory.resolveSymbolicLinks(),
  );

  Future<String> findDefaultPath() async {
    if (App.isAndroid) {
      var external = await getExternalStorageDirectories();
      if (external != null && external.isNotEmpty) {
        return FilePath.join(external.first.path, 'local');
      } else {
        return FilePath.join(App.dataPath, 'local');
      }
    } else if (App.isIOS) {
      var oldPath = FilePath.join(App.dataPath, 'local');
      if (Directory(oldPath).existsSync() &&
          Directory(oldPath).listSync().isNotEmpty) {
        return oldPath;
      } else {
        var directory = await getApplicationDocumentsDirectory();
        return FilePath.join(directory.path, 'local');
      }
    } else {
      return FilePath.join(App.dataPath, 'local');
    }
  }

  Future<void> _checkPathValidation({bool allowFallback = true}) async {
    var testFile = File(FilePath.join(path, 'venera_test'));
    try {
      testFile.createSync();
      testFile.deleteSync();
    } catch (e) {
      if (!allowFallback) rethrow;
      Log.error(
        "IO",
        "Failed to create test file in local path: $e\nUsing default path instead.",
      );
      path = await findDefaultPath();
    }
  }

  Future<void> init() {
    if (_disposed) return Future.error(StateError('Local manager is disposed'));
    return _initialization ??= _initialize().catchError((
      Object error,
      StackTrace stack,
    ) {
      final database = _database;
      try {
        database?.dispose();
        _database = null;
      } catch (closeError, closeStack) {
        // A failed close retains the original handle and forbids a second
        // initialization. The owner can retry dispose before replacing it.
        _disposed = true;
        Log.error('LocalManager', closeError, closeStack);
      }
      _initialization = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> _initialize() async {
    _downloadSnapshotPath = FilePath.join(
      App.dataPath,
      'downloading_tasks.json',
    );
    _database = _openDatabase('${App.dataPath}/local.db');
    _libraryPathFile = File(FilePath.join(App.dataPath, 'local_path'));
    LocalRepository(_rawDatabase).initialize();
    LocalStorageRelocation(_rawDatabase).initialize();
    final relocatedPath = await _storageMigration.recover(_libraryPathFile);
    _deletionJournal.initialize();
    await _deletionJournal.recover();
    if (relocatedPath != null) {
      path = relocatedPath;
    } else if (_libraryPathFile.existsSync()) {
      path = _libraryPathFile.readAsStringSync();
      if (!directory.existsSync()) {
        path = await findDefaultPath();
      }
    } else {
      path = await findDefaultPath();
    }
    _checkNotDisposed();
    try {
      if (!directory.existsSync()) {
        await directory.create();
      }
    } catch (e, s) {
      Log.error("IO", "Failed to create local folder: $e", s);
    }
    _checkNotDisposed();
    await _checkPathValidation(allowFallback: relocatedPath == null);
    _checkNotDisposed();
    _checkNoMedia();
    if (_initializeSources != null) {
      await _initializeSources();
    } else {
      await ComicSourceManager().ensureInit();
    }
    _checkNotDisposed();
    restoreDownloadingTasks();
  }

  String findValidId(ComicType type) => _repository.findValidId(type);

  Future<void> add(LocalComic comic, [String? id]) async {
    LocalComicStorageGuard.instance.write(() => _repository.add(comic, id));
    _rememberComic(comic, id: id);
    notifyListeners();
  }

  /// Called synchronously from the owning favorites mutation queue.
  void addWithFavorite(
    LocalComic comic,
    String id, {
    required String favoritesPath,
    required String folder,
    required FavoriteItem favorite,
    required String translatedTags,
    required bool append,
  }) {
    PersistenceFailure? failure;
    try {
      LocalComicStorageGuard.instance.write(
        () => registerLocalComicRecords(
          localDatabase: _db,
          comic: comic,
          id: id,
          favoritesPath: favoritesPath,
          folder: folder,
          favorite: favorite,
          translatedTags: translatedTags,
          append: append,
        ),
      );
    } on PersistenceFailure catch (error) {
      if (error.commitState != PersistenceCommitState.committed) rethrow;
      failure = error;
    }
    _rememberComic(comic, id: id);
    try {
      notifyListeners();
    } catch (error, stack) {
      Error.throwWithStackTrace(
        PersistenceFailure(
          commitState: PersistenceCommitState.committed,
          cause: failure?.cause ?? error,
          stackTrace: failure?.stackTrace ?? stack,
          cleanupFailures: [
            ...?failure?.cleanupFailures,
            if (failure != null) (error: error, stackTrace: stack),
          ],
        ),
        failure?.stackTrace ?? stack,
      );
    }
    if (failure != null) Error.throwWithStackTrace(failure, failure.stackTrace);
  }

  void remove(String id, ComicType comicType, {bool notify = true}) {
    LocalComicStorageGuard.instance.write(
      () => _repository.remove(id, comicType),
    );
    _comicDirectories.remove((id, comicType.value));
    if (notify) notifyListeners();
  }

  LocalRepository get _repository => LocalRepository(_db);

  List<LocalComic> getComics(LocalSortType sortType) =>
      _repository.getComics(sortType).map(_rememberComic).toList();

  LocalComic _rememberComic(LocalComic comic, {String? id}) {
    final key = (id ?? comic.id, comic.comicType.value);
    var location = _comicDirectories[key];
    if (location == null || location.stored != comic.directory) {
      location = _ComicLocation(comic.directory, path, _storageAccess);
      _comicDirectories[key] = location;
    }
    _comicLocations[comic] = location;
    return comic;
  }

  /// Capture storage ownership without decoding unrelated comic metadata.
  List<String> get registeredComicDirectories => _repository
      .directoryReferences()
      .map((directory) => _resolveComicDirectory(directory, path))
      .toList(growable: false);

  /// Resolve legacy relative paths without decoding unrelated metadata. Return
  /// every matching row so recovery can reject ambiguous shared ownership.
  List<LocalComic> comicsAtDirectory(String directory) => [
    for (final stored in _repository.directoryReferences().toSet())
      if (p.equals(
        p.absolute(_resolveComicDirectory(stored, path)),
        p.absolute(directory),
      ))
        ..._repository.findByDirectory(stored).map(_rememberComic),
  ];

  /// Control-file cleanup needs the same protection from retained records and
  /// native aliases as directory deletion, even though it never removes pages.
  Future<void> checkExclusiveComicDirectory(LocalComic comic) async {
    final selected = await _resolveDeletionDirectories(
      [Directory(_resolveComicDirectory(comic.directory, path))],
      excluding: [comic],
    );
    if (selected.isEmpty) {
      throw StateError(
        'Copy cleanup directory is also owned by another record',
      );
    }
  }

  @override
  LocalComic? find(String id, ComicType comicType) {
    final comic = _repository.find(id, comicType);
    return comic == null ? null : _rememberComic(comic);
  }

  List<LocalComic> getRecent() =>
      _repository.getRecent().map(_rememberComic).toList();
  int get count => _repository.count;
  LocalComic? findByName(String name) {
    final comic = _repository.findByName(name);
    return comic == null ? null : _rememberComic(comic);
  }

  List<LocalComic> search(String keyword) =>
      _repository.search(keyword).map(_rememberComic).toList();

  @override
  void dispose() {
    if (_notifierDisposed) return;
    _disposed = true;
    // Do not discard a handle or publish a replacement owner if close fails.
    _database?.dispose();
    _database = null;
    _comicDirectories.clear();
    super.dispose();
    _notifierDisposed = true;
    if (identical(_instance, this)) _instance = null;
  }

  Future<List<String>> getImages(String id, ComicType type, Object ep) async {
    if (ep is! String && ep is! int) {
      throw OperationFailure.message("Invalid ep");
    }
    var comic =
        find(id, type) ?? (throw OperationFailure.message("Comic Not Found"));
    var directory = Directory(comic.baseDir);
    if (comic.hasChapters) {
      var cid = ep is int
          ? comic.chapters!.ids.elementAt(ep - 1)
          : (ep as String);
      cid = localChapterDirectoryName(cid);
      directory = Directory(FilePath.join(directory.path, cid));
    }
    var files = <File>[];
    await for (var entity in directory.list()) {
      if (entity is File) {
        if (isIgnoredComicStorageEntry(entity.name) ||
            !isComicImageFileName(entity.name) ||
            isNamedComicCover(entity.name)) {
          continue;
        }
        files.add(entity);
      }
    }
    files.sort((a, b) => compareComicFileNames(a.name, b.name));
    return files.map((e) => "file://${e.path}").toList();
  }

  /// Preserve the actual saved image on the first read after the sort upgrade.
  /// Record the mapping before writing history so an interrupted migration can
  /// be resumed without interpreting an already converted page a second time.
  Future<void> migrateLegacyPageOrder(History history) {
    if (history.type != ComicType.local) return Future.value();
    return LocalComicStorageGuard.instance.runImport(
      () => _migrateLegacyPageOrder(history),
    );
  }

  Future<void> _migrateLegacyPageOrder(History history) async {
    final oldPage = history.page;
    final historyTime = history.time.millisecondsSinceEpoch;
    var migration = _repository.findPageMigration(history.id, history.type);
    if (migration == null) {
      var page = oldPage;
      if (history.ep > 0 && page > 0) {
        var chapter = history.ep;
        final chapters = find(history.id, ComicType.local)?.chapters;
        if (chapters != null && chapters.isGrouped && history.group != null) {
          chapter = chapters.chapterIndex(chapter, group: history.group);
        }
        final images = await getImages(history.id, ComicType.local, chapter);
        final legacy = images.toList()..sort(compareLegacyComicFileNames);
        if (page <= legacy.length) page = images.indexOf(legacy[page - 1]) + 1;
      }
      migration = _repository.recordPageMigration(
        history.id,
        history.type,
        LocalPageMigration(historyTime, oldPage, page),
      );
    }
    if (migration.historyTime == history.time.millisecondsSinceEpoch &&
        migration.oldPage == history.page &&
        migration.newPage != null &&
        migration.newPage != history.page) {
      final previousPage = history.page;
      final convertedPage = migration.newPage!;
      history.page = convertedPage;
      try {
        await _relatedData.saveMigratedHistory(history);
      } catch (_) {
        // Keep the persisted mapping for retry without leaving this instance
        // looking successfully converted after a failed history write.
        if (history.page == convertedPage &&
            history.time.millisecondsSinceEpoch == migration.historyTime) {
          history.page = previousPage;
        }
        rethrow;
      }
    }
  }

  bool isDownloaded(String id, ComicType type, [int? ep]) {
    final comic = find(id, type);
    if (comic == null) return false;
    if (comic.chapters == null || ep == null) return true;
    return comic.downloadedChapters.contains(
      comic.chapters!.ids.elementAtOrNull(ep - 1),
    );
  }

  late final _downloadQueue = DownloadQueue(
    commitComic: (comic) => _repository.add(comic),
    notifyChanged: notifyListeners,
    requestSave: saveCurrentDownloadingTasks,
    reportError: (error, stack) => Log.error('DownloadQueue', error, stack),
  );

  List<DownloadTask> get downloadingTasks => _downloadQueue.tasks;

  bool isDownloading(String id, ComicType type) =>
      _downloadQueue.contains(id, type);

  late final _downloadDirectories = DownloadDirectoryAllocator(
    rootPath: () => path,
    findRegisteredPath: (id, type) {
      final comic = find(id, type);
      return comic == null ? null : FilePath.join(path, comic.directory);
    },
  );

  @override
  Future<DownloadDirectoryAllocation> allocateDownloadDirectory(
    String id,
    ComicType type,
    String name,
  ) async {
    requireStorageAccess();
    return LocalComicStorageGuard.instance.runImport(() {
      // A caller waiting behind a migration must recheck its original library.
      requireStorageAccess();
      return _downloadDirectories.allocate(id, type, name);
    });
  }

  @override
  void completeTask(DownloadTask task) {
    _storageAccess.check();
    _downloadQueue.complete(task);
  }

  @override
  void removeTask(DownloadTask task) => _downloadQueue.remove(task);

  bool get isDownloadResumePending => _downloadQueue.isResumePending;

  Future<void> cancelDownload(DownloadTask task) => _downloadQueue.cancel(task);

  void resumeDownload(DownloadTask task) {
    _storageAccess.check();
    _downloadQueue.resume(task);
  }

  Future<void> pauseDownload(DownloadTask task) => _downloadQueue.pause(task);

  Future<void> moveToFirst(DownloadTask task) {
    _storageAccess.check();
    return _downloadQueue.moveToFirst(task);
  }

  /// Do not initialize a library just to close a window that never used it.
  /// Keep the queue suspended on success until exit or explicit release.
  static Future<VoidCallback> prepareDownloadsForExit() async {
    final manager = _instance;
    if (manager == null) return () {};
    final initialization = manager._initialization;
    if (initialization != null) await initialization;
    var storage = LocalComicStorageGuard.instance.pendingExclusive;
    while (storage != null) {
      await storage;
      storage = LocalComicStorageGuard.instance.pendingExclusive;
    }
    final preparation = manager._downloadQueue.suspend();
    try {
      await preparation;
      await manager.saveCurrentDownloadingTasks();
      await manager.pendingDownloadTaskWrites;
      return () => manager._downloadQueue.releaseSuspension(preparation);
    } catch (_) {
      manager._downloadQueue.releaseSuspension(preparation);
      rethrow;
    }
  }

  final _downloadTaskStore = DownloadTaskStore(
    onError: (error, stack) => Log.error('LocalManager', error, stack),
  );

  String? _downloadSnapshotPath;

  // Uninitialized queues retain support for cancellation and snapshot tests;
  // initialized libraries always use the path captured before startup awaits.
  String get _taskSnapshotPath =>
      _downloadSnapshotPath ??
      FilePath.join(App.dataPath, 'downloading_tasks.json');

  /// Completes when all task snapshots queued so far have finished writing.
  Future<void> get pendingDownloadTaskWrites =>
      _downloadTaskStore.pendingWrites;

  @override
  Future<void> saveCurrentDownloadingTasks() => _downloadTaskStore.save(
    _taskSnapshotPath,
    downloadingTasks.map((task) => task.toJson()),
  );

  /// Install a fully decoded paused snapshot during initialization/recovery.
  void restorePausedDownloads(Iterable<DownloadTask> tasks) {
    _storageAccess.check();
    _downloadQueue.restorePausedTasks(tasks);
  }

  void restoreDownloadingTasks() {
    _storageAccess.check();
    try {
      final tasks = _downloadTaskStore.restore(
        _taskSnapshotPath,
        (json) => downloadTaskFromJson(json, storage: this),
      );
      if (tasks != null) {
        restorePausedDownloads(tasks);
      }
    } catch (error, stack) {
      Log.error('LocalManager', error, stack);
    }
  }

  void addTask(DownloadTask task) {
    _storageAccess.check();
    _downloadQueue.add(task);
  }

  Future<void> deleteComic(LocalComic c, [bool removeFileOnDisk = true]) =>
      runWithExclusiveStorage(() => _deleteComic(c, removeFileOnDisk));

  Future<void> _deleteComic(LocalComic c, bool removeFileOnDisk) async {
    final current = find(c.id, c.comicType);
    if (current == null) return;
    c = current;
    final snapshot = _repository.deletionSnapshot();
    final directories = removeFileOnDisk
        ? await _resolveDeletionDirectories(
            [Directory(c.baseDir)],
            excluding: [c],
          )
        : const <Directory>[];
    await _deletionJournal.run(
      directories,
      (markCommitted) => _deleteRecords(
        [c],
        c.comicType == ComicType.local,
        markCommitted: markCommitted,
        expectedSnapshot: snapshot,
      ),
    );
    notifyListeners();
  }

  Future<void> deleteComicChapters(LocalComic c, List<String> chapters) =>
      runWithExclusiveStorage(() => _deleteComicChapters(c, chapters));

  Future<void> _deleteComicChapters(LocalComic c, List<String> chapters) async {
    final current = find(c.id, c.comicType);
    if (current == null) return;
    c = current;
    if (chapters.isEmpty) {
      return;
    }
    final snapshot = _repository.deletionSnapshot();
    final remainingChapters = c.downloadedChapters
        .where((chapter) => !chapters.contains(chapter))
        .toList();
    final directories = localChapterDirectoriesToDelete(
      removed: chapters,
      retained: remainingChapters,
    );
    var shouldRemovedDirs = <Directory>[];
    for (final directory in directories) {
      var dir = Directory(FilePath.join(c.baseDir, directory));
      if (dir.existsSync()) {
        shouldRemovedDirs.add(dir);
      }
    }
    shouldRemovedDirs = await _resolveDeletionDirectories(
      shouldRemovedDirs,
      chapterOwner: c,
      retainedChapters: remainingChapters,
    );
    await _deletionJournal.run(shouldRemovedDirs, (markCommitted) async {
      runSqliteTransaction(_db, () {
        _validateDeletionSnapshot(snapshot);
        _repository.removeChapters(c.id, c.comicType, chapters);
        markCommitted();
      });
    });
    notifyListeners();
  }

  Future<void> batchDeleteComics(
    List<LocalComic> comics, [
    bool removeFileOnDisk = true,
    bool removeFavoriteAndHistory = true,
  ]) => runWithExclusiveStorage(
    () =>
        _batchDeleteComics(comics, removeFileOnDisk, removeFavoriteAndHistory),
  );

  Future<void> _batchDeleteComics(
    List<LocalComic> comics,
    bool removeFileOnDisk,
    bool removeFavoriteAndHistory,
  ) async {
    comics = [for (final comic in comics) ?find(comic.id, comic.comicType)];
    if (comics.isEmpty) {
      return;
    }

    final snapshot = _repository.deletionSnapshot();
    var shouldRemovedDirs = <Directory>[];
    try {
      for (final comic in comics) {
        if (removeFileOnDisk) {
          final dir = Directory(comic.baseDir);
          if (dir.existsSync()) {
            shouldRemovedDirs.add(dir);
          }
        }
      }
      if (removeFileOnDisk) {
        shouldRemovedDirs = await _resolveDeletionDirectories(
          shouldRemovedDirs,
          excluding: comics,
        );
      }
      await _deletionJournal.run(
        shouldRemovedDirs,
        (markCommitted) => _deleteRecords(
          comics,
          removeFavoriteAndHistory,
          markCommitted: markCommitted,
          expectedSnapshot: snapshot,
        ),
      );
    } catch (e, s) {
      Log.error("LocalManager", "Failed to batch delete comics: $e", s);
      rethrow;
    }

    notifyListeners();
  }

  Future<void> _deleteRecords(
    List<LocalComic> comics,
    bool removeFavoriteAndHistory, {
    required void Function() markCommitted,
    required String expectedSnapshot,
  }) async {
    if (!removeFavoriteAndHistory) {
      runSqliteTransaction(_db, () {
        _validateDeletionSnapshot(expectedSnapshot);
        _repository.removeAll(comics);
        markCommitted();
      });
      for (final comic in comics) {
        _comicDirectories.remove((comic.id, comic.comicType.value));
      }
      return;
    }
    await _relatedData.deleteRecords(
      localDatabase: _db,
      comics: comics,
      markCommitted: markCommitted,
      validate: () {
        _checkNotDisposed();
        _validateDeletionSnapshot(expectedSnapshot);
      },
    );
    for (final comic in comics) {
      _comicDirectories.remove((comic.id, comic.comicType.value));
    }
  }

  void _validateDeletionSnapshot(String expected) {
    if (_repository.deletionSnapshot() != expected) {
      throw StateError(
        'Local library changed during deletion; retry the operation',
      );
    }
  }

  LocalDeletionJournal get _deletionJournal => LocalDeletionJournal(
    _db,
    exists: (value) async => Directory(value) is AndroidDirectory
        ? Directory(value).exists()
        : await FileSystemEntity.type(value, followLinks: false) !=
              FileSystemEntityType.notFound,
  );

  /// Resolve the proposed retained records before staging any directories.
  Future<List<Directory>> _resolveDeletionDirectories(
    List<Directory> directories, {
    List<LocalComic> excluding = const [],
    LocalComic? chapterOwner,
    List<String>? retainedChapters,
  }) async {
    if (directories.isEmpty) return const [];
    final retained = _repository.directoryReferences(
      excludingMany: excluding.map((comic) => (comic.id, comic.comicType)),
      excluding: chapterOwner == null
          ? null
          : (chapterOwner.id, chapterOwner.comicType),
    );
    final remainingChapters =
        retainedChapters ??
        (chapterOwner == null
            ? const <String>[]
            : find(
                    chapterOwner.id,
                    chapterOwner.comicType,
                  )?.downloadedChapters ??
                  const <String>[]);
    final paths = await resolveLocalDirectoriesToDelete(
      candidates: directories.map((directory) => directory.path),
      retained: [
        ...retained.map((directory) => _resolveComicDirectory(directory, path)),
        for (final chapter in remainingChapters)
          FilePath.join(
            chapterOwner!.baseDir,
            localChapterDirectoryName(chapter),
          ),
      ],
      libraryPath: path,
      // SAF document paths have provider identity, not native symlink APIs.
      resolvePath: (value) => Directory(value) is AndroidDirectory
          ? Future.value(value)
          : resolveLocalNativePath(value),
    );
    return paths.map(Directory.new).toList();
  }
}
