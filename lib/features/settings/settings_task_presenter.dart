import 'package:flutter/widgets.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';

/// Owns one settings operation and its progress route until work finishes.
/// Closing the page does not cancel an already accepted storage operation.
class SettingsTaskPresenter {
  bool _running = false;

  Future<void> run(
    BuildContext context, {
    required Future<String?> Function(SelectionOperation) task,
    required String errorMessage,
    String? successMessage,
    VoidCallback? onSuccess,
  }) async {
    if (_running || !context.mounted) return;
    final owner = WindowSelectionTask(context);
    if (!owner.canPresent) return;
    _running = true;
    String? failure;
    try {
      failure = await owner.run((operation) {
        final progress = showLoadingDialog(
          context,
          barrierDismissible: false,
          allowCancel: false,
        );
        owner.retainPresentation(
          progress.close,
          isCurrent: () => progress.isCurrent,
        );
        operation.checkActive();
        return task(operation);
      });
    } on SelectionCancelled {
      return;
    } catch (error, stack) {
      Log.error('Settings operation', error, stack);
      failure = errorMessage;
    } finally {
      _running = false;
    }
    if (!context.mounted || !owner.canPresent) return;
    if (failure != null) {
      context.showMessage(message: failure);
      return;
    }
    if (successMessage != null) context.showMessage(message: successMessage);
    onSuccess?.call();
  }
}
