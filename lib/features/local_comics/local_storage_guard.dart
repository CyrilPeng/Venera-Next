import 'dart:async';
import 'package:venera_next/foundation/app_data_operations.dart';

class LocalComicStorageBusy implements Exception {
  const LocalComicStorageBusy(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Keeps imports and directory allocation out of migration and recovery.
/// Normal reading remains available throughout these operations.
class LocalComicStorageGuard {
  static final instance = LocalComicStorageGuard();

  final _imports = <Completer<void>>{};
  final _importOwnerKey = Object();
  final _exclusiveOwnerKey = Object();
  Completer<void>? _exclusive;
  Future<void Function()>? _exitPreparation;

  /// Completion of the current migration/recovery, including failed operations.
  Future<void>? get pendingExclusive => _exclusive?.future;

  Future<T> runImport<T>(Future<T> Function() action) =>
      AppDataOperations.instance.access(() => _runImport(action));

  Future<T> _runImport<T>(Future<T> Function() action) async {
    _checkAdmission();
    final done = Completer<void>();
    _imports.add(done);
    try {
      while (_exclusive != null) {
        await _exclusive!.future;
      }
      return await runZoned(action, zoneValues: {_importOwnerKey: done});
    } finally {
      _imports.remove(done);
      done.complete();
    }
  }

  Future<T> runExclusive<T>(Future<T> Function() action) =>
      AppDataOperations.instance.access(() => _runExclusive(action));

  Future<T> _runExclusive<T>(Future<T> Function() action) async {
    _checkAdmission();
    if (_imports.isNotEmpty) {
      throw const LocalComicStorageBusy(
        'Wait for local file operations to finish before changing the local library.',
      );
    }
    if (_exclusive != null) {
      throw const LocalComicStorageBusy(
        'Local comic storage is busy. Try again later.',
      );
    }
    final done = _exclusive = Completer<void>();
    try {
      return await runZoned(action, zoneValues: {_exclusiveOwnerKey: done});
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

  /// Synchronous record mutations may finish within their accepted owner even
  /// during exit draining. Unrelated or expired owners cannot enter a migration.
  T write<T>(T Function() action) {
    final importOwner = Zone.current[_importOwnerKey];
    final exclusiveOwner = Zone.current[_exclusiveOwnerKey];
    if ((importOwner != null && !_imports.contains(importOwner)) ||
        (exclusiveOwner != null && !identical(exclusiveOwner, _exclusive))) {
      throw const LocalComicStorageBusy('Local storage reservation has ended.');
    }
    final ownsImport = importOwner != null;
    final ownsExclusive = exclusiveOwner != null;
    if (!ownsImport && !ownsExclusive) _checkAdmission();
    if (_exclusive != null && !ownsExclusive) {
      throw const LocalComicStorageBusy(
        'Local comic storage is busy. Try again later.',
      );
    }
    return action();
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
