import 'package:flutter/widgets.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/translations.dart';

/// Window-close behavior exists only while the interactive window is mounted.
class SyncWindowBinding extends StatefulWidget {
  const SyncWindowBinding({
    required this.child,
    required this.onExit,
    super.key,
  });
  final Widget child;
  final VoidCallback onExit;

  @override
  State<SyncWindowBinding> createState() => _SyncWindowBindingState();
}

class _SyncWindowBindingState extends State<SyncWindowBinding> {
  WindowFrameController? _window;
  bool _closing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final window = WindowFrame.of(context);
    if (identical(window, _window)) return;
    _window?.removeCloseListener(_handleClose);
    _window = window;
    window.addCloseListener(_handleClose);
  }

  bool _handleClose() {
    if (_closing) return false;
    if (!DataSync().isUploading) return true;
    _closing = true;
    _waitThenClose();
    return false;
  }

  Future<void> _waitThenClose() async {
    showLoadingDialog(
      App.rootContext,
      cancelButtonText: 'Shut Down'.tl,
      onCancel: widget.onExit,
      barrierDismissible: false,
      message: 'Uploading data...'.tl,
    );
    await DataSync().waitForUpload();
    if (mounted) widget.onExit();
  }

  @override
  void dispose() {
    _window?.removeCloseListener(_handleClose);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
