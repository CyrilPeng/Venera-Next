import 'dart:async';

/// Explicit startup dependencies; no constructor side effects or UI requirement.
/// A failed startup is cached: partial databases must not be reopened implicitly.
class CoreBootstrap {
  CoreBootstrap({
    required this.environment,
    required this.settings,
    required this.infrastructure,
    required this.sources,
    required this.stores,
    required this.finish,
    this.shutdownPreparation,
    Iterable<CoreStartupCleanup> failureCleanup = const [],
  }) : _failureCleanup = failureCleanup;
  final Future<void> Function() environment;
  final Future<void> Function() settings;
  final Future<void> Function() infrastructure;
  final Future<void> Function() sources;
  final Future<void> Function() stores;
  final Future<void> Function() finish;
  final Future<void> Function()? shutdownPreparation;
  final Iterable<CoreStartupCleanup> _failureCleanup;
  Future<void>? _startup;
  Future<void>? _shutdown;
  Future<void>? _preparingShutdown;
  bool _startedSuccessfully = false;

  Future<void> start() {
    if (_shutdown != null || _preparingShutdown != null) {
      return Future.error(StateError('Core is closing'));
    }
    return _startup ??= _start();
  }

  /// The host must first stop accepting work and drain active application tasks.
  /// This closes acquired resources; it does not prepare downloads or UI routes.
  Future<void> close() => _shutdown ??= _close();

  /// Stop and join producers while their stores are still available. The host
  /// may then seal data admission and persist final state before [close].
  Future<void> prepareForClose() => _preparingShutdown ??= _prepareForClose();

  Future<void> _prepareForClose() async {
    final startup = _startup;
    if (startup == null) return;
    try {
      await startup;
    } on CoreStartupRollbackFailure catch (error) {
      // Startup already attempted every cleanup; retain its failure, do not
      // retry handles that may already have been released.
      final failures = <({String store, Object error, StackTrace stack})>[];
      Object cause = error;
      while (cause is CoreStartupRollbackFailure) {
        failures.addAll(cause.cleanupFailures);
        cause = cause.cause;
      }
      throw CoreShutdownFailure(failures);
    } catch (_) {
      return;
    }
    await shutdownPreparation?.call();
  }

  Future<void> _close() async {
    await prepareForClose();
    if (!_startedSuccessfully) return;
    final failures = await _releaseCoreResources(_failureCleanup);
    if (failures.isNotEmpty) throw CoreShutdownFailure(failures);
  }

  Future<void> _start() async {
    try {
      await environment();
      await settings();
      await infrastructure();
      // Do not start stores waiting on a source that failed to initialize.
      await sources();
      await stores();
      await finish();
      _startedSuccessfully = true;
    } catch (error, stack) {
      await rollbackCoreStartup(_failureCleanup, error, stack);
      Error.throwWithStackTrace(error, stack);
    }
  }
}

/// A store attempt owns its partially opened connection as well as its success.
typedef CoreStoreStartup = ({
  String name,
  Future<void> Function() initialize,
  FutureOr<void> Function() close,
});

class CoreStartupRollbackFailure implements Exception {
  CoreStartupRollbackFailure(
    this.cause,
    this.causeStack,
    Iterable<({String store, Object error, StackTrace stack})> cleanupFailures,
  ) : cleanupFailures = List.unmodifiable(cleanupFailures);

  final Object cause;
  final StackTrace causeStack;
  final List<({String store, Object error, StackTrace stack})> cleanupFailures;

  @override
  String toString() =>
      'Core startup failed: $cause; cleanup failed: '
      '${cleanupFailures.map((failure) => '${failure.store}: ${failure.error}').join('; ')}';
}

class CoreShutdownFailure implements Exception {
  CoreShutdownFailure(
    Iterable<({String store, Object error, StackTrace stack})> failures,
  ) : failures = List.unmodifiable(failures);
  final List<({String store, Object error, StackTrace stack})> failures;

  @override
  String toString() =>
      'Core shutdown failed: ${failures.map((e) => '${e.store}: ${e.error}').join('; ')}';
}

/// Join every attempt before rollback so a late success cannot reopen a store
/// after it has been closed. Successful startup leaves ownership with the host.
Future<void> initializeCoreStores(Iterable<CoreStoreStartup> stores) async {
  final attempts = List<CoreStoreStartup>.of(stores);
  try {
    await Future.wait(
      attempts.map((store) => Future<void>.sync(store.initialize)),
    );
  } catch (error, stack) {
    await rollbackCoreStartup(
      attempts.map((store) => (name: store.name, close: store.close)),
      error,
      stack,
    );
    Error.throwWithStackTrace(error, stack);
  }
}

/// Register only resources acquired by this startup, in acquisition order.
typedef CoreStartupCleanup = ({String name, FutureOr<void> Function() close});

/// Attempt every cleanup, retaining both the startup and cleanup failures.
Future<void> rollbackCoreStartup(
  Iterable<CoreStartupCleanup> resources,
  Object cause,
  StackTrace causeStack,
) async {
  final failures = await _releaseCoreResources(resources);
  if (failures.isNotEmpty) {
    Error.throwWithStackTrace(
      CoreStartupRollbackFailure(cause, causeStack, failures),
      causeStack,
    );
  }
}

Future<List<({String store, Object error, StackTrace stack})>>
_releaseCoreResources(Iterable<CoreStartupCleanup> resources) async {
  final failures = <({String store, Object error, StackTrace stack})>[];
  for (final resource in List<CoreStartupCleanup>.of(resources).reversed) {
    try {
      await resource.close();
    } catch (error, stack) {
      failures.add((store: resource.name, error: error, stack: stack));
    }
  }
  return failures;
}
