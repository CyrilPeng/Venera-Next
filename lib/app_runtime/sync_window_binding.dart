import 'package:flutter/widgets.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/translations.dart';

/// Window-close behavior exists only while the interactive window is mounted.
class SyncWindowBinding extends StatefulWidget {
  const SyncWindowBinding({required this.child, super.key});
  final Widget child;

  @override
  State<SyncWindowBinding> createState() => _SyncWindowBindingState();
}

class _SyncWindowBindingState extends State<SyncWindowBinding> {
  WindowFrameController? _window;

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
  }

  @override
  void dispose() {
    _window?.removeExitTask(_waitThenClose);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
