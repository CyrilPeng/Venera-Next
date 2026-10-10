import 'package:venera_next/foundation/operation_failure.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/file_selection.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/owned_dio_client.dart';

import 'comic_source_manager.dart';
import 'source_repositories.dart';
import 'source_mutation_failure.dart';
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
    this.selection,
  });

  final int id;
  String name;
  String? sourceKey;
  final String? url;
  final String fileName;
  final SourceRepository? repository;
  String? fileContents;
  final Future<Uint8List> Function()? readFile;
  final FileSelection? selection;
  bool replaceExisting = false;
  SourceInstallPhase phase = SourceInstallPhase.queued;
  String? error;
  String? errorSummary;
  Object? cause;
  StackTrace? stackTrace;
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

class _InstallationSelection {
  _InstallationSelection(this.file);
  final FileSelection file;
  final attempts = <Future<void>>{};
  final failures = <int, ({Object error, StackTrace stack})>{};
  Future<void>? releasing;
}

/// Immutable diagnostics survive row removal and later retry attempts.
class SourceInstallationAttemptFailure implements Exception {
  SourceInstallationAttemptFailure(
    Iterable<({int attempt, Object error, StackTrace stack})> failures,
  ) : failures = List.unmodifiable(failures);
  final List<({int attempt, Object error, StackTrace stack})> failures;
  @override
  String toString() =>
      'Source installation attempts failed: ${failures.map((failure) => '${failure.attempt}: ${failure.error}').join('; ')}';
}

/// Session-wide tasks outlive pages. Downloads overlap; the source manager
/// serializes commits with updates and reloads of the shared JS runtime.
class SourceInstallations implements Listenable {
  SourceInstallations({
    required this.manager,
    required this.repositories,
    required Dio Function() createClient,
  }) : _createClient = createClient;

  final ComicSourceManager manager;
  final SourceRepositories repositories;
  final Dio Function() _createClient;
  final _changes = _InstallationChanges();
  final _tasks = <SourceInstallTask>[];
  final _pending = <Future<void>>{};
  final _selections = <FileSelection, _InstallationSelection>{};
  final _selectionFailures =
      <FileSelection, ({Object error, StackTrace stack})>{};
  bool _changesDisposed = false;
  final _closeFailures = <({Object error, StackTrace stack})>[];
  bool _closed = false;
  Future<void>? _closing;
  int _nextId = 0;
  int _downloads = 0;
  static const _maxDownloads = 3;

  bool get isClosed => _closed;

  @override
  void addListener(VoidCallback listener) {
    if (!_closed) _changes.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) =>
      _changes.removeListener(listener);

  void _publish() {
    if (!_closed) AppDataOperations.instance.publish(_changes.publish);
  }

