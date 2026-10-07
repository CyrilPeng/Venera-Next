import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/translations.dart';

/// Settings opened by a reader retain accepted saves in that reading session,
/// even if the sidebar or setting control is forcibly removed.
class SettingsSaveScope extends InheritedWidget {
  const SettingsSaveScope({
    super.key,
    required this.work,
    required super.child,
  });
  final ImageWork work;
  @override
  bool updateShouldNotify(covariant SettingsSaveScope oldWidget) =>
      !identical(work, oldWidget.work);
}

/// Owns idempotent setting assignments from acceptance through persistence.
/// Callers capture values and targets before submitting; retries must not
/// repeat incremental business operations or read a later UI selection.
abstract class SettingsSaveState<W extends StatefulWidget> extends State<W> {
  final _pending = <_SettingsSave>{};
  final _latest = <Object, _SettingsSave>{};
  final _guards = <ModalRoute<dynamic>, _SettingsPopEntry>{};
  WindowFrameController? _window;
  ImageWork? _work;
  SelectionTaskRegistry? _registry;
  Object _owner = Object();
  bool _leaving = false;
  bool _disposed = false;

  bool get savingSettings => _pending.isNotEmpty;
  bool get acceptsSettingsChanges =>
      !_disposed &&
      !_leaving &&
      _window?.isClosing != true &&
      _registry?.isClosing != true;
  bool get hasSettingsSaveError =>
      _latest.values.any((save) => save.hasFailures);

  bool get _canRetry => _latest.values.any(
    (save) => save.hasFailures && (save.isCurrent?.call() ?? true),
  );

  @override
  void initState() {
    super.initState();
    _work = context.getInheritedWidgetOfExactType<SettingsSaveScope>()?.work;
    _window = context.getInheritedWidgetOfExactType<WindowFrameController>();
    _registry = context
        .getInheritedWidgetOfExactType<SelectionTasksScope>()
        ?.registry;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final work = context
        .dependOnInheritedWidgetOfExactType<SettingsSaveScope>()
        ?.work;
    final window = context
        .dependOnInheritedWidgetOfExactType<WindowFrameController>();
    final registry = context
        .dependOnInheritedWidgetOfExactType<SelectionTasksScope>()
        ?.registry;
    if (window?.addExitTask != _window?.addExitTask ||
        registry != _registry ||
        work != _work) {
      // Accepted saves keep their original registrations and repair chains.
      // A new host cannot repair or retry an old host's operation by UI key.
      _owner = Object();
      _latest.clear();
    }
    _window = window;
    _work = work;
    _registry = registry;
    final routes = <ModalRoute<dynamic>>{
      ?ModalRoute.of(context),
      ?PopupIndicatorWidget.maybeOf(context)?.route,
    };
    for (final route in _guards.keys.toList()) {
      if (routes.contains(route)) continue;
      final guard = _guards.remove(route)!;
      route.unregisterPopEntry(guard);
      guard.canPopNotifier.dispose();
    }
    for (final route in routes) {
      if (_guards.containsKey(route)) continue;
      final guard = _SettingsPopEntry(() => leaveSettings(route));
      _guards[route] = guard;
      route.registerPopEntry(guard);
    }
    _updateGuards();
  }

  void _updateGuards() {
    for (final guard in _guards.values) {
      guard.canPopNotifier.value = !savingSettings && !hasSettingsSaveError;
    }
  }

