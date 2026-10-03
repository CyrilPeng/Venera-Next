import 'package:flutter/widgets.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/translations.dart';

/// Window-close behavior exists only while the interactive window is mounted.
class SyncWindowBinding extends StatefulWidget {
  const SyncWindowBinding({
    required this.child,
    required this.controller,
    this.prepareDownloads,
    this.prepareImports,
    super.key,
  });
  final Future<VoidCallback> Function()? prepareDownloads;
  final Future<VoidCallback> Function()? prepareImports;
  final Widget child;
  final DataSyncController controller;

  @override
  State<SyncWindowBinding> createState() => _SyncWindowBindingState();
}

class _SyncWindowBindingState extends State<SyncWindowBinding> {
  WindowFrameController? _window;
  VoidCallback? _releaseDownloads;
  VoidCallback? _releaseImports;
  LoadingDialogController? _uploadDialog;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final window = WindowFrame.of(context);
    if (identical(window, _window)) return;
    _window?.removeExitTask(_waitThenClose);
    _window = window;
    window.addExitTask(_waitThenClose);
  }

  Future<void> _waitThenClose() async {
    final controller = widget.controller;
    try {
      final releaseImports =
          await (widget.prepareImports ?? prepareLocalImportsForExit)();
      if (!mounted) {
        releaseImports();
        return;
      }
      _releaseImports = releaseImports;
      final release =
          await (widget.prepareDownloads ??
              LocalManager.prepareDownloadsForExit)();
      if (!mounted) {
        release();
        return;
      }
      _releaseDownloads = release;
      await HistoryManager().waitForAsyncWrites();
      if (!mounted || !controller.isUploading) return;
      final rootContext = App.rootNavigatorKey.currentContext;
      if (rootContext != null && rootContext.mounted) {
        _uploadDialog = showLoadingDialog(
          rootContext,
          cancelButtonText: 'Shut Down'.tl,
          onCancel: () {
            if (mounted) _window?.forceExit();
          },
          // Removing a navigator must not be interpreted as forced shutdown.
          cancelOnDismiss: false,
          barrierDismissible: false,
          message: 'Uploading data...'.tl,
        );
      }
      await controller.waitForUpload();
    } catch (_) {
      _releasePreparedWork();
      rethrow;
    } finally {
      _uploadDialog?.close();
      _uploadDialog = null;
    }
  }

  void _releasePreparedWork() {
    final downloads = _releaseDownloads;
    final imports = _releaseImports;
    _releaseDownloads = null;
    _releaseImports = null;
    try {
      downloads?.call();
    } finally {
      imports?.call();
    }
  }

  @override
  void dispose() {
    _window?.removeExitTask(_waitThenClose);
    final dialog = _uploadDialog;
    _uploadDialog = null;
    // A surviving navigator may be reparented while this binding is disposed.
    // Close outside the framework's locked tree-finalization phase.
    if (dialog != null) Future.microtask(dialog.close);
    try {
      _releasePreparedWork();
    } finally {
      super.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
