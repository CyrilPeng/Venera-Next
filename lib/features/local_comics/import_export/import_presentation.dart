import 'package:venera_next/components/message.dart';
import 'package:flutter/widgets.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/context.dart';

import 'pdf_import_dialog.dart';
import 'pdf_import_tasks.dart';

/// Headless imports have no presentation. Interactive imports keep the original
/// window/task; an old operation never adopts a replacement root navigator.
class ImportComicPresentation {
  const ImportComicPresentation() : _owner = null;
  const ImportComicPresentation.forTask(WindowSelectionTask owner)
    : _owner = owner;
  final WindowSelectionTask? _owner;

  void showMessage({required String message}) {
    final context = _owner?.presentationContext;
    if (context == null) return;
    context.showMessage(message: message);
  }

  LoadingDialogController? showLoading({
    void Function()? onCancel,
    bool allowCancel = true,
    bool withProgress = false,
    String? message,
  }) {
    final context = _owner?.presentationContext;
    if (context == null) return null;
    VoidCallback? detach;
    final controller = showLoadingDialog(
      context,
      onCancel: onCancel,
      allowCancel: allowCancel,
      withProgress: withProgress,
      message: message,
      onClosed: () => detach?.call(),
    );
    detach = _owner!.retainPresentation(
      controller.close,
      isCurrent: () => controller.isCurrent,
    );
    return controller;
  }

  Future<void> showPdfTask(PdfImportTask task) {
    final context = _owner?.presentationContext;
    if (context == null) return Future.value();
    return showPdfImportDialog(
      context: context,
      task: task,
      retainPresentation: (close, isCurrent) =>
          _owner!.retainPresentation(close, isCurrent: isCurrent),
    );
  }
}
