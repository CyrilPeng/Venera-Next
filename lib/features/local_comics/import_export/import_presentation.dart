import 'package:venera_next/components/message.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/context.dart';

import 'pdf_import_dialog.dart';
import 'pdf_import_tasks.dart';

/// Presentation for application-owned imports. Resolve the current root only
/// when displaying UI; a removed navigator must not invalidate completed work.
class ImportComicPresentation {
  const ImportComicPresentation();

  void showMessage({required String message}) {
    final context = App.rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    context.showMessage(message: message);
  }

  LoadingDialogController? showLoading({
    void Function()? onCancel,
    bool allowCancel = true,
    bool withProgress = false,
    String? message,
  }) {
    final context = App.rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return null;
    return showLoadingDialog(
      context,
      onCancel: onCancel,
      allowCancel: allowCancel,
      withProgress: withProgress,
      message: message,
    );
  }

  Future<void> showPdfTask(PdfImportTask task) {
    final context = App.rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return Future.value();
    return showPdfImportDialog(context: context, task: task);
  }
}
