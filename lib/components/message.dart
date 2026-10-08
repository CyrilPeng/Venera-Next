import 'package:venera_next/foundation/navigation_admission.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

import 'appbar.dart';
import 'button.dart';
import 'window_selection_task.dart';

void showToast({
  required String message,
  required BuildContext context,
  Widget? icon,
  Widget? trailing,
  int? seconds,
}) {
  var state = context.findAncestorStateOfType<OverlayWidgetState>();

  state?.showToast(
    message: message,
    icon: icon,
    trailing: trailing,
    seconds: seconds,
  );
}

class _ToastRecord {
  _ToastRecord({required this.message, this.icon, this.trailing});

  final String message;

  final Widget? icon;

  final Widget? trailing;

  final key = UniqueKey();

  Timer? timer;
}

class _ToastStack extends StatelessWidget {
  const _ToastStack({required this.toasts});

  final List<_ToastRecord> toasts;

  @override
  Widget build(BuildContext context) {
    var bottom = App.isMobile
        ? MediaQuery.of(context).size.height * 0.25 +
              MediaQuery.of(context).viewPadding.bottom
        : 24 + MediaQuery.of(context).viewInsets.bottom;
    return Positioned(
      bottom: bottom,
      left: 0,
      right: 0,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < toasts.length; i++)
              Padding(
                key: toasts[i].key,
                padding: EdgeInsets.only(
                  bottom: i == toasts.length - 1 ? 0 : 8,
                ),
                child: _ToastOverlay(toast: toasts[i]),
              ),
          ],
        ),
      ),
    );
  }
}

class _ToastOverlay extends StatelessWidget {
  const _ToastOverlay({required this.toast});

