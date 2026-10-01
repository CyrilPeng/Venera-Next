import 'local_chapter_storage.dart';
import 'package:venera_next/foundation/global_preference_store.dart';
import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/file_type.dart';
import 'package:venera_next/foundation/file_interaction.dart';

import 'download_task.dart';

class ImagesDownloadTask extends DownloadTask with _TransferSpeedMixin {
  final ComicSource source;

  final String comicId;

  /// comic details. If null, the comic details will be fetched from the source.
  ComicDetails? comic;

  /// chapters to download. If null, all chapters will be downloaded.
  final List<String>? chapters;

  @override
  String get id => comicId;

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  String? comicTitle;

  ImagesDownloadTask({
    required this.source,
    required this.comicId,
    this.comic,
    this.chapters,
    this.comicTitle,
    Stream<ImageDownloadProgress> Function(String, String)? loadThumbnail,
  }) : _loadThumbnail = loadThumbnail ?? ImageDownloader.loadThumbnail;

  final Stream<ImageDownloadProgress> Function(String, String) _loadThumbnail;
  StreamIterator<ImageDownloadProgress>? _thumbnail;

  @override
  void cancel() {
    final directoryPath = path;
    final manager = LocalManager();
    final removedChapters = List<String>.of(chapters ?? const []);
    _stopRun();
    manager.removeTask(this);
    if (directoryPath == null) return;
    final stopped = _pendingStops;
    _pendingStops =
        () async {
          if (stopped != null) await stopped;
          // Registration may change while transfer cancellation is draining.
          // Query the original manager only when cleanup is ready to run.
          final local = manager.find(id, comicType);
          if (local == null) {
            await Directory(directoryPath).deleteIgnoreError(recursive: true);
          } else {
            final removedDirectories = localChapterDirectoriesToDelete(
              removed: removedChapters,
              retained: local.downloadedChapters,
            );
            for (final directory in removedDirectories) {
              await Directory(
                FilePath.join(directoryPath, directory),
              ).deleteIgnoreError(recursive: true);
            }
          }
        }().catchError((Object error, StackTrace stack) {
          Log.error('Download', error, stack);
        });
  }

  Future<void>? _pendingStops;

  /// Drain image transfer cancellation and any directory cleanup already queued.
  Future<void> get pendingCleanup => _pendingStops ?? Future.value();

  @override
  String? get cover => _cover ?? comic?.cover;

  @override
  String get message => _message;

  @override
  void pause() {
    if (isPaused) return;
    _message = "Paused".tl;
    _stopRun();
    notifyListeners();
  }

  void _stopRun() {
    _runGeneration++;
    _isRunning = false;
    _currentSpeed = 0;
    _wakeRetryDelay();
    final pending = tasks.entries
        .where((entry) => !entry.value.isComplete)
        .toList();
    final thumbnail = _thumbnail;
    _thumbnail = null;
    if (pending.isNotEmpty || thumbnail != null) {
      final stops = [
        if (thumbnail != null) thumbnail.cancel(),
        ?_pendingStops,
        for (final entry in pending) entry.value.cancel(),
      ];
      _pendingStops = Future.wait(stops).then<void>((_) {}).catchError((
        Object error,
        StackTrace stack,
      ) {
        Log.error('Download', error, stack);
      });
      for (final entry in pending) {
        tasks.remove(entry.key);
      }
    }
    stopRecorder();
  }

  @override
  double get progress => _totalCount == 0 ? 0 : _downloadedCount / _totalCount;

  bool _isRunning = false;

  bool _isError = false;

  String _message = "Fetching comic info...".tl;

  String? _cover;

  /// All images to download, key is chapter name
  Map<String, List<String>>? _images;

  /// Downloaded image count
  int _downloadedCount = 0;

  /// Total image count
  int _totalCount = 0;

  /// Current downloading image index
  int _index = 0;

  /// Current downloading chapter, index of [_images]
  int _chapter = 0;

  var tasks = <int, _ImageDownloadWrapper>{};

