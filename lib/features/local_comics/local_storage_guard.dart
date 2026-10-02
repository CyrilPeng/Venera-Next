import 'dart:async';

class LocalComicStorageBusy implements Exception {
  const LocalComicStorageBusy(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Keeps document imports out of storage migration and library recovery.
/// Normal reading remains available throughout these operations.
class LocalComicStorageGuard {
  static final instance = LocalComicStorageGuard();

  int _imports = 0;
  Completer<void>? _exclusive;

  /// Completion of the current migration/recovery, including failed operations.
  Future<void>? get pendingExclusive => _exclusive?.future;

  Future<T> runImport<T>(Future<T> Function() action) async {
    while (_exclusive != null) {
      await _exclusive!.future;
    }
    _imports++;
    try {
      return await action();
    } finally {
      _imports--;
    }
  }

  Future<T> runExclusive<T>(Future<T> Function() action) async {
    if (_imports > 0) {
      throw const LocalComicStorageBusy(
        'Wait for document imports to finish or cancel them before changing the local library.',
      );
    }
    if (_exclusive != null) {
      throw const LocalComicStorageBusy(
        'Local comic storage is busy. Try again later.',
      );
    }
    final done = _exclusive = Completer<void>();
    try {
      return await action();
    } finally {
      _exclusive = null;
      done.complete();
    }
  }
}