  final _ToastRecord toast;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.inverseSurface,
      borderRadius: BorderRadius.circular(8),
      elevation: 2,
      textStyle: ts.withColor(Theme.of(context).colorScheme.onInverseSurface),
      child: IconTheme(
        data: IconThemeData(
          color: Theme.of(context).colorScheme.onInverseSurface,
        ),
        child: IntrinsicWidth(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
            constraints: BoxConstraints(maxWidth: context.width - 32),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (toast.icon != null) toast.icon!.paddingRight(8),
                Expanded(
                  child: Text(
                    toast.message,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (toast.trailing != null) toast.trailing!.paddingLeft(8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class OverlayWidget extends StatefulWidget {
  const OverlayWidget(this.child, {super.key});

  final Widget child;

  @override
  State<OverlayWidget> createState() => OverlayWidgetState();
}

class OverlayWidgetState extends State<OverlayWidget> {
  final overlayKey = GlobalKey<OverlayState>();

  late final OverlayEntry _contentEntry;

  OverlayEntry? _toastEntry;

  final _toasts = <_ToastRecord>[];

  @override
  void initState() {
    super.initState();
    _contentEntry = OverlayEntry(builder: (context) => widget.child);
  }

  void showToast({
    required String message,
    Widget? icon,
    Widget? trailing,
    int? seconds,
  }) {
    if (overlayKey.currentState == null) {
      return;
    }
    final toast = _ToastRecord(
      message: message,
      icon: icon,
      trailing: trailing,
    );
    toast.timer = Timer(
      Duration(seconds: seconds ?? 2),
      () => _removeToast(toast),
    );
    _toasts.add(toast);
    _ensureToastEntry();
    _toastEntry?.markNeedsBuild();
  }

  void _ensureToastEntry() {
    if (_toastEntry != null) {
      return;
    }
    _toastEntry = OverlayEntry(
      builder: (context) => _ToastStack(toasts: List.of(_toasts)),
    );
    overlayKey.currentState!.insert(_toastEntry!);
  }

  void _removeToast(_ToastRecord toast) {
    toast.timer?.cancel();
    if (!_toasts.remove(toast)) {
      return;
    }
    if (_toasts.isEmpty) {
      final entry = _toastEntry;
      _toastEntry = null;
      entry?.remove();
      entry?.dispose();
    } else {
      _toastEntry?.markNeedsBuild();
    }
  }

  void removeAll() {
    for (var toast in List.of(_toasts)) {
      _removeToast(toast);
    }
  }

  @override
  void dispose() {
    try {
      removeAll();
      _contentEntry.remove();
      _contentEntry.dispose();
    } finally {
      super.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Overlay(key: overlayKey, initialEntries: [_contentEntry]);
  }
}

void showDialogMessage(BuildContext context, String title, String message) {
  showDialog(
    context: context,
    builder: (context) => ContentDialog(
      title: title,
      content: Text(message).paddingHorizontal(16),
      actions: [FilledButton(onPressed: context.pop, child: Text("OK".tl))],
    ),
  );
}

Future<void> showConfirmDialog({
  required BuildContext context,
  required String title,
  required String content,
  required void Function() onConfirm,
  String confirmText = "Confirm",
  Color? btnColor,
}) {
  return showDialog(
    context: context,
    builder: (context) => ContentDialog(
      title: title,
      content: Text(content).paddingHorizontal(16).paddingVertical(8),
      actions: [
        FilledButton(
          onPressed: () {
            context.pop();
            onConfirm();
          },
          style: FilledButton.styleFrom(backgroundColor: btnColor),
          child: Text(confirmText.tl),
        ),
      ],
    ),
  );
}

/// Route disposal runs even if the navigator disappears before the first build.
class ResourceDialogRoute<T> extends DialogRoute<T> {
  ResourceDialogRoute({
    required super.context,
    required super.builder,
    super.themes,
    super.barrierColor,
    super.barrierDismissible,
    required this.onDispose,
  });

  final VoidCallback onDispose;

  @override
  void dispose() {
    try {
      onDispose();
    } finally {
      super.dispose();
    }
  }
}

/// Releases dialog-owned resources even when its navigator is unmounted.
class DialogResourceScope extends StatefulWidget {
  const DialogResourceScope({
    super.key,
    required this.onDispose,
    required this.child,
  });
  final VoidCallback onDispose;
  final Widget child;
  @override
  State<DialogResourceScope> createState() => _DialogResourceScopeState();
}

class _DialogResourceScopeState extends State<DialogResourceScope> {
  @override
  void dispose() {
    try {
      widget.onDispose();
    } finally {
      super.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class LoadingDialogController {
  double? _progress;

  String? _message;

  void Function()? _closeDialog;

  void Function(double? value)? _serProgress;

  void Function(String message)? _setMessage;

  bool closed = false;
  bool Function()? _isCurrent;
  bool get isCurrent => !closed && (_isCurrent?.call() ?? false);

  void close() {
    if (closed) {
      return;
    }
    closed = true;
    final closeDialog = _closeDialog;
    try {
      closeDialog?.call();
    } catch (_) {
      // Keep the original route callback retryable if removal failed before
      // finish disposed it. Reentrant close still observes the closed flag.
      if (identical(_closeDialog, closeDialog)) closed = false;
      rethrow;
    }
  }

  void setProgress(double? value) {
    if (closed) {
      return;
    }
    _serProgress?.call(value);
  }

  void setMessage(String message) {
    if (closed) {
      return;
    }
    _setMessage?.call(message);
  }
}

LoadingDialogController showLoadingDialog(
  BuildContext context, {
  void Function()? onCancel,
  void Function()? onClosed,
  bool barrierDismissible = true,
  bool allowCancel = true,
  // Button cancellation is always explicit; optionally suppress cancellation
  // when the route is dismissed or its navigator is unmounted.
  bool cancelOnDismiss = true,
  String? message,
  String cancelButtonText = "Cancel",
  bool withProgress = false,
}) {
  var controller = LoadingDialogController();
  controller._message = message;

  if (withProgress) {
    controller._progress = 0;
  }

  var finished = false;
  var cancellationStarted = false;
  var isCancelling = false;
  WindowSelectionTask? inputOwner;
  void cancel() {
    if (cancellationStarted) return;
    cancellationStarted = true;
    onCancel?.call();
  }

  void finish() {
    if (finished) return;
    finished = true;
    final wasClosed = controller.closed;
    controller.closed = true;
    controller._closeDialog = null;
    controller._serProgress = null;
    controller._setMessage = null;
    controller._isCurrent = null;
    try {
      if (!wasClosed && cancelOnDismiss) cancel();
    } finally {
      onClosed?.call();
    }
  }

  var loadingDialogRoute = ResourceDialogRoute<void>(
    context: context,
    barrierDismissible: barrierDismissible,
    onDispose: finish,
    builder: (BuildContext context) {
      return StatefulBuilder(
        builder: (context, setState) {
          inputOwner ??= WindowSelectionTask(context);
          controller._serProgress = (value) {
            if (finished || !context.mounted) return;
            setState(() {
              controller._progress = value;
            });
          };
          controller._setMessage = (message) {
            if (finished || !context.mounted) return;
            setState(() {
              controller._message = message;
            });
          };
          return ContentDialog(
            title: controller._message ?? 'Loading'.tl,
            content: LinearProgressIndicator(
              value: controller._progress,
              backgroundColor: context.colorScheme.surfaceContainer,
            ).paddingHorizontal(16).paddingVertical(16),
            actions: [
              FilledButton(
                onPressed: allowCancel
                    ? () {
                        if (isCancelling ||
                            controller.closed ||
                            !controller.isCurrent ||
                            inputOwner?.canPresent != true) {
                          return;
                        }
                        isCancelling = true;
                        try {
                          cancel();
                        } finally {
                          try {
                            controller.close();
                          } finally {
                            isCancelling = false;
                          }
                        }
                      }
                    : null,
                child: Text(cancelButtonText.tl),
              ),
            ],
          );
        },
      );
    },
  );

  var navigator = Navigator.of(context, rootNavigator: true);
  controller._isCurrent = () => loadingDialogRoute.isCurrent;

  navigator.push(loadingDialogRoute).then((_) => finish());

  controller._closeDialog = () {
    if (navigator.mounted && loadingDialogRoute.isActive) {
      navigator.removeRoute(loadingDialogRoute);
    } else {
      finish();
    }
  };

  return controller;
}

class ContentDialog extends StatelessWidget {
  const ContentDialog({
    super.key,
    this.title, // 如果不传 title 将不会展示
    required this.content,
    this.dismissible = true,
    this.actions = const [],
  });

  final String? title;

  final Widget content;

  final List<Widget> actions;

  final bool dismissible;

  @override
  Widget build(BuildContext context) {
    var content = SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          title != null
              ? Appbar(
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: dismissible
                        ? () {
                            if (NavigationAdmission.allows(context) &&
                                ModalRoute.of(context)?.isCurrent != false) {
                              Navigator.of(context).maybePop();
                            }
                          }
                        : null,
                  ),
                  title: Text(title!),
                  backgroundColor: Colors.transparent,
                )
              : const SizedBox.shrink(),
          this.content,
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: actions,
          ).paddingRight(12),
          const SizedBox(height: 16),
        ],
      ),
    );
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: context.brightness == Brightness.dark
            ? BorderSide(color: context.colorScheme.outlineVariant)
            : BorderSide.none,
      ),
      insetPadding: context.width < 400
          ? const EdgeInsets.symmetric(horizontal: 4)
          : const EdgeInsets.symmetric(horizontal: 16),
      elevation: 2,
      shadowColor: context.colorScheme.shadow,
      backgroundColor: context.colorScheme.surface,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.topCenter,
        child: IntrinsicWidth(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 600,
              minWidth: math.min(400, context.width - 16),
            ),
            child: MediaQuery.removePadding(
              removeTop: true,
              removeBottom: true,
              context: context,
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

void showInfoDialog({
  required BuildContext context,
  required String title,
  required String content,
  String confirmText = "OK",
}) {
  showDialog(
    context: context,
    builder: (context) {
      return ContentDialog(
        title: title,
        content: Text(content).paddingHorizontal(16).paddingVertical(8),
        actions: [
          Button.filled(onPressed: context.pop, child: Text(confirmText.tl)),
        ],
      );
    },
  );
}