  int get _maxConcurrentTasks =>
      GlobalPreferenceStore(appdata.settings).network.downloadThreads;

  int _runGeneration = 0;

  bool _isCurrentRun(int generation) =>
      _isRunning && generation == _runGeneration;

  Future<void>? _resumeFuture;

  @visibleForTesting
  Future<void>? get debugResumeFuture => _resumeFuture;

  Completer<void>? _retryDelayWakeup;

  void _wakeRetryDelay() {
    final wakeup = _retryDelayWakeup;
    if (wakeup != null && !wakeup.isCompleted) {
      wakeup.complete();
    }
  }

  Future<void> _waitRetryDelay(Duration duration) {
    final wakeup = Completer<void>();
    _retryDelayWakeup = wakeup;
    return Future.any<void>([
      Future<void>.delayed(duration),
      wakeup.future,
    ]).whenComplete(() {
      if (identical(_retryDelayWakeup, wakeup)) {
        _retryDelayWakeup = null;
      }
    });
  }

  Future<Res<T>> _runDownloadStepWithRetry<T>(
    int generation,
    Future<T> Function() task,
  ) {
    return _runWithRetry(
      task,
      delay: _waitRetryDelay,
      shouldContinue: () => _isCurrentRun(generation),
    );
  }

  void _scheduleTasks() {
    if (!_isRunning) return;
    final generation = _runGeneration;
    var images = _images![_images!.keys.elementAt(_chapter)]!;
    var downloading = 0;
    for (var i = _index; i < images.length; i++) {
      if (downloading >= _maxConcurrentTasks) {
        return;
      }
      if (tasks[i] != null) {
        if (!tasks[i]!.isComplete) {
          downloading++;
        }
        if (tasks[i]!.error == null) {
          continue;
        }
      }
      Directory saveTo;
      if (comic!.chapters != null) {
        saveTo = Directory(
          FilePath.join(
            path!,
            localChapterDirectoryName(_images!.keys.elementAt(_chapter)),
          ),
        );
        if (!saveTo.existsSync()) {
          saveTo.createSync(recursive: true);
        }
      } else {
        saveTo = Directory(path!);
      }
      var task = _ImageDownloadWrapper(
        this,
        _images!.keys.elementAt(_chapter),
        images[i],
        saveTo,
        i,
      );
      tasks[i] = task;
      task.wait().then((task) {
        if (task.isComplete && _isCurrentRun(generation)) {
          _scheduleTasks();
        }
      });
      downloading++;
    }
  }

  @override
  void resume() {
    if (_isRunning) return;
    final generation = ++_runGeneration;
    _resumeFuture = _resume(generation).catchError((
      Object error,
      StackTrace stack,
    ) {
      if (!_isCurrentRun(generation)) return;
      Log.error('Download', error, stack);
      // Snapshot/filesystem failures must stop prefetch and timers as well as
      // the main loop, while leaving the queued task available for retry.
      _setError('Error: $error');
    });
  }