  void _checkOpen() {
    if (_closed) throw StateError('Source installations are closed');
  }

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
    _checkOpen();
    final existing = taskFor(sourceKey: entry.key, url: entry.url);
    if (existing?.active == true) return existing!;
    if (manager.find(entry.key) != null) {
      throw OperationFailure.message('This source is already installed.'.tl);
    }
    return _enqueue(
      name: entry.name,
      url: entry.url,
      sourceKey: entry.key,
      repository: repository,
    );
  }

  SourceInstallTask enqueueUrl(String url) {
    _checkOpen();
    url = SourceRepositories.normalizeUrl(url);
    final existing = taskFor(url: url);
    if (existing?.active == true) return existing!;
    return _enqueue(
      name: Uri.parse(url).pathSegments.lastOrNull ?? 'Source script'.tl,
      url: url,
    );
  }

  /// Install the script that was previewed, preserving its download origin.
  SourceInstallTask enqueuePreviewedScript({
    required String name,
    required String contents,
    String? url,
    Future<Uint8List> Function()? readFile,
    FileSelection? selection,
  }) {
    _checkOpen();
    if (url == null) {
      return enqueueFile(
        name,
        Uint8List.fromList(utf8.encode(contents)),
        readFile: readFile,
        selection: selection,
      );
    }
    url = SourceRepositories.normalizeUrl(url);
    final existing = taskFor(url: url);
    if (existing?.active == true) return existing!;
    return _enqueue(
      name: name,
      url: url,
      fileContents: contents,
      selection: selection,
    );
  }

  SourceInstallTask enqueueCatalogEntry(SourceCatalogEntry entry) {
    _checkOpen();
    final existing = taskFor(sourceKey: entry.key, url: entry.url);
    if (existing?.active == true) return existing!;
    if (manager.find(entry.key) != null) {
      throw OperationFailure.message('This source is already installed.'.tl);
    }
    return _enqueue(name: entry.name, url: entry.url, sourceKey: entry.key);
  }

  SourceInstallTask enqueueFile(
    String name,
    Uint8List bytes, {
    Future<Uint8List> Function()? readFile,
    FileSelection? selection,
  }) {
    _checkOpen();
    final contents = utf8.decode(bytes);
    for (final task in _tasks) {
      if (task.active &&
          task.url == null &&
          task.fileName == name &&
          task.fileContents == contents) {
        return task;
      }
    }
    return _enqueue(
      name: name,
      fileContents: contents,
      readFile: readFile,
      selection: selection,
    );
  }

  SourceInstallTask _enqueue({
    required String name,
    String? url,
    String? sourceKey,
    SourceRepository? repository,
    String? fileContents,
    Future<Uint8List> Function()? readFile,
    FileSelection? selection,
  }) {
    _checkOpen();
    if (selection != null && _selections.containsKey(selection)) {
      throw StateError('Selected file already belongs to an installation');
    }
    final task = SourceInstallTask._(
      id: _nextId++,
      name: name,
      url: url,
      sourceKey: sourceKey,
      repository: repository,
      fileContents: fileContents,
      readFile: selection?.readAsBytes ?? readFile,
      selection: selection,
      fileName: url == null
          ? name
          : Uri.parse(url).pathSegments.where((s) => s.isNotEmpty).lastOrNull ??
                'source.js',
    );
    if (selection != null) {
      _selections[selection] = _InstallationSelection(selection);
    }
    _tasks.add(task);
    _publish();
    scheduleMicrotask(_pump);
    return task;
  }

  void cancel(SourceInstallTask task) {
    if (!_tasks.contains(task) || !task.canCancel) return;
    task.phase = SourceInstallPhase.canceled;
    task._cancelToken.cancel();
    _publish();
    _pump();
  }

  bool canRetry(SourceInstallTask task) {
    if (_closed || !_tasks.contains(task) || !task.canRetry) return false;
    if (task.sourceKey != null && manager.find(task.sourceKey!) != null) {
      return false;
    }
    final existing = taskFor(sourceKey: task.sourceKey, url: task.url);
    return existing == task || existing?.active != true;
  }

  void retry(SourceInstallTask task) {
    if (!canRetry(task)) return;
    if (_closed) return;
    task.replaceExisting = false;
    task._attempt++;
    task._cancelToken = CancelToken();
    task.phase = SourceInstallPhase.queued;
    task.error = null;
    task.errorSummary = null;
    task.cause = task.stackTrace = null;
    task.received = task.total = 0;
    _publish();
    scheduleMicrotask(_pump);
  }

  bool canReplace(SourceInstallTask task) =>
      !_closed &&
      _tasks.contains(task) &&
      !task.active &&
      task.repository == null &&
      task.sourceKey != null &&
      manager.find(task.sourceKey!) != null &&
      taskFor(sourceKey: task.sourceKey, url: task.url)?.active != true &&
      (task.url != null || task.readFile != null || task.fileContents != null);

  void replace(SourceInstallTask task) {
    if (!canReplace(task)) return;
    if (_closed) return;
    task.replaceExisting = true;
    task._attempt++;
    task._cancelToken = CancelToken();
    task.phase = SourceInstallPhase.queued;
    task.error = task.errorSummary = null;
    task.cause = task.stackTrace = null;
    task.received = task.total = 0;
    _publish();
    scheduleMicrotask(_pump);
  }

  void clearFinished() {
    if (_closed) return;
    for (final task in _tasks.where((task) => !task.active).toList()) {
      _tasks.remove(task);
      final selection = task.selection;
      if (selection == null) continue;
      final done = Completer<void>();
      late final Future<void> settled;
      settled = done.future.whenComplete(() => _pending.remove(settled));
      _pending.add(settled);
      _releaseSelection(selection).then(done.complete);
    }
    _publish();
  }

  void _pump() {
    if (_closed) return;
    for (final task in _tasks.toList()) {
      if (_closed) break;
      if (_downloads >= _maxDownloads) break;
      if (task.phase != SourceInstallPhase.queued) continue;
      _downloads++;
      task.phase = SourceInstallPhase.downloading;
      final attempt = task._attempt;
      final selection = _selections[task.selection];
      final done = Completer<void>();
      late final Future<void> settled;
      settled = done.future.whenComplete(() {
        _pending.remove(settled);
        selection?.attempts.remove(settled);
      });
      // Register before calling injected file/network/manager callbacks.
      _pending.add(settled);
      selection?.attempts.add(settled);
      _download(task, attempt, task._cancelToken).then(
        done.complete,
        onError: (Object error, StackTrace stack) {
          _closeFailures.add((error: error, stack: stack));
          _recordSelectionFailure(task, attempt, error, stack);
          done.complete();
        },
      );
    }
    _publish();
  }

  Future<void> _download(
    SourceInstallTask task,
    int attempt,
    CancelToken token,
  ) async {
    OwnedDioClient? client;
    Object? cause;
    StackTrace? causeStack;
    String? js;
    try {
      if (token.isCancelled) return;
      if (task.url == null || task.fileContents != null) {
        js = task.readFile == null
            ? task.fileContents!
            : utf8.decode(await task.readFile!());
        // Reuse the preview once; a retry must fetch the server's latest script.
        if (task.url != null && task._attempt == attempt) {
          task.fileContents = null;
        }
      } else {
        client = OwnedDioClient(_createClient());
        if (token.isCancelled) return;
        final response = await client.dio.get<String>(
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
            if (changed) _publish();
          },
        );
        js = response.data!;
      }
    } catch (error, stack) {
      cause = error;
      causeStack = stack;
    } finally {
      // Logical download slots can be reused after cancellation; retired
      // adapters and file reads still belong to the registered full attempt.
      _downloads--;
      scheduleMicrotask(_pump);
      try {
        await client?.closeAndWait(cause: cause, stackTrace: causeStack);
      } catch (error, stack) {
        _closeFailures.add((error: error, stack: stack));
        cause = error;
        causeStack = stack;
      }
    }
    if (cause != null) {
      _recordSelectionFailure(task, attempt, cause, causeStack!);
    }
    if (token.isCancelled || task._attempt != attempt) return;
    if (cause != null) {
      _fail(task, cause, causeStack!);
      return;
    }
    task.phase = SourceInstallPhase.waiting;
    _publish();
    if (token.isCancelled || task._attempt != attempt) return;
    await _install(task, js!, attempt, token);
  }

  void _fail(SourceInstallTask task, Object error, StackTrace stack) {
    task.cause = error;
    task.stackTrace = stack;
    task.error = error.toString();
    task.errorSummary = _errorSummary(error);
    task.phase = SourceInstallPhase.failed;
    _publish();
  }

  void _recordSelectionFailure(
    SourceInstallTask task,
    int attempt,
    Object error,
    StackTrace stack,
  ) {
    _selections[task.selection]?.failures[attempt] = (
      error: error,
      stack: stack,
    );
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
      final existing = task.replaceExisting
          ? manager.find(task.sourceKey!)
          : null;
      if (task.replaceExisting) {
        if (existing == null) {
          throw OperationFailure.message('The source is no longer installed.');
        }
        await manager.replaceScript(
          existing,
          js,
          validate: () {
            if (token.isCancelled || task._attempt != attempt) {
              throw _InstallationCanceled();
            }
            task.phase = SourceInstallPhase.installing;
            _publish();
          },
        );
        task.phase = SourceInstallPhase.succeeded;
        task.name = manager.find(existing.key)?.name ?? existing.name;
        _publish();
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
              repositories.find(repository.id)?.url != repository.url) {
            throw OperationFailure.message(
              'Repository changed. Refresh the list and try again.'.tl,
            );
          }
          task.phase = SourceInstallPhase.installing;
          _publish();
        },
      );
      task.sourceKey = source.key;
      task.name = source.name;
      task.phase = SourceInstallPhase.succeeded;
      task.fileContents = null;
    } catch (error, stack) {
      // These failures can retain native resources or an unresolved mutation;
      // a finished/cleared row must not hide them from final application close.
      if (error is SourceMutationFailure) {
        _closeFailures.add((error: error, stack: stack));
      }
      _recordSelectionFailure(task, attempt, error, stack);
      if (token.isCancelled || task._attempt != attempt) return;
      if (error is SourceAlreadyInstalledException) task.sourceKey = error.key;
      _fail(task, error, stack);
      return;
    }
    _publish();
  }

  Future<void> closeAndWait() {
    final closing = _closing;
    if (closing != null) return closing;
    _closed = true;
    final done = Completer<void>();
    _closing = done.future;
    for (final task in _tasks) {
      cancel(task);
    }
    _drain().then(
      done.complete,
      onError: (Object error, StackTrace stack) {
        if (_selectionFailures.isNotEmpty) _closing = null;
        done.completeError(error, stack);
      },
    );
    return done.future;
  }

  Future<void> _releaseSelection(FileSelection selection) {
    final owner = _selections[selection];
    if (owner == null) return Future.value();
    return owner.releasing ??= _releaseOwnedSelection(owner);
  }

  Future<void> _releaseOwnedSelection(_InstallationSelection owner) async {
    // The read's own completion can precede the attempt's error handler and
    // installation. Join attempts, excluding release jobs to avoid a cycle.
    await Future<void>.value();
    while (owner.attempts.isNotEmpty) {
      await Future.wait(owner.attempts.toList());
    }
    final selection = owner.file;
    try {
      await selection.dispose();
      _selections.remove(selection);
      _selectionFailures.remove(selection);
    } catch (error, stack) {
      final attempts = owner.failures.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final causes = attempts
          .map(
            (entry) => (
              attempt: entry.key + 1,
              error: entry.value.error,
              stack: entry.value.stack,
            ),
          )
          .toList();
      _selectionFailures[selection] = (
        error: FileSelectionCleanupFailure(
          selection: selection,
          cleanupError: error,
          cleanupStack: stack,
          operationError: causes.isEmpty
              ? null
              : causes.length == 1
              ? causes.single.error
              : SourceInstallationAttemptFailure(causes),
          operationStack: causes.isEmpty ? null : causes.first.stack,
        ),
        stack: stack,
      );
      owner.releasing = null;
    }
  }

  Future<void> _drain() async {
    // Also avoid disposing ChangeNotifier inside a listener's synchronous
    // close call. Closed owners suppress publication immediately.
    await Future<void>.value();
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
    for (final selection in _selections.keys.toList()) {
      await _releaseSelection(selection);
    }
    if (!_changesDisposed) {
      _changesDisposed = true;
      _changes.dispose();
    }
    final failures = [..._closeFailures, ..._selectionFailures.values];
    if (failures.isNotEmpty) throw SourceInstallationCloseFailure(failures);
  }
}

class SourceInstallationCloseFailure implements Exception {
  SourceInstallationCloseFailure(
    Iterable<({Object error, StackTrace stack})> failures,
  ) : failures = List.unmodifiable(failures);

  final List<({Object error, StackTrace stack})> failures;
  @override
  String toString() =>
      'Source installation close failed: ${failures.map((failure) => failure.error).join('; ')}';
}

class _InstallationChanges extends ChangeNotifier {
  void publish() => notifyListeners();
}