  Future<bool> saveSetting(
    // Keys identify the persisted target and field, not just the UI control.
    Object key,
    Future<void> Function() persist, {
    VoidCallback? onSaved,
    bool Function()? isCurrent,
  }) async {
    if (!acceptsSettingsChanges) return false;
    final owner = _owner;
    final registry = _registry;
    final window = _window;
    final work = _work;
    final task = work?.start();
    if (work != null && task == null) return false;
    if (!identical(owner, _owner) || !acceptsSettingsChanges) {
      task?.finish();
      return false;
    }
    final save = _SettingsSave(persist, onSaved, isCurrent, _latest[key]);
    _latest[key] = save;
    _pending.add(save);
    // Register ownership before invoking even a synchronously reentrant save.
    var started = false;
    try {
      save.retain(registry, window);
      if (save.cancelled ||
          registry?.isClosing == true ||
          window?.isClosing == true ||
          !identical(owner, _owner)) {
        return false;
      }
      _updateGuards();
      setState(() {});
      started = true;
      await Future<void>.sync(persist);
      if (identical(_latest[key], save)) {
        if (!_disposed &&
            identical(owner, _owner) &&
            registry?.isClosing != true &&
            identical(work, _work) &&
            (isCurrent?.call() ?? true)) {
          onSaved?.call();
        }
      }
      // A successful accepted assignment can repair its own older attempts,
      // even if its page has detached. It never repairs a later attempt.
      save.acknowledgeRepairedFailures();
      return true;
    } catch (error, stack) {
      save.error = error;
      save.stack = stack;
      save.acknowledgeWorkFailure = task?.recordFailure(error, stack);
      Log.error('Setting save', error, stack);
      if (mounted &&
          !_disposed &&
          identical(owner, _owner) &&
          registry?.isClosing != true &&
          (isCurrent?.call() ?? true)) {
        context.showMessage(message: error.toString());
      }
      return false;
    } finally {
      _pending.remove(save);
      task?.finish();
      save.done.complete();
      save.releaseIfSettled();
      if (!started && save.error == null && identical(_latest[key], save)) {
        if (save.previous case final previous?) {
          _latest[key] = previous;
        } else {
          _latest.remove(key);
        }
      }
      final latest = _latest[key];
      if (latest != null && !latest.hasPending && !latest.hasFailures) {
        _latest.remove(key);
      }
      if (!_disposed) {
        _updateGuards();
        setState(() {});
      }
    }
  }

  Future<void> waitForSettingsSave() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.map((save) => save.done.future).toList());
    }
    // Keep failed fields independent: saving brightness must not silently
    // acknowledge a failed mode change or discard its retry.
    _reportFailures(_latest.values);
  }

  static void _reportFailures(Iterable<_SettingsSave> saves) {
    final failures = [
      for (final save in saves)
        for (final attempt in save.attempts)
          if (attempt.error != null && !attempt.repaired)
            (error: attempt.error!, stackTrace: attempt.stack!),
    ];
    if (failures.length == 1) {
      Error.throwWithStackTrace(
        failures.single.error,
        failures.single.stackTrace,
      );
    } else if (failures.isNotEmpty) {
      throw SettingsSaveFailure(failures);
    }
  }

  Future<void> retrySettingsSave() async {
    final failed = _latest.entries
        .where((entry) => entry.value.hasFailures)
        .toList();
    await Future.wait([
      for (final entry in failed)
        if (identical(_latest[entry.key], entry.value) &&
            (entry.value.isCurrent?.call() ?? true))
          saveSetting(
            entry.key,
            entry.value.persist,
            onSaved: entry.value.onSaved,
            isCurrent: entry.value.isCurrent,
          ),
    ]);
  }

  Future<void> leaveSettings([ModalRoute<dynamic>? destination]) async {
    if (!acceptsSettingsChanges) return;
    final route =
        destination ??
        (Navigator.of(context).canPop()
            ? ModalRoute.of(context)
            : PopupIndicatorWidget.maybeOf(context)?.route ??
                  ModalRoute.of(context));
    final navigator = route?.navigator;
    _leaving = true;
    setState(() {});
    try {
      await waitForSettingsSave();
      if (mounted &&
          !_disposed &&
          _guards.containsKey(route) &&
          route?.isCurrent == true &&
          navigator?.mounted == true &&
          NavigationAdmission.allows(context)) {
        // Respect other owners on this route as well as LocalHistoryEntry.
        await navigator!.maybePop();
      }
    } catch (error) {
      if (mounted && !_disposed) context.showMessage(message: error.toString());
    } finally {
      _leaving = false;
      if (!_disposed) setState(() {});
    }
  }

  Widget get settingsSaveStatus => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (savingSettings)
        Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              semanticsLabel: 'Save'.tl,
            ),
          ),
        ),
      if (hasSettingsSaveError)
        TextButton(
          onPressed: acceptsSettingsChanges && _canRetry
              ? retrySettingsSave
              : null,
          child: Text('Retry'.tl),
        ),
    ],
  );

  Widget protectSettings(Widget child) => ExcludeFocus(
    excluding: !acceptsSettingsChanges,
    child: AbsorbPointer(absorbing: !acceptsSettingsChanges, child: child),
  );

  @override
  void dispose() {
    _disposed = true;
    for (final entry in _guards.entries) {
      entry.key.unregisterPopEntry(entry.value);
      entry.value.canPopNotifier.dispose();
    }
    _guards.clear();
    if (savingSettings || hasSettingsSaveError) {
      final pending = waitForSettingsSave();
      unawaited(
        pending.catchError((Object error, StackTrace stack) {
          Log.error('Detached setting save', error, stack);
        }),
      );
    }
    super.dispose();
  }
}

