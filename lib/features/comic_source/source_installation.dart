import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/app_dio.dart';

import 'comic_source_manager.dart';
import 'source.dart';
import 'source_repositories.dart';
import 'parser.dart';

enum SourceInstallPhase {
  queued,
  downloading,
  waiting,
  installing,
  succeeded,
  failed,
  canceled,
}

class SourceInstallTask {
  SourceInstallTask._({
    required this.id,
    required this.name,
    required this.url,
    required this.fileName,
    this.sourceKey,
    this.repository,
    this.fileContents,
    this.readFile,
  });

  final int id;
  String name;
  String? sourceKey;
  final String? url;
  final String fileName;
  final SourceRepository? repository;
  String? fileContents;
  final Future<Uint8List> Function()? readFile;
  bool replaceExisting = false;
  SourceInstallPhase phase = SourceInstallPhase.queued;
  String? error;
  String? errorSummary;
  int received = 0;
  int total = 0;
  CancelToken _cancelToken = CancelToken();
  int _attempt = 0;

  bool get active => switch (phase) {
    SourceInstallPhase.queued ||
    SourceInstallPhase.downloading ||
    SourceInstallPhase.waiting ||
    SourceInstallPhase.installing => true,
    _ => false,
  };
  bool get canCancel => active && phase != SourceInstallPhase.installing;
  bool get canRetry =>
      phase == SourceInstallPhase.failed ||
      phase == SourceInstallPhase.canceled;
  double? get progress => total > 0 ? (received / total).clamp(0.0, 1.0) : null;
  String get originLabel =>
      repository?.name ??
      (url == null ? 'Imported from file'.tl : 'Installed from link'.tl);

  String get statusLabel => switch (phase) {
    SourceInstallPhase.queued => 'Waiting to download'.tl,
    SourceInstallPhase.downloading =>
      progress == null
          ? 'Downloading source'.tl
          : 'Downloading source · @percent%'.tlParams({
              'percent': (progress! * 100).floor(),
            }),
    SourceInstallPhase.waiting => 'Waiting to install'.tl,
    SourceInstallPhase.installing => 'Installing source'.tl,
    SourceInstallPhase.succeeded => 'Installed'.tl,
    SourceInstallPhase.failed => 'Installation failed'.tl,
    SourceInstallPhase.canceled => 'Installation canceled'.tl,
  };
}

class _InstallationCanceled implements Exception {}

/// Session-wide tasks outlive pages. Downloads overlap; the source manager
/// serializes commits with updates and reloads of the shared JS runtime.
class SourceInstallations extends ChangeNotifier {
  SourceInstallations._() : _client = null, _manager = null;

  @visibleForTesting
  SourceInstallations.forTesting({
    required Dio client,
    required ComicSourceManager manager,
  }) : _client = client,
       _manager = manager;

  final Dio? _client;
  final ComicSourceManager? _manager;
  static final instance = SourceInstallations._();
  final _tasks = <SourceInstallTask>[];
  int _nextId = 0;
  int _downloads = 0;
  static const _maxDownloads = 3;

  List<SourceInstallTask> get tasks => List.unmodifiable(_tasks);
  int get activeCount => _tasks.where((t) => t.active).length;
  int get failureCount =>
      _tasks.where((t) => t.phase == SourceInstallPhase.failed).length;

  SourceInstallTask? taskFor({String? sourceKey, String? url}) {
    // Active tasks take priority over older completed attempts, including a
    // task started for the same key in a different repository.
    bool matches(SourceInstallTask task) =>
        (sourceKey != null && task.sourceKey == sourceKey) ||
        (url != null && task.url == url);
    final matching = _tasks.reversed.where(matches);
    for (final task in matching) {
      if (task.active) return task;
    }
    return matching.firstOrNull;
  }

