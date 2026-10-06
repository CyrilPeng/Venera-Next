import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/image_save_work.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/translations.dart';

import 'window_frame.dart';
import 'window_selection_task.dart';

/// Binds one page's save owner to back navigation and the containing window.
/// Unmount retires that owner and hands its remaining work to the window.
class ImageSaveBinding extends StatefulWidget {
  const ImageSaveBinding({required this.work, required this.child, super.key});

  final ImageSaveWork work;
  final Widget child;

  @override
  State<ImageSaveBinding> createState() => _ImageSaveBindingState();
}

class _ImageSaveBindingState extends State<ImageSaveBinding> {
  WindowFrameController? _window;
  SelectionTaskRegistry? _registry;
  void Function()? _unbindTasks;
  void Function()? _removeListener;
  void Function()? _windowHold;
  void Function()? _preparedWindow;
  void Function()? _preparedPage;
  Future<void>? _preparingWindow;
  bool _leaving = false;
  int _generation = 0;
  int _windowGeneration = 0;

  @override
  void initState() {
    super.initState();
    _removeListener = widget.work.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant ImageSaveBinding oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.work, widget.work)) return;
    _generation++;
    _windowGeneration++;
    _removeListener?.call();
    _unbindTasks?.call();
    _unbindTasks = null;
    _retire(oldWidget.work);
    _leaving = false;
    _removeListener = widget.work.addListener(_changed);
    _bindTasks();
    _joinClosingWindow();
  }

  void _unregisterWindow() {
    _window?.removeCloseStartListener(_holdWindow);
    _window?.removeCloseFailureListener(_resumeWindow);
    _window?.removeExitTask(_prepareWindow);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final registry = context
        .dependOnInheritedWidgetOfExactType<SelectionTasksScope>()
        ?.registry;
    final window = context
        .dependOnInheritedWidgetOfExactType<WindowFrameController>();
    // Inherited controller widgets can be rebuilt for the same host. Its bound
    // tracking callback identifies that host without invalidating preparation.
    if (window?.trackExitTask == _window?.trackExitTask) {
      if (_unbindTasks == null || registry != _registry) _bindTasks();
      return;
    }
    if (_windowHold != null) {
      _window?.trackExitTask(_prepareWindow());
    }
    _windowGeneration++;
    _unregisterWindow();
    _resumeWindow();
    _window = window;
    _bindTasks();
    window?.addCloseStartListener(_holdWindow);
    window?.addCloseFailureListener(_resumeWindow);
    window?.addExitTask(_prepareWindow);
    _joinClosingWindow();
  }

  void _bindTasks() {
    _unbindTasks?.call();
    final registry = context
        .getInheritedWidgetOfExactType<SelectionTasksScope>()
        ?.registry;
    _registry = registry;
    final window = _window;
    _unbindTasks = widget.work.bindTasks(
      canStart: () => registry?.isClosing != true && window?.isClosing != true,
      retain: (task) {
        final releaseHost = registry?.retain(
          cancel: task.cancel,
          close: task.closeAndWait,
        );
        window?.addCloseStartListener(task.cancel);
        window?.addExitTask(task.closeAndWait);
        return () {
          window?.removeCloseStartListener(task.cancel);
          window?.removeExitTask(task.closeAndWait);
          releaseHost?.call();
        };
      },
    );
  }

  void _joinClosingWindow() {
    if (_window?.isClosing != true) return;
    _holdWindow();
    // The host may already have snapshotted or called our exit callback.
    // Explicitly track newly mounted/replaced owners in that same close.
    _window!.trackExitTask(_prepareWindow());
  }

  void _holdWindow() {
    _windowHold ??= widget.work.holdForExit();
  }

  Future<void> _prepareWindow() {
    final work = widget.work;
    final generation = _windowGeneration;
    return _preparingWindow ??= () async {
      final release = await work.prepareForExit();
      if (!mounted || generation != _windowGeneration) {
        release();
      } else {
        _preparedWindow = release;
      }
    }();
  }

  void _resumeWindow() {
    final prepared = _preparedWindow;
    final hold = _windowHold;
    _preparedWindow = null;
    _windowHold = null;
    _preparingWindow = null;
    try {
      prepared?.call();
    } finally {
      hold?.call();
    }
  }

  Future<void> _leave() async {
    if (_leaving) return;
    final work = widget.work;
    final generation = _generation;
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    var popped = false;
    setState(() => _leaving = true);
    try {
      final release = await work.prepareForExit();
      if (!mounted || generation != _generation) {
        release();
        return;
      }
      _preparedPage = release;
      if (route?.isCurrent == true &&
          identical(ModalRoute.of(context), route) &&
          navigator.mounted &&
          NavigationAdmission.allows(context)) {
        navigator.pop();
        // LocalHistoryEntry may consume pop without removing this route.
        popped = route?.isCurrent != true;
      }
    } catch (error, stack) {
      Log.error(
        'Image save',
        'Failed to leave image save owner: $error',
        stack,
      );
      if (mounted && generation == _generation) {
        context.showMessage(message: 'Error'.tl);
      }
    } finally {
      if (mounted && generation == _generation && !popped) {
        _preparedPage?.call();
        _preparedPage = null;
        setState(() => _leaving = false);
      }
    }
  }

  void _retire(ImageSaveWork work) {
    final closing = work.dispose();
    _window?.trackExitTask(closing);
    _resumeWindow();
    _preparedPage?.call();
    _preparedPage = null;
    unawaited(
      closing.catchError((Object error, StackTrace stack) {
        Log.error(
          'Image save',
          'Failed to finish detached image save: $error',
          stack,
        );
      }),
    );
  }

  @override
  void dispose() {
    _generation++;
    _windowGeneration++;
    _removeListener?.call();
    _unbindTasks?.call();
    _unregisterWindow();
    _retire(widget.work);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_leaving && !widget.work.isBusy,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_leave());
    },
    child: AbsorbPointer(absorbing: _leaving, child: widget.child),
  );
}
