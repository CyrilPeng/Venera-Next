import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'directory_selection.dart';
import 'file_selection.dart';

class SelectionCancelled implements Exception {
  const SelectionCancelled();
  @override
  String toString() => 'Selection cancelled';
}

/// Owns one picker/consumer operation, including selections returned after
/// cancellation. Closing joins the actual operation; retry only releases its
/// remaining handles and never repeats a picker, import or committed write.
class SelectionOperation {
  SelectionOperation({void Function()? checkActive})
    : _checkActive = checkActive;

  final void Function()? _checkActive;
  final _resources = <Object, Future<void> Function()>{};
  final _settled = Completer<void>();
  bool _started = false;
  bool _cancelled = false;
  bool _finished = false;
  Future<void>? _releasing;
  Object? _operationError;
  StackTrace? _operationStack;
  SelectionCleanupFailure? _cleanupFailure;

  Future<void> get settled => _settled.future;
  bool get hasPendingCleanup => _resources.isNotEmpty;
  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void checkActive() {
    if (_cancelled || _finished) throw const SelectionCancelled();
    _checkActive?.call();
  }

  Future<T> run<T>(Future<T> Function(SelectionOperation) action) {
    if (_started) throw StateError('Selection operation already started');
    _started = true;
    return Future<T>.microtask(() async {
      try {
        checkActive();
        return await action(this);
      } catch (error, stack) {
        _operationError = error;
        _operationStack = stack;
        rethrow;
      } finally {
        try {
          await _release();
        } finally {
          _finished = true;
          _settled.complete();
        }
      }
    });
  }

  Future<FileSelection?> pickFile(
    Future<FileSelection?> Function() pick,
  ) async {
    checkActive();
    final selection = await pick();
    if (selection != null) _resources[selection] = selection.dispose;
    checkActive();
    return selection;
  }

  Future<List<FileSelection>> pickFiles(
    Future<List<FileSelection>> Function() pick,
  ) async {
    checkActive();
    final selections = List<FileSelection>.of(await pick());
    for (final selection in selections) {
      _resources[selection] = selection.dispose;
    }
    checkActive();
    return List.unmodifiable(selections);
  }

  Future<DirectorySelection?> pickDirectory(
    Future<DirectorySelection?> Function() pick,
  ) async {
    checkActive();
    final selection = await pick();
    if (selection != null) _resources[selection] = selection.dispose;
    checkActive();
    return selection;
  }

  Future<T> useFile<T>(
    FileSelection selection,
    Future<T> Function(File) consume,
  ) {
    checkActive();
    if (!_resources.containsKey(selection)) {
      throw StateError('File does not belong to this selection operation');
    }
    return selection.withFile((file) {
      checkActive();
      return consume(file);
    });
  }

  Future<T> useDirectory<T>(
    DirectorySelection selection,
    Future<T> Function(Directory) consume,
  ) {
    checkActive();
    if (!_resources.containsKey(selection)) {
      throw StateError('Directory does not belong to this selection operation');
    }
    return selection.withDirectory((directory) {
      checkActive();
      return consume(directory);
    });
  }

  /// Owns a private working copy for consumers that require a writable file.
  /// The copy is registered before preparation and survives failed cleanup;
  /// closing retries only its release, never the consumer or the copy itself.
  Future<T> useFileCopy<T>(
    FileSelection selection, {
    required Directory cacheDirectory,
    required Future<T> Function(File) consume,
  }) => useFile(selection, (source) async {
    return useTemporaryFile(
      cacheDirectory: cacheDirectory,
      filename: selection.name,
      prepare: (file) async {
        await source.copy(file.path);
      },
      consume: consume,
    );
  });

  Future<T> useTemporaryFile<T>({
    required Directory cacheDirectory,
    required String filename,
    required Future<void> Function(File) prepare,
    required Future<T> Function(File) consume,
  }) {
    checkActive();
    final name = p.windows.basename(p.posix.basename(filename));
    if (name.isEmpty || name == '.' || name == '..') {
      throw const FormatException('Invalid selected file name');
    }
    return useTemporaryDirectory(
      cacheDirectory: cacheDirectory,
      prepare: (directory) => prepare(File(p.join(directory.path, name))),
      consume: (directory) => consume(File(p.join(directory.path, name))),
    );
  }

