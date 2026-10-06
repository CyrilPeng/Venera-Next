import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// A selected directory is borrowed. Only a copy created by this owner may be
/// deleted; native access belongs to its original per-selection callback.
class DirectorySelection {
  DirectorySelection(
    Directory directory, {
    Future<void> Function()? releaseAccess,
    Future<void> Function()? retainAccess,
  }) : _directory = directory,
       _releaseAccess = releaseAccess,
       _retainAccess = retainAccess,
       _cacheDirectory = null,
       _copy = null;

  DirectorySelection.copy({
    required Directory source,
    required Directory cacheDirectory,
    required Future<void> Function(Directory, Directory) copy,
  }) : _cacheDirectory = cacheDirectory,
       _copy = ((directory) => copy(source, directory)),
       _releaseAccess = null,
       _retainAccess = null;

  /// Owns generated contents using the same receipt protocol as copied input.
  DirectorySelection.temporary({
    required Directory cacheDirectory,
    required Future<void> Function(Directory) prepare,
  }) : _cacheDirectory = cacheDirectory,
       _copy = prepare,
       _releaseAccess = null,
       _retainAccess = null;

  final Directory? _cacheDirectory;
  final Future<void> Function(Directory)? _copy;
  Future<void> Function()? _releaseAccess;
  final Future<void> Function()? _retainAccess;
  Directory? _directory;
  Directory? _copyRoot;
  String? _copyCanonical;
  String? _token;
  bool _receiptWritten = false;
  bool _receiptDeleted = false;
  Future<Directory>? _preparing;
  Future<void>? _retaining;
  Future<void>? _closing;
  bool _closed = false;
  final _uses = <Future<void>>{};
  static const _receiptName = '.selection-owner';
  static const _contentsName = 'contents';

  Future<Directory> _prepare() {
    final previous = _preparing;
    if (previous != null) return previous;
    final done = Completer<Directory>();
    _preparing = done.future;
    Future<Directory>.sync(() async {
      if (_closed) throw StateError('Directory selection is closing');
      if (_directory == null) {
        final root = await _cacheDirectory!.createTemp('selected-directory-');
        _copyRoot = root;
        _copyCanonical = await root.resolveSymbolicLinks();
        _token = const Uuid().v4();
        await File(
          p.join(root.path, _receiptName),
        ).writeAsString(_token!, flush: true);
        _receiptWritten = true;
        if (_closed) throw StateError('Directory selection is closing');
        final contents = Directory(p.join(root.path, _contentsName));
        await contents.create();
        await _copy!(contents);
        _directory = contents;
      }
      if (_closed) throw StateError('Directory selection is closing');
      return _directory!;
    }).then(done.complete, onError: done.completeError);
    unawaited(
      done.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    return done.future;
  }

  /// Includes the complete consumer Future, including native extraction or
  /// registration. Closing rejects unstarted consumers and joins active ones.
  Future<T> withDirectory<T>(Future<T> Function(Directory) action) {
    if (_closed) {
      return Future.error(StateError('Directory selection is closing'));
    }
    final done = Completer<T>();
    late final Future<void> settled;
    settled = done.future
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _uses.remove(settled));
    _uses.add(settled);
    Future<T>.microtask(() async {
      final directory = await _prepare();
      if (_closed) throw StateError('Directory selection is closing');
      return action(directory);
    }).then(done.complete, onError: done.completeError);
    return done.future;
  }

  /// Transfer native access to the application session before publishing a
  /// directory reference. A temporary copy can never become a library path.
  Future<void> retainAccessForSession() {
    if (_copy != null) {
      return Future.error(StateError('Cannot retain a temporary directory'));
    }
    if (_closed) {
      return Future.error(StateError('Directory selection is closing'));
    }
    final existing = _retaining;
    if (existing != null) return existing;
    final done = Completer<void>();
    _retaining = done.future;
    withDirectory((_) async {
      await _retainAccess?.call();
    }).then(
      done.complete,
      onError: (Object error, StackTrace stack) {
        _retaining = null;
        done.completeError(error, stack);
      },
    );
    return done.future;
  }

  Future<void> dispose() {
    final previous = _closing;
    if (previous != null) return previous;
    _closed = true;
    final done = Completer<void>();
    _closing = done.future;
    _dispose().then(
      done.complete,
      onError: (Object error, StackTrace stack) {
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
    if (_copyRoot != null) {
      await _releaseCopy(_copyRoot!);
      _copyRoot = null;
    }
    await _releaseAccess?.call();
    _releaseAccess = null;
    _directory = null;
    _preparing = null;
    _retaining = null;
  }

  Future<void> _releaseCopy(Directory root) async {
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory ||
        _copyCanonical == null ||
        !p.equals(await root.resolveSymbolicLinks(), _copyCanonical!)) {
      throw FileSystemException('Selected copy directory changed', root.path);
    }
    final entries = await root.list(followLinks: false).toList();
    if (entries.any(
      (entry) =>
          !{_receiptName, _contentsName}.contains(p.basename(entry.path)),
    )) {
      throw FileSystemException('Unknown selected copy contents', root.path);
    }
    final receipt = File(p.join(root.path, _receiptName));
    final receiptType = await FileSystemEntity.type(
      receipt.path,
      followLinks: false,
    );
    if (receiptType == FileSystemEntityType.notFound &&
        entries.isEmpty &&
        (_receiptDeleted || !_receiptWritten)) {
      // A previous release removed the receipt but could not remove the root.
      await root.delete();
      return;
    }
    if (receiptType != FileSystemEntityType.file ||
        !p.equals(
          await receipt.resolveSymbolicLinks(),
          p.join(_copyCanonical!, _receiptName),
        ) ||
        (_receiptWritten && await receipt.readAsString() != _token)) {
      throw FileSystemException(
        'Selected copy ownership receipt changed',
        receipt.path,
      );
    }
    final contents = Directory(p.join(root.path, _contentsName));
    final contentsType = await FileSystemEntity.type(
      contents.path,
      followLinks: false,
    );
    if (contentsType != FileSystemEntityType.notFound) {
      if (contentsType != FileSystemEntityType.directory ||
          !p.equals(
            await contents.resolveSymbolicLinks(),
            p.join(_copyCanonical!, _contentsName),
          )) {
        throw FileSystemException(
          'Selected copy contents changed',
          contents.path,
        );
      }
      // Dart deletes descendant links themselves rather than following targets.
      await contents.delete(recursive: true);
    }
    await receipt.delete();
    _receiptDeleted = true;
    await root.delete();
  }
}

class DirectorySelectionCleanupFailure implements Exception {
  const DirectorySelectionCleanupFailure({
    required this.selection,
    required this.cleanupError,
    required this.cleanupStack,
    this.operationError,
    this.operationStack,
  });
  final DirectorySelection selection;
  final Object cleanupError;
  final StackTrace cleanupStack;
  final Object? operationError;
  final StackTrace? operationStack;
  @override
  String toString() =>
      'Selected directory cleanup failed: $cleanupError'
      '${operationError == null ? '' : '; operation: $operationError'}';
}

Future<T> withSelectedDirectory<T>(
  DirectorySelection selection,
  Future<T> Function(DirectorySelection) action,
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
      throw DirectorySelectionCleanupFailure(
        selection: selection,
        cleanupError: error,
        cleanupStack: stack,
        operationError: cause,
        operationStack: causeStack,
      );
    }
  }
}
