import 'local_comic_model.dart';
import 'local_repository.dart';
import 'local_chapter_storage.dart';
import 'local_deletion_paths.dart';
import 'download_task_store.dart';
import 'download_directory_allocator.dart';
import 'local_sort_type.dart';
export 'local_sort_type.dart';
export 'local_comic_model.dart';
import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/sqlite_connection.dart';
import 'download_task.dart';
import 'download_queue.dart';
import 'download_task_codec.dart';
import 'package:venera_next/foundation/file_interaction.dart';

import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/features/history/history.dart';

import 'local_storage_guard.dart';
import 'local_storage_migration.dart';

export 'local_comic_image.dart';

extension LocalComicFiles on LocalComic {
  File get coverFile => File(FilePath.join(baseDir, cover));

  String get baseDir => (directory.contains('/') || directory.contains('\\'))
      ? directory
      : FilePath.join(LocalManager().path, directory);
}

class LocalManager with ChangeNotifier {
  static LocalManager? _instance;

  @visibleForTesting
  static bool debugSkipComicSourceInit = false;

  @visibleForTesting
  static void resetForTesting() {
    try {
      _instance?.dispose();
    } catch (_) {
      // ignore cleanup failures in partially initialized tests
    }
    _instance = null;
    debugSkipComicSourceInit = false;
  }

  LocalManager._({
    Database Function(String)? openDatabase,
    Future<void> Function()? initializeSources,
  }) : _openDatabase = openDatabase ?? openSqliteDatabase,
       _initializeSources = initializeSources;

  @visibleForTesting
  factory LocalManager.forTesting({
    required Database Function(String) openDatabase,
    required Future<void> Function() initializeSources,
  }) => LocalManager._(
    openDatabase: openDatabase,
    initializeSources: initializeSources,
  );

  final Database Function(String) _openDatabase;
  final Future<void> Function()? _initializeSources;
  Future<void>? _initialization;
  Database? _database;
  bool _disposed = false;

  factory LocalManager() {
    return _instance ??= LocalManager._();
  }

  Database get _db =>
      _database ?? (throw StateError('Local manager is not initialized'));

  void _checkNotDisposed() {
    if (_disposed) throw StateError('Local manager is disposed');
  }

  /// path to the directory where all the comics are stored
  late String path;

