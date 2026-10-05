import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/image_work.dart';
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
  bool _leaving = false;
  bool _disposed = false;

  bool get savingSettings => _pending.isNotEmpty;
  bool get acceptsSettingsChanges =>
      !_disposed && !_leaving && _window?.isClosing != true;
  bool get hasSettingsSaveError =>
      _latest.values.any((save) => save.error != null);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _work = context
        .dependOnInheritedWidgetOfExactType<SettingsSaveScope>()
        ?.work;
    final window = context
        .dependOnInheritedWidgetOfExactType<WindowFrameController>();
    if (window?.addExitTask != _window?.addExitTask) {
      _window?.removeExitTask(_waitForWindowSettingsSave);
      if (savingSettings || hasSettingsSaveError) {
        _window?.trackExitTask(
          _waitForSnapshot(List.of(_pending), List.of(_latest.values)),
        );
      }
      _window = window;
      _window?.addExitTask(_waitForWindowSettingsSave);
    }
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
    Object key,
    Future<void> Function() persist, {
    VoidCallback? onSaved,
    bool Function()? isCurrent,
  }) async {
    if (!acceptsSettingsChanges) return false;
    final work = _work;
    final task = work?.start();
    if (work != null && task == null) return false;
    final save = _SettingsSave(persist, onSaved, isCurrent, _latest[key]);
    _latest[key] = save;
    _pending.add(save);
    _updateGuards();
    setState(() {});
    // Register ownership before invoking even a synchronously reentrant save.
    try {
      await Future<void>.sync(persist);
      if (identical(_latest[key], save)) {
        if (!_disposed &&
            identical(work, _work) &&
            (isCurrent?.call() ?? true)) {
          onSaved?.call();
        }
        save.acknowledgeRepairedFailures();
        if (identical(_latest[key], save)) _latest.remove(key);
      }
      return true;
    } catch (error, stack) {
      save.error = error;
      save.stack = stack;
      save.acknowledgeWorkFailure = task?.recordFailure(error, stack);
      Log.error('Setting save', error, stack);
      if (mounted && !_disposed) context.showMessage(message: error.toString());
      return false;
    } finally {
      _pending.remove(save);
      task?.finish();
      save.done.complete();
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

  // Window close has already stopped admission. Capture this host's work now,
  // including when the callback is already awaited as the element migrates.
  Future<void> _waitForWindowSettingsSave() =>
      _waitForSnapshot(List.of(_pending), List.of(_latest.values));

  static Future<void> _waitForSnapshot(
    List<_SettingsSave> pending,
    List<_SettingsSave> latest,
  ) async {
    await Future.wait(pending.map((save) => save.done.future));
    _reportFailures(latest);
  }

  static void _reportFailures(Iterable<_SettingsSave> saves) {
    final failures = [
      for (final save in saves)
        if (save.error != null) (error: save.error!, stackTrace: save.stack!),
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
        .where((entry) => entry.value.error != null)
        .toList();
    await Future.wait([
      for (final entry in failed)
        if (identical(_latest[entry.key], entry.value))
          saveSetting(
            entry.key,
            entry.value.persist,
            onSaved: entry.value.onSaved,
            isCurrent: entry.value.isCurrent,
          ),
    ]);
  }

  Future<void> leaveSettings([ModalRoute<dynamic>? destination]) async {
    if (_disposed || _leaving || _window?.isClosing == true) return;
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
          onPressed: acceptsSettingsChanges ? retrySettingsSave : null,
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
    _window?.removeExitTask(_waitForWindowSettingsSave);
    if (savingSettings || hasSettingsSaveError) {
      final pending = waitForSettingsSave();
      _window?.trackExitTask(pending);
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

  void acknowledgeRepairedFailures() {
    for (_SettingsSave? save = this; save != null; save = save.previous) {
      save.acknowledgeWorkFailure?.call();
      save.acknowledgeWorkFailure = null;
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
