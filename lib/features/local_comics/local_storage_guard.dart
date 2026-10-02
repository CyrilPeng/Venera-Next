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

  final _imports = <Completer<void>>{};
  Completer<void>? _exclusive;
  Future<void Function()>? _exitPreparation;

  /// Completion of the current migration/recovery, including failed operations.
  Future<void>? get pendingExclusive => _exclusive?.future;

  Future<T> runImport<T>(Future<T> Function() action) async {
    _checkAdmission();
    final done = Completer<void>();
    _imports.add(done);
    try {
      while (_exclusive != null) {
        await _exclusive!.future;
      }
      return await action();
    } finally {
      _imports.remove(done);
      done.complete();
    }
  }

  Future<T> runExclusive<T>(Future<T> Function() action) async {
    _checkAdmission();
    if (_imports.isNotEmpty) {
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

  void _checkAdmission() {
    if (_exitPreparation != null) {
      throw const LocalComicStorageBusy(
        'Local comic storage is closing. Try again later.',
      );
    }
  }

  /// Reject new operations, then drain accepted imports (including waiters)
  /// and migration/recovery. Operation failures still reach their own callers.
  Future<void Function()> prepareForExit() {
    final existing = _exitPreparation;
    if (existing != null) return existing;
    final pending = [
      for (final importing in _imports) importing.future,
      if (_exclusive != null) _exclusive!.future,
    ];
    late final Future<void Function()> preparation;
    preparation = Future.wait(pending).then(
      (_) => () {
        if (identical(_exitPreparation, preparation)) _exitPreparation = null;
      },
    );
    _exitPreparation = preparation;
    return preparation;
  }
}