class SettingsSaveFailure implements Exception {
  SettingsSaveFailure(
    Iterable<({Object error, StackTrace stackTrace})> failures,
  ) : failures = List.unmodifiable(failures);
  final List<({Object error, StackTrace stackTrace})> failures;
  @override
  String toString() => failures.map((failure) => failure.error).join('; ');
}

class _SettingsSave {
  _SettingsSave(this.persist, this.onSaved, this.isCurrent, this.previous);
  final Future<void> Function() persist;
  final VoidCallback? onSaved;
  final bool Function()? isCurrent;
  final done = Completer<void>();
  Object? error;
  StackTrace? stack;
  final _SettingsSave? previous;
  void Function()? acknowledgeWorkFailure;
  bool repaired = false;
  bool cancelled = false;
  final _releases = <VoidCallback>[];

  Iterable<_SettingsSave> get attempts sync* {
    for (_SettingsSave? save = this; save != null; save = save.previous) {
      yield save;
    }
  }

  bool get hasFailures =>
      attempts.any((save) => save.error != null && !save.repaired);
  bool get hasPending => attempts.any((save) => !save.done.isCompleted);

  void cancel() => cancelled = true;

  void retain(SelectionTaskRegistry? registry, WindowFrameController? window) {
    final releaseHost = registry?.retain(cancel: cancel, close: closeAndWait);
    if (releaseHost != null) _releases.add(releaseHost);
    if (window != null) {
      window.addCloseStartListener(cancel);
      window.addExitTask(closeAndWait);
      _releases.add(() {
        window.removeCloseStartListener(cancel);
        window.removeExitTask(closeAndWait);
      });
    }
  }

  Future<void> closeAndWait() async {
    await done.future;
    if (error != null && !repaired) {
      Error.throwWithStackTrace(error!, stack!);
    }
  }

  void releaseIfSettled() {
    if (!done.isCompleted || (error != null && !repaired)) return;
    final releases = List.of(_releases);
    _releases.clear();
    for (final release in releases) {
      release();
    }
  }

  void acknowledgeRepairedFailures() {
    for (final save in attempts) {
      if (save.error == null) continue;
      save.repaired = true;
      save.acknowledgeWorkFailure?.call();
      save.acknowledgeWorkFailure = null;
      save.releaseIfSettled();
    }
  }
}

class _SettingsPopEntry extends PopEntry<Object?> {
  _SettingsPopEntry(this.leave);
  final Future<void> Function() leave;
  @override
  final ValueNotifier<bool> canPopNotifier = ValueNotifier(true);
  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (!didPop && !canPopNotifier.value) unawaited(leave());
  }
}
