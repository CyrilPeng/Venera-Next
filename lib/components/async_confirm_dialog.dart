import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

import 'button.dart';
import 'message.dart';
import 'window_selection_task.dart';

/// Joins the presentation and its last accepted confirmation. Only a known
/// uncommitted failure may repeat an incremental mutation.
Future<void> showAsyncConfirmDialog({
  required BuildContext context,
  required String title,
  required String content,
  required Future<void> Function() onConfirm,
  Color? btnColor,
  Widget Function(BuildContext context, bool enabled)? contentBuilder,
}) {
  final result = _showAsyncConfirmDialog(
    context: context,
    title: title,
    content: content,
    onConfirm: onConfirm,
    btnColor: btnColor,
    contentBuilder: contentBuilder,
  );
  unawaited(
    result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        Log.error('Confirmation presentation', error, stack);
      },
    ),
  );
  return result;
}

Future<void> _showAsyncConfirmDialog({
  required BuildContext context,
  required String title,
  required String content,
  required Future<void> Function() onConfirm,
  Color? btnColor,
  Widget Function(BuildContext context, bool enabled)? contentBuilder,
}) async {
  if (!context.mounted) return;
  final task = WindowSelectionTask(context);
  if (!task.canPresent) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  final disposed = Completer<void>();
  final removalFailed = Completer<void>();
  removalFailed.future.ignore();
  ResourceDialogRoute<void>? route;
  Future<void>? confirmationSettled;
  bool finished = false;
  bool saving = false;
  bool confirmationFinished = false;
  String? error;
  WindowSelectionTask? dialogOwner;

  void finish() {
    if (finished) return;
    finished = true;
    disposed.complete();
  }

  bool canConfirm() => !finished && task.canPresent && route?.isCurrent == true;
  bool canDismiss() =>
      !finished && dialogOwner?.canPresent == true && route?.isCurrent == true;

  try {
    await task.run((operation) async {
      operation.checkActive();
      final dialog = route = ResourceDialogRoute<void>(
        context: context,
        themes: InheritedTheme.capture(from: context, to: navigator.context),
        barrierColor: DialogTheme.of(context).barrierColor ?? Colors.black54,
        barrierDismissible: false,
        onDispose: finish,
        builder: (_) => StatefulBuilder(
          builder: (context, setState) {
            dialogOwner ??= WindowSelectionTask(context);
            void showFailure(Object failure, StackTrace stack) {
              Log.error('Confirm operation', failure, stack);
              error = failure.toString();
              if (context.mounted && !finished) setState(() {});
            }

            void dismiss() {
              if (saving || !canDismiss()) return;
              try {
                navigator.pop();
              } catch (failure, stack) {
                showFailure(failure, stack);
              }
            }

            return NavigationAdmission(
              allowsNavigation: () => !saving && canDismiss(),
              child: PopScope(
                canPop: !saving,
                child: ContentDialog(
                  title: title,
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      contentBuilder?.call(
                            context,
                            !saving && !confirmationFinished && canConfirm(),
                          ) ??
                          Text(content),
                      if (error != null) Text(error!),
                    ],
                  ).paddingHorizontal(16).paddingVertical(8),
                  actions: [
                    Flexible(
                      child: Wrap(
                        alignment: WrapAlignment.end,
                        runSpacing: 8,
                        children: [
                          TextButton(
                            onPressed: saving ? null : dismiss,
                            child: Text('Cancel'.tl),
                          ),
                          Semantics(
                            button: true,
                            enabled: !saving,
                            label: saving ? 'Confirm'.tl : null,
                            child: ExcludeSemantics(
                              excluding: saving,
                              child: Button.filled(
                                color: btnColor,
                                isLoading: saving,
                                onPressed: () async {
                                  if (saving) return;
                                  if (confirmationFinished) {
                                    dismiss();
                                    return;
                                  }
                                  if (!canConfirm()) return;
                                  final confirmation = WindowSelectionTask(
                                    context,
                                  );
                                  setState(() {
                                    saving = true;
                                    error = null;
                                  });
                                  final ended = Completer<void>();
                                  confirmationSettled = ended.future;
                                  try {
                                    await confirmation.run<void>((
                                      operation,
                                    ) async {
                                      operation.checkActive();
                                      await onConfirm();
                                    }, reportFailureOnClose: true);
                                    confirmationFinished = true;
                                    if (canDismiss()) navigator.pop();
                                  } catch (failure, stack) {
                                    if (failure is SelectionCancelled) return;
                                    confirmationFinished =
                                        confirmationFinished ||
                                        failure is PersistenceFailure &&
                                            failure.commitState !=
                                                PersistenceCommitState
                                                    .notCommitted;
                                    showFailure(failure, stack);
                                  } finally {
                                    saving = false;
                                    try {
                                      if (context.mounted && !finished) {
                                        setState(() {});
                                      }
                                    } finally {
                                      ended.complete();
                                    }
                                  }
                                },
                                child: Text(
                                  confirmationFinished ? 'OK'.tl : 'Confirm'.tl,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
      final release = task.retainPresentation(() {
        try {
          if (navigator.mounted && dialog.isActive) {
            navigator.removeRoute(dialog);
          } else {
            finish();
          }
        } catch (failure, stack) {
          if (!removalFailed.isCompleted) {
            removalFailed.completeError(failure, stack);
          }
          rethrow;
        }
      }, isCurrent: () => dialog.isCurrent);
      final closed = navigator.push(dialog);
      await Future.any<void>([closed, disposed.future, removalFailed.future]);
      release();
    });
  } on SelectionCancelled {
    // Closing can retire the original host before presentation is admitted.
  } finally {
    if (route?.navigator == null) finish();
    // The caller may replace its keyed page after this returns. Finish using
    // its context even when the route was removed during an accepted write.
    await confirmationSettled;
  }
}
