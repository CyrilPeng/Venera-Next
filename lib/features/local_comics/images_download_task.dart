import 'package:venera_next/foundation/operation_failure.dart';
import 'local_chapter_storage.dart';
import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'dart:async';
import 'package:path/path.dart' as p;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'download_task_storage.dart';
import 'local_comic_model.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/file_type.dart';
import 'package:venera_next/foundation/file_interaction.dart';

import 'download_task.dart';
import 'download_directory_allocator.dart';
import 'download_retry.dart';

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
    required DownloadTaskStorage storage,
    required this.source,
    required this.comicId,
    this.comic,
    this.chapters,
    this.comicTitle,
    bool? skipUnavailableImages,
    Stream<ImageDownloadProgress> Function(String, String)? loadThumbnail,
    ComicImageLoader? loadImage,
    Future<DownloadDirectoryAllocation> Function(String, ComicType, String)?
    allocateDirectory,
  }) : skipUnavailableImages =
           skipUnavailableImages ??
           GlobalPreferenceStore(
             appdata.settings,
           ).read(NetworkPreferences.skipUnavailableDownloadImages),
       _storage = storage,
       _loadThumbnail = loadThumbnail ?? ImageDownloader.loadThumbnail,
       _loadImage = loadImage ?? ImageDownloader.loadComicImageUnwrapped,
       _allocateDirectory = allocateDirectory;

  final Stream<ImageDownloadProgress> Function(String, String) _loadThumbnail;
  final ComicImageLoader _loadImage;
  StreamIterator<ImageDownloadProgress>? _thumbnail;
  final Future<DownloadDirectoryAllocation> Function(String, ComicType, String)?
  _allocateDirectory;
  Future<void>? _allocationFuture;
  String? _ownedOutputPath;
  final DownloadTaskStorage _storage;

  bool skipUnavailableImages;
  bool _awaitingMissingPages = false;

  @override
  bool get isAwaitingMissingPages => _awaitingMissingPages;

  @override
  void prepareMissingPageRetry() => _awaitingMissingPages = false;
  final _missingImages = <String, Set<int>>{};
  int get missingImageCount =>
      _missingImages.values.fold(0, (count, pages) => count + pages.length);

  Future<void> updateSkipUnavailableImages(bool value) async {
    skipUnavailableImages = value;
    notifyListeners();
    await _storage.saveCurrentDownloadingTasks();
  }

  _ImageDownloadWrapper _createImageTask(String chapter, int index) {
    final directory = Directory(
      comic!.chapters == null
          ? path!
          : FilePath.join(path!, localChapterDirectoryName(chapter)),
    );
    if (!directory.existsSync()) directory.createSync(recursive: true);
    return _ImageDownloadWrapper(
      this,
      chapter,
      _images![chapter]![index],
      directory,
      index,
    );
  }

  String get _progressMessage => missingImageCount == 0
      ? '$_downloadedCount/$_totalCount'
      : 'Downloaded @a/@b; missing @c images'.tlParams({
          'a': _downloadedCount,
          'b': _totalCount,
          'c': missingImageCount,
        });

  Future<bool> _retryMissingImages(int generation) async {
    // Retry only missing pages; completed files and chapter cursors stay intact.
    final missing = [
      for (final entry in _missingImages.entries)
        for (final index in entry.value) (entry.key, index),
    ];
    for (final (chapter, index) in missing) {
      final task = tasks[index] = _createImageTask(chapter, index);
      await task.wait();
      if (!_isCurrentRun(generation)) return false;
      tasks.remove(index);
      if (task.error != null) {
        if (!skipUnavailableImages || !task.canSkip) {
          _setError('Error: ${task.error}');
          return false;
        }
      } else {
        _missingImages[chapter]!.remove(index);
        if (_missingImages[chapter]!.isEmpty) _missingImages.remove(chapter);
        _downloadedCount++;
      }
      _message = _progressMessage;
      notifyListeners();
      await _storage.saveCurrentDownloadingTasks();
      if (!_isCurrentRun(generation)) return false;
    }
    return true;
  }

  Future<void> _allocateOutput() async {
    final manager = _storage;
    final allocation =
        await (_allocateDirectory ?? manager.allocateDownloadDirectory)(
          comicId,
          comicType,
          comic!.title,
        );
    final directory = allocation.directory;
    if (allocation.isNew) _ownedOutputPath = directory.path;
    if (!await directory.exists()) await directory.create();
    // Pause/resume and cancellation drain this operation before reusing or
    // cleaning its result, including a result returned after pause/cancel.
    path = directory.path;
  }

  @override
  void cancel() {
    final directoryPath = path;
    final manager = _storage;
    final removedChapters = List<String>.of(chapters ?? const []);
    _stopRun();
    manager.removeTask(this);
    if (directoryPath == null &&
        _allocationFuture == null &&
        _ownedOutputPath == null) {
      return;
    }
    final stopped = _pendingStops;
    _pendingStops =
        () async {
          if (stopped != null) await stopped;
          // Registration may change while transfer cancellation is draining.
          // Query the original manager only when cleanup is ready to run.
          final cleanupPath = _ownedOutputPath ?? directoryPath ?? path;
          if (cleanupPath == null) return;
          final local = manager.find(id, comicType);
          if (local == null) {
            if (_ownedOutputPath != cleanupPath) return;
            final directory = Directory(cleanupPath);
            if (await directory.exists()) {
              await directory.delete(recursive: true);
            }
          } else if (p.equals(
            p.absolute(FilePath.join(manager.path, local.directory)),
            p.absolute(cleanupPath),
          )) {
            final removedDirectories = localChapterDirectoriesToDelete(
              removed: removedChapters,
              retained: local.downloadedChapters,
            );
            for (final directory in removedDirectories) {
              await Directory(
                FilePath.join(cleanupPath, directory),
              ).deleteIgnoreError(recursive: true);
            }
          }
          if (path == cleanupPath) path = null;
          _ownedOutputPath = null;
        }().catchError((Object error, StackTrace stack) {
          Log.error('Download', error, stack);
        });
  }

  Future<void>? _pendingStops;

  /// Drain image transfer cancellation and any directory cleanup already queued.
  @override
  Future<void> get pendingCleanup => _pendingStops ?? Future.value();

  @override
  String? get cover => _cover ?? comic?.cover;

  @override
  String get message => isAwaitingMissingPages
      ? _incompleteMessage
      : isWaitingToRetry
      ? 'Connection interrupted. Waiting to retry...'.tl
      : _message;

  String get _incompleteMessage => [
    'Waiting for missing pages. Downloaded pages are available in the local library.'
        .tl,
    _progressMessage,
    for (final entry in _missingImages.entries)
      '${comic!.chapters?.allChapters[entry.key] ?? title}: ${entry.value.map((index) => index + 1).join(', ')}',
  ].join('\n');

  DownloadRetry? _retry;

  @override
  bool get isWaitingToRetry => _isRunning && (_retry?.isWaiting ?? false);

  @override
  void retryNow() {
    if (_isRunning) _retry?.wake();
  }

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
    _retry?.cancel();
    final pending = tasks.entries
        .where((entry) => !entry.value.isComplete)
        .toList();
    final thumbnail = _thumbnail;
    _thumbnail = null;
    if (pending.isNotEmpty || thumbnail != null || _allocationFuture != null) {
      final stops = [
        ?_allocationFuture,
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

  Future<Res<T>> _runDownloadStepWithRetry<T>(
    int generation,
    Future<T> Function() task,
  ) async {
    try {
      if (!_isCurrentRun(generation)) {
        throw OperationFailure.message('Canceled', kind: FailureKind.cancelled);
      }
      return Res(await _retry!.run(task, retryUnknown: true));
    } catch (error, stack) {
      return Res.fromException(error, stack);
    }
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
        // The main loop owns exhausted failures. Prefetch completion must not
        // recreate a failed wrapper and silently reset its retry budget.
        continue;
      }
      var task = _createImageTask(_images!.keys.elementAt(_chapter), i);
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
    _awaitingMissingPages = false;
    final generation = ++_runGeneration;
    _retry = DownloadRetry(
      isActive: () => _isCurrentRun(generation),
      onWaitingChanged: () {
        if (_isCurrentRun(generation)) notifyListeners();
      },
    );
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
        return r.data;
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
        final allocation = _allocationFuture = _allocateOutput();
        try {
          await allocation;
        } finally {
          if (identical(_allocationFuture, allocation)) {
            _allocationFuture = null;
          }
        }
        if (!_isCurrentRun(generation)) return;
      } catch (e, s) {
        if (!_isCurrentRun(generation)) return;
        Log.error("Download", e.toString(), s);
        _setError("Error: $e");
        return;
      }
    }

    await _storage.saveCurrentDownloadingTasks();
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
          throw OperationFailure.message("Failed to download cover");
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
      await _storage.saveCurrentDownloadingTasks();
      if (!_isCurrentRun(generation)) return;
    }

    if (_images == null) {
      if (comic!.chapters == null) {
        _message = "Fetching image list...".tl;
        notifyListeners();
        var res = await _runDownloadStepWithRetry(generation, () async {
          var r = await source.loadComicPages!(comicId, null);
          return r.data;
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
            return r.data;
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
      await _storage.saveCurrentDownloadingTasks();
      if (!_isCurrentRun(generation)) return;
    }

    tasks.clear();
    if (!await _retryMissingImages(generation)) return;
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
          if (!skipUnavailableImages || !task.canSkip) {
            _setError("Error: ${task.error}");
            return;
          }
          (_missingImages[_images!.keys.elementAt(_chapter)] ??= {}).add(
            _index,
          );
        } else {
          _downloadedCount++;
        }
        _index++;
        _message = _progressMessage;
        notifyListeners();
        await _storage.saveCurrentDownloadingTasks();
        if (!_isCurrentRun(generation)) return;
      }
      _index = 0;
      _chapter++;
    }

    if (missingImageCount > 0) {
      _stopRun();
      _awaitingMissingPages = true;
      try {
        _storage.retainIncompleteTask(this);
        _ownedOutputPath = null;
      } catch (error, stack) {
        _awaitingMissingPages = false;
        Log.error('Download', error, stack);
        _setError('Error: $error');
        return;
      }
      notifyListeners();
      return;
    }
    _storage.completeTask(this);
    _ownedOutputPath = null;
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
      "skipUnavailableImages": skipUnavailableImages,
      'awaitingMissingPages': _awaitingMissingPages,
      "missingImages": {
        for (final entry in _missingImages.entries)
          entry.key: entry.value.toList(),
      },
    };
  }

  static ImagesDownloadTask? fromJson(
    DownloadTaskStorage storage,
    Map<String, dynamic> json, {
    ComicImageLoader? loadImage,
  }) {
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

    final task =
        ImagesDownloadTask(
            storage: storage,
            loadImage: loadImage,
            source: ComicSource.find(json["source"])!,
            comicId: json["comicId"],
            skipUnavailableImages: json['skipUnavailableImages'] == true,
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
    final missing = json['missingImages'];
    if (missing is Map && images != null) {
      for (final entry in missing.entries) {
        final pages = images[entry.key];
        if (pages == null || entry.value is! List) continue;
        final indices = (entry.value as List)
            .whereType<int>()
            .where((index) => index >= 0 && index < pages.length)
            .toSet();
        if (indices.isNotEmpty) {
          task._missingImages[entry.key as String] = indices;
        }
      }
    }
    task._awaitingMissingPages =
        json['awaitingMissingPages'] == true &&
        task.missingImageCount > 0 &&
        images != null &&
        task._chapter >= images.length;
    return task;
  }

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  void dispose() {
    _stopRun();
    super.dispose();
  }

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
      incompleteChapters: Map.unmodifiable({
        for (final entry in _missingImages.entries)
          entry.key: IncompleteChapter(
            pageCount: _images![entry.key]!.length,
            missing: entry.value,
          ),
      }),
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
  bool canSkip = false;

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

  void start() async {
    try {
      await task._retry!.run(_download, retryUnknown: true);
    } catch (e, s) {
      if (isCancelled) return;
      Log.error('Download', e, s);
      error = e.toString();
      canSkip = canSkipUnavailableDownloadImage(e);
      _completeWaiters();
    }
  }

  Future<void> _download() async {
    int lastBytes = 0;
    String? unsupportedMime;
    final imageIterator = StreamIterator(
      task._loadImage(image, task.source.key, task.comicId, chapter),
    );
    _imageIterator = imageIterator;
    try {
      while (await imageIterator.moveNext()) {
        final progress = imageIterator.current;
        if (isCancelled) {
          return;
        }
        task.onData(progress.currentBytes - lastBytes);
        lastBytes = progress.currentBytes;
        if (progress.imageBytes != null) {
          final uri = Uri.tryParse(image);
          final imagePath = uri?.path ?? image.split('?').first;
          final fallbackExtension = p.extension(imagePath);
          var fileType = detectFileType(
            progress.imageBytes!,
            fallbackExtension: fallbackExtension.isEmpty
                ? null
                : fallbackExtension,
          );
          var fileName = "$index${fileType.ext}";
          if (!isComicImageFileName(fileName)) {
            unsupportedMime = fileType.mime;
            continue;
          }
          var file = saveTo.joinFile(fileName);
          final activeWrite = file
              .writeAsBytes(progress.imageBytes!)
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
          await imageIterator.cancel();
          if (isCancelled) return;
          isComplete = true;
          _completeWaiters();
          return;
        }
      }
      if (!isComplete && !isCancelled) {
        if (unsupportedMime != null) {
          throw OperationFailure.message(
            "Unsupported image data: $unsupportedMime",
            kind: FailureKind.unsupported,
          );
        }
        throw OperationFailure.message("Failed to download image");
      }
    } finally {
      // Release the failed request before a retry opens another connection.
      await imageIterator.cancel();
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