  SourceInstallTask enqueueRepository(
    SourceRepository repository,
    SourceCatalogEntry entry,
  ) {
    final existing = taskFor(sourceKey: entry.key, url: entry.url);
    if (existing?.active == true) return existing!;
    if (ComicSource.find(entry.key) != null) {
      throw 'This source is already installed.'.tl;
    }
    return _enqueue(
      name: entry.name,
      url: entry.url,
      sourceKey: entry.key,
      repository: repository,
    );
  }

  SourceInstallTask enqueueUrl(String url) {
    url = SourceRepositories.normalizeUrl(url);
    final existing = taskFor(url: url);
    if (existing?.active == true) return existing!;
    return _enqueue(
      name: Uri.parse(url).pathSegments.lastOrNull ?? 'Source script'.tl,
      url: url,
    );
  }

  SourceInstallTask enqueueFile(
    String name,
    Uint8List bytes, {
    Future<Uint8List> Function()? readFile,
  }) {
    final contents = utf8.decode(bytes);
    for (final task in _tasks) {
      if (task.active &&
          task.url == null &&
          task.fileName == name &&
          task.fileContents == contents) {
        return task;
      }
    }
    return _enqueue(name: name, fileContents: contents, readFile: readFile);
  }

  SourceInstallTask _enqueue({
    required String name,
    String? url,
    String? sourceKey,
    SourceRepository? repository,
    String? fileContents,
    Future<Uint8List> Function()? readFile,
  }) {
    final task = SourceInstallTask._(
      id: _nextId++,
      name: name,
      url: url,
      sourceKey: sourceKey,
      repository: repository,
      fileContents: fileContents,
      readFile: readFile,
      fileName: url == null
          ? name
          : Uri.parse(url).pathSegments.where((s) => s.isNotEmpty).lastOrNull ??
                'source.js',
    );
    _tasks.add(task);
    notifyListeners();
    scheduleMicrotask(_pump);
    return task;
  }

  void cancel(SourceInstallTask task) {
    if (!task.canCancel) return;
    task.phase = SourceInstallPhase.canceled;
    task._cancelToken.cancel();
    notifyListeners();
    _pump();
  }

  bool canRetry(SourceInstallTask task) {
    if (!task.canRetry) return false;
    if (task.sourceKey != null && ComicSource.find(task.sourceKey!) != null) {
      return false;
    }
    final existing = taskFor(sourceKey: task.sourceKey, url: task.url);
    return existing == task || existing?.active != true;
  }

  void retry(SourceInstallTask task) {
    if (!canRetry(task)) return;
    task.replaceExisting = false;
    task._attempt++;
    task._cancelToken = CancelToken();
    task.phase = SourceInstallPhase.queued;
    task.error = null;
    task.errorSummary = null;
    task.received = task.total = 0;
    notifyListeners();
    scheduleMicrotask(_pump);
  }

  bool canReplace(SourceInstallTask task) =>
      !task.active &&
      task.repository == null &&
      task.sourceKey != null &&
      ComicSource.find(task.sourceKey!) != null &&
      taskFor(sourceKey: task.sourceKey, url: task.url)?.active != true &&
      (task.url != null || task.readFile != null || task.fileContents != null);

  void replace(SourceInstallTask task) {
    if (!canReplace(task)) return;
    task.replaceExisting = true;
    task._attempt++;
    task._cancelToken = CancelToken();
    task.phase = SourceInstallPhase.queued;
    task.error = task.errorSummary = null;
    task.received = task.total = 0;
    notifyListeners();
    scheduleMicrotask(_pump);
  }

  void clearFinished() {
    _tasks.removeWhere((task) => !task.active);
    notifyListeners();
  }

  void _pump() {
    for (final task in _tasks) {
      if (_downloads >= _maxDownloads) break;
      if (task.phase != SourceInstallPhase.queued) continue;
      _downloads++;
      task.phase = SourceInstallPhase.downloading;
      unawaited(_download(task, task._attempt, task._cancelToken));
    }
    notifyListeners();
  }

