import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

import 'button.dart';
import 'message.dart';
import 'window_selection_task.dart';

Future<void> showInputDialog({
  required BuildContext context,
  required String title,
  String? hintText,
  required FutureOr<Object?> Function(String) onConfirm,
  void Function()? onClosed,
  bool reportConfirmationFailureOnClose = false,
  String? initialValue,
  String confirmText = "Confirm",
  String cancelText = "Cancel",
  RegExp? inputValidator,
  String? image,
  Uint8List? imageData,
}) async {
  final task = WindowSelectionTask(context);
  final navigator = Navigator.of(context, rootNavigator: true);
  final controller = TextEditingController(text: initialValue);
  bool isLoading = false;
  bool confirmationFinished = false;
  bool resourcesDisposed = false;
  String? error;
  final disposed = Completer<void>();
  final removalFailed = Completer<void>();
  removalFailed.future.ignore();
  ResourceDialogRoute<void>? route;

  void finish() {
    if (resourcesDisposed) return;
    resourcesDisposed = true;
    controller.dispose();
    try {
      onClosed?.call();
    } finally {
      disposed.complete();
    }
  }

  bool canAct() =>
      !resourcesDisposed && task.canPresent && route?.isCurrent == true;

  try {
    await task.run((operation) async {
      operation.checkActive();
      final dialog = route = ResourceDialogRoute<void>(
        context: context,
        themes: InheritedTheme.capture(from: context, to: navigator.context),
        barrierColor: DialogTheme.of(context).barrierColor ?? Colors.black54,
        onDispose: finish,
        builder: (_) => StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: title,
              content: Column(
                children: [
                  if (image != null)
                    SizedBox(
                      height: 108,
                      child: Image.network(image, fit: BoxFit.none),
                    ).paddingBottom(8),
                  if (image == null && imageData != null)
                    SizedBox(
                      height: 108,
                      child: Image.memory(imageData, fit: BoxFit.none),
                    ).paddingBottom(8),
                  TextField(
                    controller: controller,
                    decoration: InputDecoration(
                      hintText: hintText,
                      border: const OutlineInputBorder(),
                      errorText: error,
                    ),
                  ).paddingHorizontal(12),
                ],
              ),
              actions: [
                Semantics(
                  button: true,
                  enabled: !isLoading,
                  label: isLoading ? confirmText.tl : null,
                  child: ExcludeSemantics(
                    excluding: isLoading,
                    child: Button.filled(
                      isLoading: isLoading,
                      onPressed: () async {
                        if (isLoading || !canAct()) return;
                        if (confirmationFinished) {
                          navigator.pop();
                          return;
                        }
                        if (inputValidator != null &&
                            !inputValidator.hasMatch(controller.text)) {
                          setState(() => error = "Invalid input".tl);
                          return;
                        }
                        final value = controller.text;
                        final confirmation = WindowSelectionTask(context);
                        setState(() {
                          isLoading = true;
                          error = null;
                        });
                        try {
                          final result = await confirmation.run<Object?>(
                            (operation) async {
                              operation.checkActive();
                              return onConfirm(value);
                            },
                            reportFailureOnClose:
                                reportConfirmationFailureOnClose,
                          );
                          confirmationFinished = result == null;
                          if (!context.mounted || !canAct()) return;
                          if (confirmationFinished) {
                            navigator.pop();
                          } else {
                            setState(() => error = result.toString());
                          }
                        } catch (failure, stack) {
                          if (failure is SelectionCancelled) return;
                          Log.error('Input confirmation', failure, stack);
                          confirmationFinished =
                              confirmationFinished ||
                              failure is PersistenceFailure &&
                                  failure.commitState !=
                                      PersistenceCommitState.notCommitted;
                          if (context.mounted && canAct()) {
                            setState(() => error = failure.toString());
                          }
                        } finally {
                          if (context.mounted) {
                            setState(() => isLoading = false);
                          }
                        }
                      },
                      child: Text(
                        confirmationFinished ? 'OK'.tl : confirmText.tl,
                      ),
                    ),
                  ),
                ),
              ],
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
        } catch (error, stack) {
          // Let the presentation waiter end so the host can report this close
          // failure and explicitly retry removing the same retained route.
          if (!removalFailed.isCompleted) {
            removalFailed.completeError(error, stack);
          }
          rethrow;
        }
      }, isCurrent: () => dialog.isCurrent);
      final closed = navigator.push(dialog);
      await Future.any<void>([closed, disposed.future, removalFailed.future]);
      release();
    });
  } on SelectionCancelled {
    // The original host can close before the deferred presentation begins.
  } finally {
    if (route?.navigator == null) finish();
  }
}
