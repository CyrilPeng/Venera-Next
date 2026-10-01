import 'dart:async';

import 'package:venera_next/features/reader/history_writer.dart';
import 'package:venera_next/features/reader/reading_session.dart';

/// Owns progress and duration lifetimes for one reader. Platform lifecycle
/// events are adapted to foreground state; content readiness is independent.
class ReaderSession {
  ReaderSession({
    required ReadingSessionTracker durations,
    required ReaderHistoryWriter progress,
    required void Function(bool paused) pauseAutoReading,
    required FutureOr<void> Function() onClosed,
    required bool foreground,
  }) : _durations = durations,
       _progress = progress,
       _pauseAutoReading = pauseAutoReading,
       _onClosed = onClosed,
       _foreground = foreground;

  final ReadingSessionTracker _durations;
  final ReaderHistoryWriter _progress;
  final void Function(bool) _pauseAutoReading;
  final FutureOr<void> Function() _onClosed;
  bool _foreground;
  bool _contentReady = false;
  bool _disposed = false;
  Future<void>? _closing;

  bool get contentReady => _contentReady;

  void setContentReady(bool ready) {
    if (_disposed) return;
    _contentReady = ready;
    _updateDuration();
  }

  void setForeground(bool foreground) {
    if (_disposed) return;
    _foreground = foreground;
    _pauseAutoReading(!foreground);
    _updateDuration();
  }

  void _updateDuration() {
    if (_foreground && _contentReady) {
      _durations.start();
    } else {
      unawaited(_durations.pause());
    }
  }

  void scheduleProgress() {
    if (!_disposed) _progress.schedule();
  }

  /// Submit pending progress immediately and stop the duration clock, then
  /// drain both writers before notifying the application once.
  Future<void> dispose() {
    if (_closing != null) return _closing!;
    _disposed = true;
    _contentReady = false;
    return _closing = Future.wait([
      _progress.dispose(),
      _durations.dispose(),
    ]).whenComplete(_onClosed).then((_) {});
  }
}