  Future<void> _resume(int generation) async {
    _isError = false;
    _message = "Resuming...".tl;
    _isRunning = true;
    notifyListeners();
    final stopped = _pendingStops;
    if (stopped != null) {
      await stopped;
      if (identical(_pendingStops, stopped)) _pendingStops = null;
    }
    if (!_isCurrentRun(generation)) return;
    runRecorder();

    if (comic == null) {
      _message = "Fetching comic info...".tl;
      notifyListeners();
      var res = await _runDownloadStepWithRetry(generation, () async {
        var r = await source.loadComicInfo!(comicId);
        if (r.error) {
          throw r.errorMessage!;
        } else {
          return r.data;
        }
      });
      if (!_isCurrentRun(generation)) {
        return;
      }
      if (res.error) {
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        comic = res.data;
      }
    }

    if (path == null) {
      try {
        var dir = await LocalManager().findValidDirectory(
          comicId,
          comicType,
          comic!.title,
        );
        if (!_isCurrentRun(generation)) return;
        if (!(await dir.exists())) {
          await dir.create();
        }
        if (!_isCurrentRun(generation)) return;
        path = dir.path;
      } catch (e, s) {
        if (!_isCurrentRun(generation)) return;
        Log.error("Download", e.toString(), s);
        _setError("Error: $e");
        return;
      }
    }

    await LocalManager().saveCurrentDownloadingTasks();
    if (!_isCurrentRun(generation)) return;

    if (_cover == null) {
      _message = "Downloading cover...".tl;
      notifyListeners();
      var res = await _runDownloadStepWithRetry(generation, () async {
        Uint8List? data;
        final thumbnail = StreamIterator(
          _loadThumbnail(comic!.cover, source.key),
        );
        _thumbnail = thumbnail;
        try {
          while (await thumbnail.moveNext()) {
            if (!_isCurrentRun(generation)) return null;
            final progress = thumbnail.current;
            if (progress.imageBytes != null) data = progress.imageBytes;
          }
        } finally {
          await thumbnail.cancel();
          if (identical(_thumbnail, thumbnail)) _thumbnail = null;
        }
        // A stream may already have produced bytes when cancellation starts.
        // Never write those bytes into a canceled or replacement run's path.
        if (!_isCurrentRun(generation)) return null;
        if (data == null) {
          throw "Failed to download cover";
        }
        var fileType = detectFileType(data);
        var file = File(FilePath.join(path!, "cover${fileType.ext}"));
        file.writeAsBytesSync(data);
        return "file://${file.path}";
      });
      if (!_isCurrentRun(generation)) {
        return;
      }
      if (res.error) {
        Log.error("Download", res.errorMessage!);
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        _cover = res.data;
        notifyListeners();
      }
      await LocalManager().saveCurrentDownloadingTasks();
      if (!_isCurrentRun(generation)) return;
    }

    if (_images == null) {
      if (comic!.chapters == null) {
        _message = "Fetching image list...".tl;
        notifyListeners();
        var res = await _runDownloadStepWithRetry(generation, () async {
          var r = await source.loadComicPages!(comicId, null);
          if (r.error) {
            throw r.errorMessage!;
          } else {
            return r.data;
          }
        });
        if (!_isCurrentRun(generation)) {
          return;
        }
        if (res.error) {
          Log.error("Download", res.errorMessage!);
          _setError("Error: ${res.errorMessage}");
          return;
        } else {
          _images = {'': res.data};
          _totalCount = _images!['']!.length;
        }
      } else {
        final fetchedImages = <String, List<String>>{};
        var totalCount = 0;
        int cpCount = 0;
        int totalCpCount =
            chapters?.length ?? comic!.chapters!.allChapters.length;
        for (var i in comic!.chapters!.allChapters.keys) {
          if (chapters != null && !chapters!.contains(i)) {
            continue;
          }
          _message = "Fetching image list (@a/@b)...".tlParams({
            "a": cpCount,
            "b": totalCpCount,
          });
          notifyListeners();
          var res = await _runDownloadStepWithRetry(generation, () async {
            var r = await source.loadComicPages!(comicId, i);
            if (r.error) {
              throw r.errorMessage!;
            } else {
              return r.data;
            }
          });
          if (!_isCurrentRun(generation)) {
            return;
          }
          if (res.error) {
            Log.error("Download", res.errorMessage!);
            _setError("Error: ${res.errorMessage}");
            return;
          } else {
            fetchedImages[i] = res.data;
            totalCount += res.data.length;
            cpCount++;
          }
        }
        // Publish only a complete list owned by this run. A paused partial
        // fetch must not look ready to the next resume attempt.
        _images = fetchedImages;
        _totalCount = totalCount;
      }
      _message = "$_downloadedCount/$_totalCount";
      notifyListeners();
      await LocalManager().saveCurrentDownloadingTasks();
      if (!_isCurrentRun(generation)) return;
    }

    while (_chapter < _images!.length) {
      var images = _images![_images!.keys.elementAt(_chapter)]!;
      tasks.clear();
      while (_index < images.length) {
        _scheduleTasks();
        var task = tasks[_index]!;
        await task.wait();
        if (!_isCurrentRun(generation)) {
          return;
        }
        if (task.error != null) {
          Log.error("Download", task.error.toString());
          _setError("Error: ${task.error}");
          return;
        }
        _index++;
        _downloadedCount++;
        _message = "$_downloadedCount/$_totalCount";
        await LocalManager().saveCurrentDownloadingTasks();
        if (!_isCurrentRun(generation)) return;
      }
      _index = 0;
      _chapter++;
    }

    LocalManager().completeTask(this);
    _isRunning = false;
    stopRecorder();
  }

