import 'dart:async';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/application_update_service.dart';
import 'package:venera_next/foundation/selection_operation.dart';

import 'package:venera_next/features/sync/data_sync_controller.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/follow_updates/follow_updates_runtime.dart';

import 'core_bootstrap.dart';
import 'window_placement.dart';
import 'interactive_bindings.dart';
import 'application_updates.dart';

/// Lifetime of one application, including widget mounts that have already
/// detached but still own asynchronous work. Final close never reopens it.
class ApplicationHost {
  ApplicationHost({
    required this.core,
    required this.sync,
    this.placement,
    this.sourceInstallations,
    SourceUpdateService? sourceUpdates,
    AppDataOperations? dataOperations,
    ApplicationUpdateService? applicationUpdates,
  }) : sourceUpdates = sourceUpdates ?? SourceUpdateService.instance,
       applicationUpdates = applicationUpdates ?? createApplicationUpdates(),
       dataOperations = dataOperations ?? AppDataOperations.instance;

  final CoreBootstrap core;
  final DataSyncController sync;
  final WindowPlacementHost? placement;
  final SourceUpdateService sourceUpdates;
  final SourceInstallations? sourceInstallations;
  final ApplicationUpdateService applicationUpdates;
  final AppDataOperations dataOperations;
  final selections = SelectionTaskRegistry();
  final _mounts = <ApplicationMount>[];
  final _finalDrains = <Future<void> Function()>{};
  ApplicationMount? _current;
  bool _closing = false;
  bool _syncPrepared = false;
  bool _syncClosed = false;
  Future<void>? _coreClose;
  Future<void>? _attempt;

  bool get isClosing => _closing;

  ApplicationMount attach({
    required void Function() stop,
    required Future<void> Function() close,
  }) {
    if (_closing) throw StateError('Application host is closing');
    // Detach old listeners/timers synchronously before a new mount subscribes.
    final previous = _current;
    if (previous != null) {
      unawaited(
        previous.closeAndWait().then<void>((_) {
          _mounts.remove(previous);
        }, onError: (Object _, StackTrace _) {}),
      );
    }
    final mount = ApplicationMount._(stop, close);
    _mounts.add(mount);
    return _current = mount;
  }

  /// Called after the window's reversible preparations. A failed final close
  /// stays irreversible: retry only resumes the owners' own close contracts.
  Future<void> close({Future<void> Function()? drain}) {
    if (drain != null) _finalDrains.add(drain);
    final attempt = _attempt;
    if (attempt != null) return attempt;
    _closing = true;
    sync.stop();
    final done = Completer<void>();
    _attempt = done.future;
    _close().then(
      done.complete,
      onError: (Object error, StackTrace stack) {
        _attempt = null;
        done.completeError(error, stack);
      },
    );
    return done.future;
  }

  Future<void> _close() async {
    final failures = <ApplicationCloseDiagnostic>[];
    Future<void> attempt(String owner, Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stack) {
        failures.add((owner: owner, error: error, stack: stack));
      }
    }

    // Each mount must join its real tasks even if cancelling/subscription
    // release fails. Older mounts cannot disappear from the final drain.
    await Future.wait([
      attempt('selection tasks', selections.closeAndWait),
      if (sourceInstallations case final installations?)
        attempt('source installations', installations.closeAndWait),
      for (var i = 0; i < _mounts.length; i++)
        attempt('interactive mount ${i + 1}', _mounts[i].closeAndWait),
    ]);
    await attempt('source updates', sourceUpdates.closeAndWait);
    await attempt('application updates', applicationUpdates.closeAndWait);
    await attempt('window writes', _drainWindows);
    if (!_syncPrepared) {
      await attempt('sync preparation', () async {
        await sync.prepareForExit();
        _syncPrepared = true;
      });
    }
    // A failed owner may still retain resources. Do not invalidate its core
    // dependencies merely because its close Future has settled with an error.
    if (failures.isNotEmpty) throw ApplicationCloseFailure(failures);

    await attempt('core producers', core.prepareForClose);
    await attempt('window writes', _drainWindows);
    if (failures.isNotEmpty) throw ApplicationCloseFailure(failures);
    // Keep sync observation alive through all admitted writes. Its final save
    // owns the last exclusive admission; stores are released only after that
    // save succeeds. A failed save can retry without reopening business work.
    await attempt(
      'final persistence and stores',
      () => dataOperations.closeAndWait(
        finalize: () async {
          if (!_syncClosed) {
            await sync.closeAndWait();
            _syncClosed = true;
          }
          // Store close methods use the same admission protocol. Producers have
          // already stopped outside this scope; only their cached closes remain.
          await (_coreClose ??= core.close());
        },
      ),
    );
    if (failures.isNotEmpty) throw ApplicationCloseFailure(failures);
  }

  Future<void> _drainWindows() async {
    final visited = <Future<void> Function()>{};
    while (visited.length < _finalDrains.length) {
      final pending = _finalDrains.difference(visited);
      visited.addAll(pending);
      await Future.wait(pending.map((drain) => Future<void>.sync(drain)));
    }
  }
}

Future<void> closeApplicationMountBindings({
  required FollowUpdatesRuntime followUpdates,
  required InteractiveBindings interactive,
  Future<void> Function()? closeStartupUpdates,
}) async {
  final failures = <ApplicationCloseDiagnostic>[];
  await Future.wait([
    for (final owner in <({String name, Future<void> Function() close})>[
      (name: 'follow updates', close: followUpdates.closeAndWait),
      (name: 'platform bindings', close: interactive.dispose),
      if (closeStartupUpdates != null)
        (name: 'startup updates', close: closeStartupUpdates),
    ])
      Future<void>.sync(owner.close).catchError((
        Object error,
        StackTrace stack,
      ) {
        failures.add((owner: owner.name, error: error, stack: stack));
      }),
  ]);
  if (failures.isNotEmpty) throw ApplicationCloseFailure(failures);
}

class ApplicationMount {
  ApplicationMount._(this._stop, this._close);
  final void Function() _stop;
  final Future<void> Function() _close;
  Future<void>? _closing;

  Future<void> closeAndWait() {
    final closing = _closing;
    if (closing != null) return closing;
    final done = Completer<void>();
    _closing = done.future;
    final failures = <ApplicationCloseDiagnostic>[];
    try {
      _stop();
    } catch (error, stack) {
      failures.add((owner: 'stop scheduling', error: error, stack: stack));
    }
    Future<void>.sync(_close).then(
      (_) {
        if (failures.isEmpty) {
          done.complete();
        } else {
          done.completeError(ApplicationCloseFailure(failures));
        }
      },
      onError: (Object error, StackTrace stack) {
        failures.add((owner: 'release bindings', error: error, stack: stack));
        done.completeError(ApplicationCloseFailure(failures), stack);
      },
    );
    return done.future;
  }
}

typedef ApplicationCloseDiagnostic = ({
  String owner,
  Object error,
  StackTrace stack,
});

class ApplicationCloseFailure implements Exception {
  ApplicationCloseFailure(Iterable<ApplicationCloseDiagnostic> failures)
    : failures = List.unmodifiable(failures);
  final List<ApplicationCloseDiagnostic> failures;
  @override
  String toString() =>
      'Application shutdown failed: ${failures.map((failure) => '${failure.owner}: ${failure.error}').join('; ')}';
}
