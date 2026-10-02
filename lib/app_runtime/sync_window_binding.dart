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
    this.prepareDownloads,
    super.key,
  });
  final Future<VoidCallback> Function()? prepareDownloads;
  final Widget child;

  @override
  State<SyncWindowBinding> createState() => _SyncWindowBindingState();
}

class _SyncWindowBindingState extends State<SyncWindowBinding> {
  WindowFrameController? _window;
  VoidCallback? _releaseDownloads;

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
    final release =
        await (widget.prepareDownloads ??
            LocalManager.prepareDownloadsForExit)();
    if (!mounted) {
      release();
      return;
    }
    _releaseDownloads = release;
    try {
      await HistoryManager().waitForAsyncWrites();
      if (!mounted || !DataSync().isUploading) return;
      showLoadingDialog(
        App.rootContext,
        cancelButtonText: 'Shut Down'.tl,
        onCancel: _window!.forceExit,
        barrierDismissible: false,
        message: 'Uploading data...'.tl,
      );
      await DataSync().waitForUpload();
    } catch (_) {
      _releaseDownloads?.call();
      _releaseDownloads = null;
      rethrow;
    }
  }

  @override
  void dispose() {
    _window?.removeExitTask(_waitThenClose);
    _releaseDownloads?.call();
    _releaseDownloads = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
