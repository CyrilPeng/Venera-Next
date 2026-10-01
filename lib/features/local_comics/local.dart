import 'local_comic_model.dart';
import 'local_repository.dart';
import 'local_sort_type.dart';
export 'local_sort_type.dart';
export 'local_comic_model.dart';
import 'dart:async';
import 'dart:convert';
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
import 'package:venera_next/features/local_comics/download.dart';
import 'package:venera_next/foundation/file_interaction.dart';

import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/features/history/history.dart';

import 'local_storage_guard.dart';

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

  LocalManager._();

  factory LocalManager() {
    return _instance ??= LocalManager._();
  }

  late Database _db;

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
      return await LocalComicStorageGuard.instance.runExclusive(
        () => _setNewPath(newPath),
      );
    } on LocalComicStorageBusy catch (error) {
      return error.message.tl;
    }
  }

  Future<String?> _setNewPath(String newPath) async {
    var newDir = Directory(newPath);
    if (!await newDir.exists()) {
      return "Directory does not exist";
    }
    if (!await newDir.list().isEmpty) {
      return "Directory is not empty";
    }
    try {
      await copyDirectoryIsolate(directory, newDir);
      await File(
        FilePath.join(App.dataPath, 'local_path'),
      ).writeAsString(newPath);
    } catch (e, s) {
      Log.error("IO", e, s);
      return e.toString();
    }
    await directory.deleteContents(recursive: true);
    path = newPath;
    _checkNoMedia();
    return null;
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

  Future<void> init() async {
    _db = openSqliteDatabase('${App.dataPath}/local.db');
    _repository.initialize();
    if (File(FilePath.join(App.dataPath, 'local_path')).existsSync()) {
      path = File(FilePath.join(App.dataPath, 'local_path')).readAsStringSync();
      if (!directory.existsSync()) {
        path = await findDefaultPath();
      }
    } else {
      path = await findDefaultPath();
    }
    try {
      if (!directory.existsSync()) {
        await directory.create();
      }
    } catch (e, s) {
      Log.error("IO", "Failed to create local folder: $e", s);
    }
    await _checkPathValidation();
    _checkNoMedia();
    if (!debugSkipComicSourceInit) {
      await ComicSourceManager().ensureInit();
    }
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
    super.dispose();
    _db.dispose();
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
      cid = getChapterDirectoryName(cid);
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

  List<DownloadTask> downloadingTasks = [];

  bool isDownloading(String id, ComicType type) {
    return downloadingTasks.any(
      (element) => element.id == id && element.comicType == type,
    );
  }

  Future<Directory> findValidDirectory(
    String id,
    ComicType type,
    String name,
  ) async {
    var comic = find(id, type);
    if (comic != null) {
      return Directory(FilePath.join(path, comic.directory));
    }
    const comicDirectoryMaxLength = 80;
    if (name.length > comicDirectoryMaxLength) {
      name = name.substring(0, comicDirectoryMaxLength);
    }
    var dir = findValidDirectoryName(path, name);
    return Directory(FilePath.join(path, dir)).create().then((value) => value);
  }

  void completeTask(DownloadTask task) {
    add(task.toLocalComic());
    downloadingTasks.remove(task);
    notifyListeners();
    saveCurrentDownloadingTasks();
    downloadingTasks.firstOrNull?.resume();
  }

  void removeTask(DownloadTask task) {
    downloadingTasks.remove(task);
    notifyListeners();
    saveCurrentDownloadingTasks();
  }

  void moveToFirst(DownloadTask task) {
    if (downloadingTasks.first != task) {
      var shouldResume = !downloadingTasks.first.isPaused;
      downloadingTasks.first.pause();
      downloadingTasks.remove(task);
      downloadingTasks.insert(0, task);
      notifyListeners();
      saveCurrentDownloadingTasks();
      if (shouldResume) {
        downloadingTasks.first.resume();
      }
    }
  }

  Future<void> _downloadTaskWrites = Future.value();

  /// Completes when all task snapshots queued so far have finished writing.
  Future<void> get pendingDownloadTaskWrites => _downloadTaskWrites;

  Future<void> saveCurrentDownloadingTasks() {
    // Capture both path and snapshot before queuing: later mutations must not
    // change the meaning of an already requested save.
    final file = File(FilePath.join(App.dataPath, 'downloading_tasks.json'));
    final data = jsonEncode(downloadingTasks.map((e) => e.toJson()).toList());
    final write = _downloadTaskWrites.then((_) async {
      await file.writeAsString(data);
    });
    // Keep subsequent writes usable after a failure. Awaiting callers still
    // receive the original error through the returned future.
    _downloadTaskWrites = write.catchError((Object error, StackTrace stack) {
      Log.error('LocalManager', 'Failed to save download tasks: $error');
    });
    return write;
  }

  void restoreDownloadingTasks() {
    var file = File(FilePath.join(App.dataPath, 'downloading_tasks.json'));
    if (file.existsSync()) {
      try {
        var tasks = jsonDecode(file.readAsStringSync());
        for (var e in tasks) {
          var task = DownloadTask.fromJson(e);
          if (task != null) {
            downloadingTasks.add(task);
          }
        }
      } catch (e) {
        file.delete();
        Log.error("LocalManager", "Failed to restore downloading tasks: $e");
      }
    }
  }

  void addTask(DownloadTask task) {
    downloadingTasks.add(task);
    notifyListeners();
    saveCurrentDownloadingTasks();
    downloadingTasks.first.resume();
  }

  void deleteComic(LocalComic c, [bool removeFileOnDisk = true]) {
    if (removeFileOnDisk) {
      var dir = Directory(FilePath.join(path, c.directory));
      dir.deleteIgnoreError(recursive: true);
    }
    // Deleting a local comic means that it's no longer available, thus both favorite and history should be deleted.
    if (c.comicType == ComicType.local) {
      // Always queue deletion: an earlier progress write may still be pending.
      unawaited(HistoryManager().remove(c.id, c.comicType));
      var folders = LocalFavoritesManager().find(c.id, c.comicType);
      for (var f in folders) {
        LocalFavoritesManager().deleteComicWithId(f, c.id, c.comicType);
      }
    }
    remove(c.id, c.comicType);
  }

  void deleteComicChapters(LocalComic c, List<String> chapters) {
    if (chapters.isEmpty) {
      return;
    }
    _repository.removeChapters(c.id, c.comicType, chapters);
    var shouldRemovedDirs = <Directory>[];
    for (var chapter in chapters) {
      var dir = Directory(
        FilePath.join(c.baseDir, getChapterDirectoryName(chapter)),
      );
      if (dir.existsSync()) {
        shouldRemovedDirs.add(dir);
      }
    }
    if (shouldRemovedDirs.isNotEmpty) {
      _deleteDirectories(shouldRemovedDirs);
    }
    notifyListeners();
  }

  void batchDeleteComics(
    List<LocalComic> comics, [
    bool removeFileOnDisk = true,
    bool removeFavoriteAndHistory = true,
  ]) {
    if (comics.isEmpty) {
      return;
    }

    var shouldRemovedDirs = <Directory>[];
    try {
      for (final comic in comics) {
        if (removeFileOnDisk) {
          final dir = Directory(FilePath.join(path, comic.directory));
          if (dir.existsSync()) {
            shouldRemovedDirs.add(dir);
          }
        }
      }
      _repository.removeAll(comics);
    } catch (e, s) {
      Log.error("LocalManager", "Failed to batch delete comics: $e", s);
      return;
    }

    var comicIDs = comics.map((e) => ComicID(e.comicType, e.id)).toList();

    if (removeFavoriteAndHistory) {
      LocalFavoritesManager().batchDeleteComicsInAllFolders(comicIDs);
      unawaited(HistoryManager().batchDeleteHistories(comicIDs));
    }

    notifyListeners();

    if (removeFileOnDisk) {
      _deleteDirectories(shouldRemovedDirs);
    }
  }

  /// Deletes the directories in a separate isolate to avoid blocking the UI thread.
  static void _deleteDirectories(List<Directory> directories) {
    Isolate.run(() async {
      await SAFTaskWorker().init();
      for (var dir in directories) {
        try {
          if (dir.existsSync()) {
            await dir.delete(recursive: true);
          }
        } catch (e) {
          continue;
        }
      }
    });
  }

  static String getChapterDirectoryName(String name) {
    var builder = StringBuffer();
    for (var i = 0; i < name.length; i++) {
      var char = name[i];
      if (char == '/' ||
          char == '\\' ||
          char == ':' ||
          char == '*' ||
          char == '?' ||
          char == '"' ||
          char == '<' ||
          char == '>' ||
          char == '|') {
        builder.write('_');
      } else {
        builder.write(char);
      }
    }
    return builder.toString();
  }
}