  Directory get directory => Directory(path);

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
      return await runWithExclusiveStorage(() => _setNewPath(newPath));
    } on LocalComicStorageBusy catch (error) {
      return error.message.tl;
    }
  }

  /// Migration/recovery may not reinterpret directories owned by queued tasks.
  Future<T> runWithExclusiveStorage<T>(
    Future<T> Function() action,
  ) => LocalComicStorageGuard.instance.runExclusive(() async {
    if (downloadingTasks.isNotEmpty || _downloadQueue.isSuspended) {
      throw const LocalComicStorageBusy(
        'Wait for downloads to finish or cancel them before changing the local library.',
      );
    }
    final stopped = _downloadQueue.suspend(notify: false);
    try {
      await stopped;
      return await action();
    } finally {
      _downloadQueue.releaseSuspension(stopped, notify: false);
    }
  });

  Future<String?> _setNewPath(String newPath) async {
    try {
      final result =
          await LocalStorageMigration(
            copyContents: copyDirectoryIsolate,
            publishPath: (value) => path = value,
            reportCleanupError: (error, stack) => Log.error('IO', error, stack),
            canonicalPath: (directory) => directory is AndroidDirectory
                ? Future.value(directory.path)
                : directory.resolveSymbolicLinks(),
          ).migrate(
            source: directory,
            destination: Directory(newPath),
            pathFile: File(FilePath.join(App.dataPath, 'local_path')),
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

  Future<void> _checkPathValidation() async {
    var testFile = File(FilePath.join(path, 'venera_test'));
    try {
      testFile.createSync();
      testFile.deleteSync();
    } catch (e) {
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
      _database = null;
      try {
        database?.dispose();
      } catch (closeError, closeStack) {
        Log.error('LocalManager', closeError, closeStack);
      }
      _initialization = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> _initialize() async {
    _database = _openDatabase('${App.dataPath}/local.db');
    _repository.initialize();
    if (File(FilePath.join(App.dataPath, 'local_path')).existsSync()) {
      path = File(FilePath.join(App.dataPath, 'local_path')).readAsStringSync();
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
    await _checkPathValidation();
    _checkNotDisposed();
    _checkNoMedia();
    if (_initializeSources != null) {
      await _initializeSources();
    } else if (!debugSkipComicSourceInit) {
      await ComicSourceManager().ensureInit();
    }
    _checkNotDisposed();
    restoreDownloadingTasks();
  }

  String findValidId(ComicType type) => _repository.findValidId(type);

  Future<void> add(LocalComic comic, [String? id]) async {
    _repository.add(comic, id);
    notifyListeners();
  }

  void remove(String id, ComicType comicType, {bool notify = true}) {
    _repository.remove(id, comicType);
    if (notify) notifyListeners();
  }

  void removeComic(LocalComic comic) {
    remove(comic.id, comic.comicType);
  }

  LocalRepository get _repository => LocalRepository(_db);

  List<LocalComic> getComics(LocalSortType sortType) =>
      _repository.getComics(sortType);
  LocalComic? find(String id, ComicType comicType) =>
      _repository.find(id, comicType);
  List<LocalComic> getRecent() => _repository.getRecent();
  int get count => _repository.count;
  LocalComic? findByName(String name) => _repository.findByName(name);
  List<LocalComic> search(String keyword) => _repository.search(keyword);

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final database = _database;
    _database = null;
    super.dispose();
    database?.dispose();
  }

  Future<List<String>> getImages(String id, ComicType type, Object ep) async {
    if (ep is! String && ep is! int) {
      throw "Invalid ep";
    }
    var comic = find(id, type) ?? (throw "Comic Not Found");
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
  Future<void> migrateLegacyPageOrder(History history) async {
    if (history.type != ComicType.local) return;
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
        await HistoryManager().addHistory(history);
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

  bool isDownloaded(
    String id,
    ComicType type, [
    int? ep,
    ComicChapters? chapters,
  ]) {
    var comic = find(id, type);
    if (comic == null) return false;
    if (comic.chapters == null || ep == null) return true;
    if (chapters != null) {
      if (comic.chapters?.length != chapters.length) {
        // update
        add(
          LocalComic(
            id: comic.id,
            title: comic.title,
            subtitle: comic.subtitle,
            tags: comic.tags,
            directory: comic.directory,
            chapters: chapters,
            cover: comic.cover,
            comicType: comic.comicType,
            downloadedChapters: comic.downloadedChapters,
            createdAt: comic.createdAt,
          ),
        );
      }
    }
    return comic.downloadedChapters.contains(
      (chapters ?? comic.chapters)!.ids.elementAtOrNull(ep - 1),
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

  Future<DownloadDirectoryAllocation> allocateDownloadDirectory(
    String id,
    ComicType type,
    String name,
  ) => _downloadDirectories.allocate(id, type, name);

  void completeTask(DownloadTask task) => _downloadQueue.complete(task);

  void removeTask(DownloadTask task) => _downloadQueue.remove(task);

  bool get isDownloadResumePending => _downloadQueue.isResumePending;

  Future<void> cancelDownload(DownloadTask task) => _downloadQueue.cancel(task);

  void resumeDownload(DownloadTask task) => _downloadQueue.resume(task);

  Future<void> pauseDownload(DownloadTask task) => _downloadQueue.pause(task);

  Future<void> moveToFirst(DownloadTask task) =>
      _downloadQueue.moveToFirst(task);

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

  /// Completes when all task snapshots queued so far have finished writing.
  Future<void> get pendingDownloadTaskWrites =>
      _downloadTaskStore.pendingWrites;

  Future<void> saveCurrentDownloadingTasks() => _downloadTaskStore.save(
    FilePath.join(App.dataPath, 'downloading_tasks.json'),
    downloadingTasks.map((task) => task.toJson()),
  );

  /// Install a fully decoded paused snapshot during initialization/recovery.
  void restorePausedDownloads(Iterable<DownloadTask> tasks) =>
      _downloadQueue.restorePausedTasks(tasks);

  void restoreDownloadingTasks() {
    try {
      final tasks = _downloadTaskStore.restore(
        FilePath.join(App.dataPath, 'downloading_tasks.json'),
        downloadTaskFromJson,
      );
      if (tasks != null) {
        restorePausedDownloads(tasks);
      }
    } catch (error, stack) {
      Log.error('LocalManager', error, stack);
    }
  }

  void addTask(DownloadTask task) => _downloadQueue.add(task);

  Future<void> deleteComic(LocalComic c, [bool removeFileOnDisk = true]) =>
      runWithExclusiveStorage(() => _deleteComic(c, removeFileOnDisk));

  Future<void> _deleteComic(LocalComic c, bool removeFileOnDisk) async {
    final current = find(c.id, c.comicType);
    if (current == null) return;
    c = current;
    // Deleting a local comic means that it's no longer available, thus both favorite and history should be deleted.
    if (c.comicType == ComicType.local) {
      // Always queue deletion: an earlier progress write may still be pending.
      await HistoryManager().remove(c.id, c.comicType);
      var folders = LocalFavoritesManager().find(c.id, c.comicType);
      for (var f in folders) {
        LocalFavoritesManager().deleteComicWithId(f, c.id, c.comicType);
      }
    }
    remove(c.id, c.comicType);
    if (removeFileOnDisk) {
      await _deleteUnreferencedDirectories([Directory(c.baseDir)]);
    }
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
    _repository.removeChapters(c.id, c.comicType, chapters);
    final directories = localChapterDirectoriesToDelete(
      removed: chapters,
      retained: find(c.id, c.comicType)?.downloadedChapters ?? const [],
    );
    var shouldRemovedDirs = <Directory>[];
    for (final directory in directories) {
      var dir = Directory(FilePath.join(c.baseDir, directory));
      if (dir.existsSync()) {
        shouldRemovedDirs.add(dir);
      }
    }
    if (shouldRemovedDirs.isNotEmpty) {
      await _deleteUnreferencedDirectories(shouldRemovedDirs, chapterOwner: c);
    }
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
      _repository.removeAll(comics);
    } catch (e, s) {
      Log.error("LocalManager", "Failed to batch delete comics: $e", s);
      rethrow;
    }

    var comicIDs = comics.map((e) => ComicID(e.comicType, e.id)).toList();

    if (removeFavoriteAndHistory) {
      LocalFavoritesManager().batchDeleteComicsInAllFolders(comicIDs);
      await HistoryManager().batchDeleteHistories(comicIDs);
    }

    notifyListeners();

    if (removeFileOnDisk) {
      await _deleteUnreferencedDirectories(shouldRemovedDirs);
    }
  }

  /// Protect remaining registrations before handing paths to filesystem cleanup.
  Future<void> _deleteUnreferencedDirectories(
    List<Directory> directories, {
    LocalComic? chapterOwner,
  }) async {
    final retained = getComics(LocalSortType.name).where(
      (comic) =>
          chapterOwner == null ||
          comic.id != chapterOwner.id ||
          comic.comicType != chapterOwner.comicType,
    );
    final paths = localDirectoriesToDelete(
      candidates: directories.map((directory) => directory.path),
      retained: retained.map((comic) => comic.baseDir),
      libraryPath: path,
    );
    if (paths.isNotEmpty) {
      await _deleteDirectories(paths.map(Directory.new).toList());
    }
  }

  static Future<void> _deleteDirectories(List<Directory> directories) async {
    await Isolate.run(() async {
      await SAFTaskWorker().init();
      for (var dir in directories) {
        if (dir.existsSync()) {
          await dir.delete(recursive: true);
        }
      }
    });
  }
}
