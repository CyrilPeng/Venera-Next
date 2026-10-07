import 'dart:async';
import 'package:venera_next/features/sync/data_sync_controller.dart';
import 'webdav_library.dart';

/// The mounted application owns automatic sync scheduling, not transfer data.
class BackgroundSync {
  BackgroundSync({
    required this.startDataSync,
    required this.stopDataSync,
    required this.checkLibrary,
  });

  factory BackgroundSync.platform(DataSyncController sync) {
    return BackgroundSync(
      startDataSync: sync.start,
      stopDataSync: sync.stop,
      checkLibrary: webDavLibrary.source.synchronizer.checkForAutomaticSync,
    );
  }

  final void Function() startDataSync;
  final void Function() stopDataSync;
  final void Function() checkLibrary;
  Timer? _libraryTimer;
  bool _running = false;
  int _generation = 0;

  void start() {
    if (_running) return;
    _running = true;
    final generation = ++_generation;
    try {
      startDataSync();
      checkLibrary();
      if (!_running || generation != _generation) return;
      _libraryTimer = Timer.periodic(const Duration(minutes: 15), (_) {
        if (_running && generation == _generation) checkLibrary();
      });
    } catch (_) {
      stop();
      rethrow;
    }
  }

  void stop() {
    if (!_running) return;
    _running = false;
    _generation++;
    _libraryTimer?.cancel();
    _libraryTimer = null;
    stopDataSync();
  }
}
