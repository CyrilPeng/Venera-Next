import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Owns a selected file until explicitly released. Local paths are borrowed;
/// only a native preparation receipt grants permission to delete a copy.
class FileSelection {
  FileSelection(String path)
    : identifier = path,
      name = p.basename(path),
      _isDocument = false,
      _file = File(path);

  FileSelection.androidDocument({required String uri, required this.name})
    : identifier = uri,
      _isDocument = true;

  static const _channel = MethodChannel('venera/select_file');
  final String identifier;
  final String name;
  final bool _isDocument;
  File? _file;
  Map<String, String>? _receipt;
  Future<File>? _preparing;
  Future<void>? _closing;
  bool _closed = false;
  final _uses = <Future<void>>{};

  Future<File> prepare() {
    if (_closed) return Future.error(StateError('File selection is closing'));
    final pending = _preparing;
    if (pending != null) return pending;
    final done = Completer<File>();
    _preparing = done.future;
    _prepare().then(
      done.complete,
      onError: (Object error, StackTrace stack) {
        if (!_closed && _receipt == null) _preparing = null;
        done.completeError(error, stack);
      },
    );
    // Close can observe failure independently from the original consumer.
    unawaited(
      done.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    return done.future;
  }

  Future<File> _prepare() async {
    if (_file == null && _isDocument) {
      Map<String, dynamic>? result;
      try {
        result = await _channel.invokeMapMethod<String, dynamic>(
          'prepareFile',
          identifier,
        );
      } on PlatformException catch (error) {
        // Native copying may fail together with cleanup. Keep its ownership
        // receipt so explicit close can retry without copying/importing again.
        final details = error.details;
        if (details is Map &&
            details['path'] is String &&
            details['token'] is String) {
          _receipt = {
            'path': details['path'] as String,
            'token': details['token'] as String,
          };
        }
        rethrow;
      }
      if (result == null ||
          result['path'] is! String ||
          result['temporary'] is! bool) {
        throw StateError('Invalid selected file preparation result');
      }
      final path = result['path'] as String;
      if (result['temporary'] == true) {
        final token = result['token'];
        if (token is! String || token.isEmpty) {
          throw StateError('Missing selected file ownership receipt');
        }
        _receipt = {'path': path, 'token': token};
      }
      _file = File(path);
    }
    if (_closed) throw StateError('File selection is closing');
    return _file!;
  }

  /// Keep the file through the complete consumer Future. No new consumer starts
  /// after close; already running reads/imports finish before deleting copies.
  Future<T> withFile<T>(Future<T> Function(File file) action) {
    if (_closed) return Future.error(StateError('File selection is closing'));
    final done = Completer<T>();
    late final Future<void> settled;
    settled = done.future
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _uses.remove(settled));
    _uses.add(settled);
    Future<T>.microtask(() async {
      final file = await prepare();
      if (_closed) throw StateError('File selection is closing');
      return action(file);
    }).then(done.complete, onError: done.completeError);
    return done.future;
  }

  Future<Uint8List> readAsBytes() => withFile((file) => file.readAsBytes());
  Future<void> saveTo(String path) => withFile((file) async {
    await file.copy(path);
  });

  Future<void> dispose() {
    final closing = _closing;
    if (closing != null) return closing;
    _closed = true;
    final done = Completer<void>();
    _closing = done.future;
    _dispose().then(
      done.complete,
      onError: (Object error, StackTrace stack) {
        // Preserve the same file/receipt; retry only its release.
        _closing = null;
        done.completeError(error, stack);
      },
    );
    return done.future;
  }

  Future<void> _dispose() async {
    await _preparing?.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    while (_uses.isNotEmpty) {
      await Future.wait(_uses.toList());
    }
    if (_receipt != null) {
      await _channel.invokeMethod<void>('releaseFile', _receipt);
    }
    _receipt = null;
    _file = null;
  }
}

class FileSelectionCleanupFailure implements Exception {
  const FileSelectionCleanupFailure({
    required this.selection,
    required this.cleanupError,
    required this.cleanupStack,
    this.operationError,
    this.operationStack,
  });
  final FileSelection selection;
  final Object cleanupError;
  final StackTrace cleanupStack;
  final Object? operationError;
  final StackTrace? operationStack;
  @override
  String toString() =>
      'Selected file cleanup failed: $cleanupError'
      '${operationError == null ? '' : '; operation: $operationError'}';
}

/// A one-shot consumer releases its selection and preserves both failures.
Future<T> withSelectedFile<T>(
  FileSelection selection,
  Future<T> Function(FileSelection) action,
) async {
  Object? cause;
  StackTrace? causeStack;
  try {
    return await action(selection);
  } catch (error, stack) {
    cause = error;
    causeStack = stack;
    rethrow;
  } finally {
    try {
      await selection.dispose();
    } catch (error, stack) {
      throw FileSelectionCleanupFailure(
        selection: selection,
        cleanupError: error,
        cleanupStack: stack,
        operationError: cause,
        operationStack: causeStack,
      );
    }
  }
}
