import 'dart:async';
import 'dart:isolate';

import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/file_downloader.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'download_task.dart';

class ArchiveDownloadTask extends DownloadTask {
  final String archiveUrl;

  final ComicDetails comic;

  late ComicSource source;

  /// Download comic by archive url
  ///
  /// Currently only support zip file and comics without chapters
  ArchiveDownloadTask(
    this.archiveUrl,
    this.comic, {
    FileDownloader Function(String, String)? createDownloader,
    Future<void> Function(String, String)? extractArchive,
  }) : _createDownloader =
           createDownloader ?? ((url, path) => FileDownloader(url, path)),
       _extract = extractArchive ?? _extractArchive {
    source = ComicSource.find(comic.sourceKey)!;
  }

  final FileDownloader Function(String, String) _createDownloader;
  final Future<void> Function(String, String) _extract;
  FileDownloader? _downloader;
  int _generation = 0;
  Future<void>? _runFuture;
  Future<void>? _stopFuture;
  Future<void>? _cleanup;

  bool _isCurrent(int generation) => _isRunning && generation == _generation;

  Future<void> get pendingRun => _runFuture ?? Future.value();

  Future<void> get pendingCleanup =>
      Future.wait<void>([?_runFuture, ?_stopFuture, ?_cleanup]).then((_) {});

  void _stop() {
    _generation++;
    _isRunning = false;
    _speed = 0;
    final downloader = _downloader;
    _downloader = null;
    if (downloader != null) {
      _stopFuture = downloader.stop().catchError((
        Object error,
        StackTrace stack,
      ) {
        Log.error('Download', error, stack);
      });
    }
  }

  String _message = "Fetching comic info...".tl;

  bool _isRunning = false;

  bool _isError = false;

  void _setError(String message) {
    _stop();
    _isError = true;
    _message = message;
    notifyListeners();
    Log.error("Download", message);
  }

  @override
  void cancel() {
    final directoryPath = path;
    _stop();
    path = null;
    LocalManager().removeTask(this);
    final stopped = pendingCleanup;
    _cleanup =
        () async {
          await stopped;
          if (directoryPath != null) {
            await Directory(directoryPath).deleteIgnoreError(recursive: true);
          }
        }().catchError((Object error, StackTrace stack) {
          Log.error('Download', error, stack);
        });
  }

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  @override
  String? get cover => comic.cover;

  @override
  String get id => comic.id;

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  String get message => _message;

  int _currentBytes = 0;

  int _expectedBytes = 0;

  int _speed = 0;

  @override
  void pause() {
    _stop();
    _message = "Paused".tl;
    notifyListeners();
  }

  @override
  double get progress =>
      _expectedBytes == 0 ? 0 : _currentBytes / _expectedBytes;

  @override
  void resume() {
    if (_isRunning) return;
    final prior = pendingCleanup;
    final generation = ++_generation;
    _isRunning = true;
    _isError = false;
    _message = "Downloading...".tl;
    _runFuture = _resume(generation, prior).catchError((
      Object error,
      StackTrace stack,
    ) {
      if (!_isCurrent(generation)) return;
      Log.error('Download', error, stack);
      _setError('Error: $error');
    });
  }

  Future<void> _resume(int generation, Future<void> prior) async {
    // Native extraction cannot be interrupted; drain the previous run before
    // another run touches its archive or output directory.
    await prior;
    if (!_isCurrent(generation)) return;
    notifyListeners();
    if (!_isCurrent(generation)) return;
    if (path == null) {
      final dir = await LocalManager().findValidDirectory(
        comic.id,
        comicType,
        comic.title,
      );
      if (!_isCurrent(generation)) return;
      if (!(await dir.exists())) await dir.create();
      if (!_isCurrent(generation)) return;
      path = dir.path;
    }
    final outputPath = path!;
    final archiveFile = File(
      FilePath.join(App.dataPath, "archive_downloading.zip"),
    );
    Log.info("Download", "Downloading $archiveUrl");
    final downloader = _downloader = _createDownloader(
      archiveUrl,
      archiveFile.path,
    );
    var isDownloaded = false;
    await for (final status in downloader.start()) {
      if (!_isCurrent(generation)) return;
      _currentBytes = status.downloadedBytes;
      _expectedBytes = status.totalBytes;
      _message =
          "${bytesToReadableString(_currentBytes)}/${bytesToReadableString(_expectedBytes)}";
      _speed = status.bytesPerSecond;
      isDownloaded = status.isFinished;
      notifyListeners();
    }
    if (!_isCurrent(generation)) return;
    if (!isDownloaded) {
      _setError("Error: Download failed");
      return;
    }
    try {
      await _extract(archiveFile.path, outputPath);
    } catch (error) {
      if (_isCurrent(generation)) {
        _setError("Failed to extract archive: $error");
      }
      return;
    }
    if (!_isCurrent(generation)) return;
    await archiveFile.deleteIgnoreError();
    if (!_isCurrent(generation)) return;
    LocalManager().completeTask(this);
    _isRunning = false;
    _speed = 0;
  }

  static Future<void> _extractArchive(String archive, String outDir) async {
    var out = Directory(outDir);
    if (out is AndroidDirectory) {
      // Saf directory can't be accessed by native code.
      var cacheDir = FilePath.join(App.cachePath, "archive_downloading");
      Directory(cacheDir).forceCreateSync();
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, cacheDir);
      });
      await copyDirectoryIsolate(Directory(cacheDir), Directory(outDir));
      await Directory(cacheDir).deleteIgnoreError(recursive: true);
    } else {
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, outDir);
      });
    }
  }

  @override
  int get speed => _speed;

  @override
  String get title => comic.title;

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ArchiveDownloadTask",
      "archiveUrl": archiveUrl,
      "comic": comic.toJson(),
      "path": path,
    };
  }

  static ArchiveDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ArchiveDownloadTask") {
      return null;
    }
    return ArchiveDownloadTask(
      json["archiveUrl"],
      ComicDetails.fromJson(json["comic"]),
    )..path = json["path"];
  }

  String _findCover() {
    final files = sortedComicImageEntries(
      Directory(path!).listSync().whereType<File>(),
      nameOf: (file) => file.name,
    );
    final cover = findNamedComicCover(files, nameOf: (file) => file.name);
    return (cover ?? files.first).name;
  }

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic.id,
      title: title,
      subtitle: comic.subTitle ?? '',
      tags: comic.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: null,
      cover: _findCover(),
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: [],
      createdAt: DateTime.now(),
    );
  }
}
