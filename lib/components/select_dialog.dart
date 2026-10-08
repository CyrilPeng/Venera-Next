import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';

import 'message.dart';
import 'select.dart';
import 'window_selection_task.dart';

Future<int?> showSelectDialog({
  required BuildContext context,
  required String title,
  required List<String> options,
  int? initialIndex,
}) async {
  final task = WindowSelectionTask(context);
  final navigator = Navigator.of(context, rootNavigator: true);
  int? current = initialIndex;
  final disposed = Completer<int?>();
  final removalFailed = Completer<int?>();
  removalFailed.future.ignore();
  ResourceDialogRoute<void>? route;

  void finish() {
    if (!disposed.isCompleted) disposed.complete(null);
  }

  bool canAct() =>
      !disposed.isCompleted && task.canPresent && route?.isCurrent == true;

  try {
    return await task.run((operation) async {
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
              content: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Select(
                      current: current == null ? "" : options[current!],
                      values: options,
                      minWidth: 156,
                      onTap: (i) {
                        if (!canAct()) return;
                        setState(() => current = i);
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    if (!canAct()) return;
                    current = null;
                    navigator.pop();
                  },
                  child: Text('Cancel'.tl),
                ),
                FilledButton(
                  onPressed: current == null
                      ? null
                      : () {
                          if (canAct()) navigator.pop();
                        },
                  child: Text('Confirm'.tl),
                ),
              ],
            );
          },
        ),
      );
      final release = task.retainPresentation(() {
        try {
          current = null;
          if (navigator.mounted && dialog.isActive) {
            navigator.removeRoute(dialog);
          } else {
            finish();
          }
        } catch (error, stack) {
          if (!removalFailed.isCompleted) {
            removalFailed.completeError(error, stack);
          }
          rethrow;
        }
      }, isCurrent: () => dialog.isCurrent);
      // Ordinary back/barrier dismissal keeps the current choice. Disposal
      // without a pop and explicit host cancellation both return null.
      final closed = navigator.push(dialog).then<int?>((_) => current);
      final result = await Future.any<int?>([
        closed,
        disposed.future,
        removalFailed.future,
      ]);
      release();
      return result;
    });
  } on SelectionCancelled {
    return null;
  } finally {
    if (route?.navigator == null) finish();
  }
}