  Future<void> _download(
    SourceInstallTask task,
    int attempt,
    CancelToken token,
  ) async {
    Dio? dio;
    try {
      String js;
      if (task.url == null) {
        js = task.readFile == null
            ? task.fileContents!
            : utf8.decode(await task.readFile!());
      } else {
        dio = _client ?? AppDio();
        final response = await dio.get<String>(
          task.url!,
          cancelToken: token,
          options: Options(
            responseType: ResponseType.plain,
            headers: {'cache-time': 'no'},
          ),
          onReceiveProgress: (received, total) {
            if (task._attempt != attempt || token.isCancelled) return;
            // Notify at most once per percentage point for ordinary responses.
            final changed =
                total != task.total ||
                total <= 0 ||
                (received * 100 ~/ total) != (task.received * 100 ~/ total);
            task.received = received;
            task.total = total;
            if (changed) notifyListeners();
          },
        );
        js = response.data!;
      }
      if (token.isCancelled || task._attempt != attempt) return;
      task.phase = SourceInstallPhase.waiting;
      notifyListeners();
      unawaited(_install(task, js, attempt, token));
    } catch (error) {
      if (!token.isCancelled && task._attempt == attempt) {
        task.error = error.toString();
        task.errorSummary = _errorSummary(error);
        task.phase = SourceInstallPhase.failed;
        notifyListeners();
      }
    } finally {
      if (_client == null) dio?.close();
      _downloads--;
      _pump();
    }
  }

  String _errorSummary(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status != null) {
        return 'The source server returned HTTP @code. Try again later or check the source address.'
            .tlParams({'code': status});
      }
      return 'Could not download the source. Check your connection and try again.'
          .tl;
    }
    return 'The source could not be installed. View details for the reason.'.tl;
  }

  Future<void> _install(
    SourceInstallTask task,
    String js,
    int attempt,
    CancelToken token,
  ) async {
    try {
      final repository = task.repository;
      final manager = _manager ?? ComicSourceManager();
      final existing = task.replaceExisting
          ? ComicSource.find(task.sourceKey!)
          : null;
      if (task.replaceExisting) {
        if (existing == null) throw 'The source is no longer installed.';
        await manager.replaceScript(
          existing,
          js,
          validate: () {
            if (token.isCancelled || task._attempt != attempt) {
              throw _InstallationCanceled();
            }
            task.phase = SourceInstallPhase.installing;
            notifyListeners();
          },
        );
        task.phase = SourceInstallPhase.succeeded;
        task.name = ComicSource.find(existing.key)?.name ?? existing.name;
        notifyListeners();
        return;
      }
      final source = await manager.installScript(
        js: js,
        fileName: task.fileName,
        expectedKey: task.sourceKey,
        origin: SourceOrigin(
          kind: repository != null
              ? 'repository'
              : task.url == null
              ? 'file'
              : 'url',
          repositoryId: repository?.id,
          repositoryName: repository?.name,
          url: task.url,
        ),
        beforeInstall: () {
          if (token.isCancelled || task._attempt != attempt) {
            throw _InstallationCanceled();
          }
          if (repository != null &&
              SourceRepositories.instance.find(repository.id)?.url !=
                  repository.url) {
            throw 'Repository changed. Refresh the list and try again.'.tl;
          }
          task.phase = SourceInstallPhase.installing;
          notifyListeners();
        },
      );
      task.sourceKey = source.key;
      task.name = source.name;
      task.phase = SourceInstallPhase.succeeded;
      task.fileContents = null;
    } catch (error) {
      if (token.isCancelled || task._attempt != attempt) return;
      if (error is SourceAlreadyInstalledException) task.sourceKey = error.key;
      task.error = error.toString();
      task.errorSummary = _errorSummary(error);
      task.phase = SourceInstallPhase.failed;
    }
    notifyListeners();
  }
}
