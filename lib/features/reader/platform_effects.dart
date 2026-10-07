import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';

import 'platform_effects_controller.dart';

export 'platform_effects_controller.dart' show ReaderOrientation;

final _nativeEffects = ReaderPlatformEffectsCoordinator(
  applyOrientation: (orientation) =>
      SystemChrome.setPreferredOrientations(switch (orientation) {
        ReaderOrientation.system => const [],
        ReaderOrientation.portrait => const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ],
        ReaderOrientation.landscape => const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
      }),
  applySystemBars: (visible) => SystemChrome.setEnabledSystemUIMode(
    visible ? SystemUiMode.edgeToEdge : SystemUiMode.immersive,
  ),
  onError: (error, stack) =>
      Log.error('Reader', 'Platform effects failed: $error', stack),
);

void _observe(Future<void> operation) {
  unawaited(operation.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
}

/// Binds one policy before native work starts. Failed release stays registered
/// with the original host/window even after the widget that created it leaves.
class ReaderPlatformEffectsBinding {
  ReaderPlatformEffectsBinding(
    BuildContext context, {
    bool systemBarsVisible = true,
    bool? orientationEnabled,
  }) : coordinator = ReaderPlatformEffectsScope.coordinatorOf(context),
       _registry = context
           .getInheritedWidgetOfExactType<SelectionTasksScope>()
           ?.registry,
       _frame = context.getInheritedWidgetOfExactType<WindowFrameController>() {
    handle = coordinator.createOwner(
      orientationEnabled:
          orientationEnabled ?? defaultTargetPlatform == TargetPlatform.android,
      systemBarsVisible: systemBarsVisible,
    );
    if (_registry?.isClosing == true || _frame?.isClosing == true) {
      dispose();
      return;
    }
    _frame?.addCloseStartListener(_holdWindow);
    _frame?.addCloseFailureListener(_resumeWindow);
    _frame?.addExitTask(_prepareWindow);
    _releaseHost = _registry?.retain(cancel: dispose, close: closeAndWait);
    _observe(handle.attach());
  }

  final ReaderPlatformEffectsCoordinator coordinator;
  final SelectionTaskRegistry? _registry;
  final WindowFrameController? _frame;
  late final ReaderPlatformEffectsHandle handle;
  final _windowHold = Object();
  void Function()? _releaseHost;
  Future<void>? _closing;

  bool belongsTo(BuildContext context) =>
      identical(
        coordinator,
        ReaderPlatformEffectsScope.coordinatorOf(context),
      ) &&
      identical(
        _registry,
        context.getInheritedWidgetOfExactType<SelectionTasksScope>()?.registry,
      ) &&
      _frame?.addExitTask ==
          context
              .getInheritedWidgetOfExactType<WindowFrameController>()
              ?.addExitTask;

  void _holdWindow() => _observe(handle.hold(_windowHold, true));
  void _resumeWindow() => _observe(handle.hold(_windowHold, false));
  Future<void> _prepareWindow() =>
      handle.isClosed ? closeAndWait() : handle.hold(_windowHold, true);

  void setSystemBarsVisible(bool visible) =>
      _observe(handle.setSystemBarsVisible(visible));

  bool cycleOrientation() {
    final operation = handle.cycleOrientation();
    if (operation == null) return false;
    _observe(operation);
    return true;
  }

  /// Each exit attempt has its own hold; releasing one cannot reopen another.
  ({Future<void> ready, void Function() release}) prepareForExit() {
    final reason = Object();
    final ready = handle.hold(reason, true);
    return (ready: ready, release: () => _observe(handle.hold(reason, false)));
  }

  void dispose() => _observe(closeAndWait());

  Future<void> closeAndWait() {
    if (_closing case final closing?) return closing;
    final closing = _closing = handle.closeAndWait();
    unawaited(
      closing.then<void>(
        (_) {
          _releaseHost?.call();
          _releaseHost = null;
          _frame?.removeCloseStartListener(_holdWindow);
          _frame?.removeCloseFailureListener(_resumeWindow);
          _frame?.removeExitTask(_prepareWindow);
        },
        onError: (Object _, StackTrace _) {
          _closing = null;
        },
      ),
    );
    return closing;
  }
}

/// The mounted application owns its default policy too. The native coordinator
/// outlives scopes so a late old-scope release cannot overwrite a newer reader.
class ReaderPlatformEffectsScope extends StatelessWidget {
  const ReaderPlatformEffectsScope({
    super.key,
    required this.child,
    this.coordinator,
  });
  final Widget child;
  final ReaderPlatformEffectsCoordinator? coordinator;

  static ReaderPlatformEffectsCoordinator coordinatorOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_EffectsProvider>()?.coordinator ??
      _nativeEffects;

  static void watch(BuildContext context) {
    context.dependOnInheritedWidgetOfExactType<_EffectsProvider>();
  }

  @override
  Widget build(BuildContext context) => _EffectsProvider(
    coordinator: coordinator ?? _nativeEffects,
    child: _ApplicationPolicy(child: child),
  );
}

class _EffectsProvider extends InheritedWidget {
  const _EffectsProvider({required this.coordinator, required super.child});
  final ReaderPlatformEffectsCoordinator coordinator;
  @override
  bool updateShouldNotify(_EffectsProvider oldWidget) =>
      !identical(coordinator, oldWidget.coordinator);
}

class _ApplicationPolicy extends StatefulWidget {
  const _ApplicationPolicy({required this.child});
  final Widget child;
  @override
  State<_ApplicationPolicy> createState() => _ApplicationPolicyState();
}

class _ApplicationPolicyState extends State<_ApplicationPolicy> {
  ReaderPlatformEffectsBinding? _binding;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.dependOnInheritedWidgetOfExactType<_EffectsProvider>();
    context.dependOnInheritedWidgetOfExactType<SelectionTasksScope>();
    context.dependOnInheritedWidgetOfExactType<WindowFrameController>();
    if (_binding?.belongsTo(context) == true) return;
    _binding?.dispose();
    _binding = ReaderPlatformEffectsBinding(context);
  }

  @override
  void dispose() {
    _binding?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
