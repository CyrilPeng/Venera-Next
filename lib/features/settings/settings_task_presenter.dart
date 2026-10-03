import 'package:flutter/widgets.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';

/// Owns one settings operation and its progress route until work finishes.
/// Closing the page does not cancel an already accepted storage operation.
class SettingsTaskPresenter {
  bool _running = false;

  Future<void> run(
    BuildContext context, {
    required Future<String?> Function() task,
    required String errorMessage,
    String? successMessage,
    VoidCallback? onSuccess,
  }) async {
    if (_running || !context.mounted) return;
    _running = true;
    final progress = showLoadingDialog(
      context,
      barrierDismissible: false,
      allowCancel: false,
    );
    String? failure;
    try {
      failure = await task();
    } catch (error, stack) {
      Log.error('Settings operation', error.toString(), stack);
      failure = errorMessage;
    } finally {
      progress.close();
      _running = false;
    }
    if (!context.mounted) return;
    if (failure != null) {
      context.showMessage(message: failure);
      return;
    }
    if (successMessage != null) context.showMessage(message: successMessage);
    onSuccess?.call();
  }
}