  @override
  void onNextSecond(Timer t) {
    notifyListeners();
    super.onNextSecond(t);
  }

  void _setError(String message) {
    _stopRun();
    _isError = true;
    _message = message;
    notifyListeners();
  }

  @override
  int get speed => currentSpeed;

  @override
  String get title => comic?.title ?? comicTitle ?? "Loading...";

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ImagesDownloadTask",
      "source": source.key,
      "comicId": comicId,
      "comic": comic?.toJson(),
      "chapters": chapters,
      "path": path,
      "cover": _cover,
      "images": _images,
      "downloadedCount": _downloadedCount,
      "totalCount": _totalCount,
      "index": _index,
      "chapter": _chapter,
    };
  }

  static ImagesDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ImagesDownloadTask") {
      return null;
    }

    Map<String, List<String>>? images;
    if (json["images"] != null) {
      images = {};
      for (var entry in json["images"].entries) {
        images[entry.key] = List<String>.from(entry.value);
      }
    }

    return ImagesDownloadTask(
        source: ComicSource.find(json["source"])!,
        comicId: json["comicId"],
        comic: json["comic"] == null
            ? null
            : ComicDetails.fromJson(json["comic"]),
        chapters: ListOrNull.from(json["chapters"]),
      )
      ..path = json["path"]
      .._cover = json["cover"]
      .._images = images
      .._downloadedCount = json["downloadedCount"]
      .._totalCount = json["totalCount"]
      .._index = json["index"]
      .._chapter = json["chapter"];
  }

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic!.id,
      title: title,
      subtitle: comic!.subTitle ?? '',
      tags: comic!.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: comic!.chapters,
      cover: File(_cover!.split("file://").last).name,
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: chapters ?? comic?.chapters?.ids.toList() ?? [],
      createdAt: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is ImagesDownloadTask) {
      return other.comicId == comicId && other.source.key == source.key;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(comicId, source.key);
}

Future<Res<T>> _runWithRetry<T>(
  Future<T> Function() task, {
  int retry = 3,
  Future<void> Function(Duration duration)? delay,
  bool Function()? shouldContinue,
}) async {
  final wait = delay ?? Future<void>.delayed;
  for (var i = 0; i < retry; i++) {
    if (shouldContinue?.call() == false) {
      return Res.error("Canceled");
    }
    try {
      return Res(await task());
    } catch (e) {
      if (i == retry - 1 || shouldContinue?.call() == false) {
        return Res.error(e.toString());
      }
      await wait(Duration(seconds: i + 1));
    }
  }
  throw UnimplementedError();
}

class _ImageDownloadWrapper {
  final ImagesDownloadTask task;

  final String chapter;

  final int index;

  final String image;

  final Directory saveTo;

  _ImageDownloadWrapper(
    this.task,
    this.chapter,
    this.image,
    this.saveTo,
    this.index,
  ) {
    start();
  }

  bool isComplete = false;

  String? error;

  bool isCancelled = false;

  StreamIterator<ImageDownloadProgress>? _imageIterator;

  Future<void>? _activeWrite;

  Future<void>? _cancellation;
  bool _cancellationDrained = false;

