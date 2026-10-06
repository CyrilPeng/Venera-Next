import 'package:flutter/widgets.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/follow_updates/follow_updates.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';

/// Window-close behavior exists only while the interactive window is mounted.
class SyncWindowBinding extends StatefulWidget {
  const SyncWindowBinding({
    required this.child,
    required this.controller,
    this.isFinalizing,
    this.prepareInteractive,
    this.prepareFollowUpdates,
    this.prepareWebDavLibrary,
    this.prepareDownloads,
    this.prepareImages,
    this.prepareImports,
    this.cancelStartupUpdates,
    this.closeStartupUpdates,
    super.key,
  });
  final Future<VoidCallback> Function()? prepareInteractive;
  final Future<VoidCallback> Function()? prepareFollowUpdates;
  final Future<VoidCallback> Function()? prepareWebDavLibrary;
  final Future<VoidCallback> Function()? prepareDownloads;
  final Future<VoidCallback> Function()? prepareImages;
  final Future<VoidCallback> Function()? prepareImports;
  final VoidCallback? cancelStartupUpdates;
  final Future<void> Function()? closeStartupUpdates;
  final Widget child;
  final DataSyncController controller;
  final bool Function()? isFinalizing;

  @override
  State<SyncWindowBinding> createState() => _SyncWindowBindingState();
}

class _SyncWindowBindingState extends State<SyncWindowBinding> {
  WindowFrameController? _window;
  VoidCallback? _releaseSync;
  VoidCallback? _releaseInteractive;
  VoidCallback? _releaseFollowUpdates;
  VoidCallback? _releaseWebDavLibrary;
  VoidCallback? _releaseDownloads;
  VoidCallback? _releaseImages;
  VoidCallback? _releaseImports;
  bool _preparing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final window = WindowFrame.of(context);
    if (identical(window, _window)) return;
    _window?.removeExitTask(_waitThenClose);
    _window?.removeCloseFailureListener(_releasePreparedWork);
    _window?.removeCloseStartListener(_cancelStartupUpdates);
    _window = window;
    window.addExitTask(_waitThenClose);
    window.addCloseFailureListener(_releasePreparedWork);
    window.addCloseStartListener(_cancelStartupUpdates);
    if (window.isClosing) _cancelStartupUpdates();
  }

  void _cancelStartupUpdates() => widget.cancelStartupUpdates?.call();

  Future<void> _waitThenClose() async {
    final controller = widget.controller;
    _preparing = true;
    try {
      await widget.closeStartupUpdates?.call();
      if (!mounted) return;
      final prepareInteractive = widget.prepareInteractive;
      if (prepareInteractive != null) {
        _releaseInteractive = await prepareInteractive();
        if (!mounted) return;
      }
      _releaseFollowUpdates =
          await (widget.prepareFollowUpdates ??
              FollowUpdateJob.prepareForExit)();
      if (!mounted) return;
      final prepareWebDavLibrary = widget.prepareWebDavLibrary;
      if (prepareWebDavLibrary != null) {
        _releaseWebDavLibrary = await prepareWebDavLibrary();
        if (!mounted) return;
      }
      _releaseImports =
          await (widget.prepareImports ?? prepareLocalImportsForExit)();
      if (!mounted) return;
      _releaseDownloads =
          await (widget.prepareDownloads ??
              LocalManager.prepareDownloadsForExit)();
      if (!mounted) return;
      final prepareImages = widget.prepareImages;
      if (prepareImages != null) {
        _releaseImages = await prepareImages();
        if (!mounted) return;
      }
      await HistoryManager().waitForAsyncWrites();
      if (!mounted) return;
      _releaseSync = await controller.prepareForExit();
    } catch (_) {
      _releasePreparedWork();
      rethrow;
    } finally {
      _preparing = false;
      if (!mounted) _releasePreparedWork();
    }
  }

  void _releasePreparedWork() {
    if (widget.isFinalizing?.call() == true) return;
    final sync = _releaseSync;
    _releaseSync = null;
    final images = _releaseImages;
    _releaseImages = null;
    final downloads = _releaseDownloads;
    final imports = _releaseImports;
    final webDavLibrary = _releaseWebDavLibrary;
    final followUpdates = _releaseFollowUpdates;
    final interactive = _releaseInteractive;
    _releaseDownloads = null;
    _releaseImports = null;
    _releaseWebDavLibrary = null;
    _releaseFollowUpdates = null;
    _releaseInteractive = null;
    try {
      sync?.call();
    } finally {
      try {
        images?.call();
      } finally {
        try {
          downloads?.call();
        } finally {
          try {
            imports?.call();
          } finally {
            try {
              webDavLibrary?.call();
            } finally {
              try {
                followUpdates?.call();
              } finally {
                interactive?.call();
              }
            }
          }
        }
      }
    }
  }

  @override
  void dispose() {
    _window?.removeCloseStartListener(_cancelStartupUpdates);
    _window?.removeExitTask(_waitThenClose);
    _window?.removeCloseFailureListener(_releasePreparedWork);
    try {
      // A pending hold must finish before earlier owners resume producing work.
      // The preparation finally releases all holds after detachment.
      if (!_preparing) _releasePreparedWork();
    } finally {
      super.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