  Future<T> useTemporaryDirectory<T>({
    required Directory cacheDirectory,
    Future<void> Function(Directory)? prepare,
    required Future<T> Function(Directory) consume,
  }) {
    checkActive();
    final directory = DirectorySelection.temporary(
      cacheDirectory: cacheDirectory,
      prepare: (directory) async {
        checkActive();
        await prepare?.call(directory);
      },
    );
    _resources[directory] = directory.dispose;
    return useDirectory(directory, consume);
  }

  /// The receiver must either accept all handles synchronously or throw before
  /// accepting any. The operation remains registered throughout reentrant calls.
  T transferFiles<T>(List<FileSelection> files, T Function() accept) {
    checkActive();
    if (files.any((file) => !_resources.containsKey(file))) {
      throw StateError('Cannot transfer an unowned selection');
    }
    final result = accept();
    for (final file in files) {
      _resources.remove(file);
    }
    return result;
  }

  Future<void> closeAndWait() async {
    cancel();
    final wasRunning = _started && !_finished;
    if (_started) await settled;
    // Report a failed release from this drain before a later close retries it.
    if (wasRunning && _cleanupFailure != null) throw _cleanupFailure!;
    await _release();
  }

  Future<void> _release() {
    final pending = _releasing;
    if (pending != null) return pending;
    final done = Completer<void>();
    _releasing = done.future;
    Future<void>.sync(() async {
      final failures = <Object>[];
      for (final entry in _resources.entries.toList().reversed) {
        try {
          await entry.value();
          _resources.remove(entry.key);
        } catch (error, stack) {
          failures.add(switch (entry.key) {
            FileSelection selection => FileSelectionCleanupFailure(
              selection: selection,
              cleanupError: error,
              cleanupStack: stack,
              operationError: _operationError,
              operationStack: _operationStack,
            ),
            DirectorySelection selection => DirectorySelectionCleanupFailure(
              selection: selection,
              cleanupError: error,
              cleanupStack: stack,
              operationError: _operationError,
              operationStack: _operationStack,
            ),
            _ => StateError('Unknown selection resource'),
          });
        }
      }
      _cleanupFailure = failures.isEmpty
          ? null
          : SelectionCleanupFailure(
              failures,
              operationError: _operationError,
              operationStack: _operationStack,
            );
      if (_cleanupFailure != null) throw _cleanupFailure!;
    }).then(
      (_) {
        _releasing = null;
        done.complete();
      },
      onError: (Object error, StackTrace stack) {
        _releasing = null;
        done.completeError(error, stack);
      },
    );
    return done.future;
  }
}

class SelectionCleanupFailure implements Exception {
  SelectionCleanupFailure(
    Iterable<Object> failures, {
    this.operationError,
    this.operationStack,
  }) : failures = List.unmodifiable(failures);

  final List<Object> failures;
  final Object? operationError;
  final StackTrace? operationStack;

  @override
  String toString() => 'Selection cleanup failed: ${failures.join('; ')}';
}

/// Application-owned fallback for removed/replaced windows and mobile hosts.
/// Registration happens before the deferred operation callback can execute.
class SelectionTaskRegistry {
  final _tasks =
      <Object, ({void Function() cancel, Future<void> Function() close})>{};
  bool _closed = false;
  Future<void>? _closing;

  bool get isClosing => _closed;

  void Function() retain({
    required void Function() cancel,
    required Future<void> Function() close,
  }) {
    if (_closed) {
      cancel();
      return () {};
    }
    final token = Object();
    _tasks[token] = (cancel: cancel, close: close);
    return () => _tasks.remove(token);
  }

  Future<void> closeAndWait() {
    final previous = _closing;
    if (previous != null) return previous;
    _closed = true;
    final done = Completer<void>();
    _closing = done.future;
    final tasks = _tasks.entries.toList();
    final failures = <({Object error, StackTrace stack})>[];
    for (final entry in tasks) {
      try {
        entry.value.cancel();
      } catch (error, stack) {
        failures.add((error: error, stack: stack));
      }
    }
    Future.wait(
      tasks.map((entry) async {
        try {
          await entry.value.close();
          _tasks.remove(entry.key);
        } catch (error, stack) {
          failures.add((error: error, stack: stack));
        }
      }),
    ).then((_) {
      if (failures.isEmpty) {
        done.complete();
      } else {
        _closing = null;
        done.completeError(SelectionCleanupFailure(failures));
      }
    });
    return done.future;
  }
}