  Future<void> cancel() {
    if (_cancellation != null) return _cancellation!;
    isCancelled = true;
    final waitFutures = <Future<void>>[];
    final imageIterator = _imageIterator;
    if (imageIterator != null) {
      waitFutures.add(imageIterator.cancel().then<void>((_) {}));
    }
    final activeWrite = _activeWrite;
    if (activeWrite != null) {
      waitFutures.add(activeWrite.catchError((_) {}));
    }
    return _cancellation = Future.wait(waitFutures)
        .then<void>((_) {})
        .whenComplete(() {
          _cancellationDrained = true;
          _completeWaiters();
        });
  }

  var completers = <Completer<_ImageDownloadWrapper>>[];

  var retry = 3;

  void start() async {
    int lastBytes = 0;
    String? unsupportedMime;
    final imageIterator = StreamIterator(
      ImageDownloader.loadComicImageUnwrapped(
        image,
        task.source.key,
        task.comicId,
        chapter,
      ),
    );
    _imageIterator = imageIterator;
    try {
      while (await imageIterator.moveNext()) {
        final p = imageIterator.current;
        if (isCancelled) {
          return;
        }
        task.onData(p.currentBytes - lastBytes);
        lastBytes = p.currentBytes;
        if (p.imageBytes != null) {
          var fileType = detectFileType(p.imageBytes!);
          var fileName = "$index${fileType.ext}";
          if (!isComicImageFileName(fileName)) {
            unsupportedMime = fileType.mime;
            continue;
          }
          var file = saveTo.joinFile(fileName);
          final activeWrite = file
              .writeAsBytes(p.imageBytes!)
              .then<void>((_) {});
          _activeWrite = activeWrite;
          try {
            await activeWrite;
          } finally {
            if (identical(_activeWrite, activeWrite)) {
              _activeWrite = null;
            }
          }
          if (isCancelled) {
            return;
          }
          isComplete = true;
          _completeWaiters();
          await imageIterator.cancel();
          return;
        }
      }
      if (!isComplete && !isCancelled) {
        if (unsupportedMime != null) {
          throw "Unsupported image data: $unsupportedMime";
        }
        throw "Failed to download image";
      }
    } catch (e, s) {
      if (isCancelled) {
        return;
      }
      Log.error("Download", e.toString(), s);
      retry--;
      if (retry > 0) {
        start();
        return;
      }
      error = e.toString();
      _completeWaiters();
    } finally {
      if (identical(_imageIterator, imageIterator)) {
        _imageIterator = null;
      }
      if (isCancelled) {
        _completeWaiters();
      }
    }
  }

  Future<_ImageDownloadWrapper> wait() {
    if (isCancelled) {
      return _cancellation!.then((_) => this);
    }
    if (isComplete || error != null) {
      return Future.value(this);
    }
    var c = Completer<_ImageDownloadWrapper>();
    completers.add(c);
    return c.future;
  }

  void _completeWaiters() {
    if (isCancelled && !_cancellationDrained) return;
    for (var c in completers) {
      if (!c.isCompleted) {
        c.complete(this);
      }
    }
    completers.clear();
  }
}

abstract mixin class _TransferSpeedMixin {
  int _bytesSinceLastSecond = 0;

  int _currentSpeed = 0;

  int get currentSpeed => _currentSpeed;

  Timer? timer;

  void onData(int length) {
    if (timer == null) return;
    if (length < 0) {
      return;
    }
    _bytesSinceLastSecond += length;
  }

  void onNextSecond(Timer t) {
    _currentSpeed = _bytesSinceLastSecond;
    _bytesSinceLastSecond = 0;
  }

  void runRecorder() {
    if (timer != null) {
      timer!.cancel();
    }
    _bytesSinceLastSecond = 0;
    timer = Timer.periodic(const Duration(seconds: 1), onNextSecond);
  }

  void stopRecorder() {
    timer?.cancel();
    timer = null;
    _currentSpeed = 0;
    _bytesSinceLastSecond = 0;
  }
}
