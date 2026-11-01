import 'dart:async';

import 'package:venera_next/components/message.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';

import 'pdf_import_dialog.dart';
import 'pdf_import_tasks.dart';
import 'copy_recovery_dialog.dart';
import 'comic_copy_record.dart';

/// Headless imports have no presentation. Interactive imports keep the original
/// window/task; an old operation never adopts a replacement root navigator.
class ImportComicPresentation {
  const ImportComicPresentation() : _owner = null;
  const ImportComicPresentation.forTask(WindowSelectionTask owner)
    : _owner = owner;
  final WindowSelectionTask? _owner;

  bool get canPresent => _owner?.presentationContext != null;

  Future<ComicCopyRecoveryChoice?> chooseCopyRecovery({
    required String title,
    required String? previousFolder,
    required List<String> folders,
    ComicCopyRecoveryKind kind = ComicCopyRecoveryKind.complete,
  }) async {
    final context = _owner?.presentationContext;
    if (context == null) return null;
    final choice = await showComicCopyRecoveryDialog(
      context: context,
      title: title,
      previousFolder: previousFolder,
      folders: folders,
      kind: kind,
      retainPresentation: (close, isCurrent) =>
          _owner!.retainPresentation(close, isCurrent: isCurrent),
    );
    return _owner!.canPresent ? choice : null;
  }

  void showMessage({required String message}) {
    final context = _owner?.presentationContext;
    if (context == null) return;
    context.showMessage(message: message);
  }

  Future<void> showResult({
    required int imported,
    required List<String> details,
  }) async {
    final context = _owner?.presentationContext;
    if (context == null) return;
    const detailLimit = 100;
    final visible = details.take(detailLimit).toList();
    if (details.length > detailLimit) {
      visible.add(
        'Showing @a of @b details'.tlParams({
          'a': detailLimit,
          'b': details.length,
        }),
      );
    }
    final disposed = Completer<void>();
    VoidCallback? detach;
    final route = ResourceDialogRoute<void>(
      context: context,
      barrierDismissible: false,
      onDispose: () {
        detach?.call();
        if (!disposed.isCompleted) disposed.complete();
      },
      builder: (dialogContext) => ContentDialog(
        title: 'Imported @a comics'.tlParams({'a': imported}),
        content: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: SelectableText(
            visible.isEmpty ? 'Done'.tl : visible.join('\n\n'),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () {
              if (_owner?.canPresent == true &&
                  ModalRoute.of(dialogContext)?.isCurrent == true) {
                dialogContext.pop();
              }
            },
            child: Text('OK'.tl),
          ),
        ],
      ),
    );
    detach = _owner!.retainPresentation(() {
      if (route.isActive) route.navigator?.removeRoute(route);
    }, isCurrent: () => route.isCurrent);
    try {
      // Navigator disposal need not complete push's Future. It must not retain
      // the import's selected files or temporary copies indefinitely.
      await Future.any([
        Navigator.of(context, rootNavigator: true).push(route),
        disposed.future,
      ]);
    } finally {
      detach();
    }
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
