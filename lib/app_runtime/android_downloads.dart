import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';
import 'package:venera_next/features/local_comics/download_task.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/log.dart';

/// Binds the existing Dart/JS queue to Android's foreground execution lifetime.
/// No headless engine or second queue is created; restored tasks stay paused.
class AndroidDownloads with WidgetsBindingObserver {
  AndroidDownloads({
    required this.manager,
    this.channel = const MethodChannel('venera/downloads'),
  });

  final LocalManager manager;
  final MethodChannel channel;
  final String _owner = const Uuid().v4();
  static AndroidDownloads? _current;
  DownloadTask? _task;
  Timer? _heartbeat;
  Future<void>? _pending;
  Future<void>? _closing;
  bool _started = false;
  bool _closed = false;
  bool _bound = false;
  int _revision = 0;
  int _handledRevision = 0;
  int _nextSession = 0;
  int? _session;
  int? _nativeSession;
  int? _attemptedSession;
  bool _starting = false;

  bool get _ownsChannel => !_closed && identical(_current, this);

  void start() {
    if (_closed) throw StateError('Android download binding is closed');
    if (_started) return;
    _started = true;
    _current = this;
    channel.setMethodCallHandler(_handleEvent);
    WidgetsBinding.instance.addObserver(this);
    manager.addListener(_changed);
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) => _changed());
    _changed();
  }

  void _changed() {
    if (!_ownsChannel) return;
    final first = manager.currentDownloadingTask;
    if (!identical(first, _task)) {
      _task?.removeListener(_changed);
      _task = first;
      first?.addListener(_changed);
    }
    _revision++;
    _pending ??= Future<void>.microtask(_drain)
        .catchError((Object error, StackTrace stack) {
          _handledRevision = _revision;
          _reportError(error, stack);
        })
        .whenComplete(() {
          _pending = null;
          if (_ownsChannel && _handledRevision != _revision) _changed();
        });
  }

  Map<String, Object> _arguments(int session) => {
    'owner': _owner,
    'session': session,
    'progress': ((_task?.progress ?? 0).clamp(0, 1) * 1000).round(),
    'waiting': _task?.isWaitingToRetry ?? false,
  };

  Future<void> _drain() async {
    if (!_ownsChannel) return;
    if (!_bound) {
      // A partially failed bind can still own native resources and needs dispose.
      _bound = true;
      await channel.invokeMethod<void>('bind', {'owner': _owner});
    }
    while (_ownsChannel && _handledRevision != _revision) {
      _handledRevision = _revision;
      // Coalesce completion -> next task -> resume in the same synchronous
      // turn, so a queue advancing in the background keeps its existing lease.
      final active =
          _task != null &&
          (!_task!.isPaused || manager.isDownloadResumePending);
      if (!active) {
        final native = _nativeSession;
        _session = _nativeSession = _attemptedSession = null;
        if (native != null) {
          await channel.invokeMethod<void>('stop', _arguments(native));
        }
        continue;
      }
      final session = _session ??= ++_nextSession;
      if (_nativeSession == session) {
        await channel.invokeMethod<void>('update', _arguments(session));
      } else if (_attemptedSession != session) {
        _attemptedSession = session;
        _starting = true;
        try {
          final started = await channel.invokeMethod<bool>(
            'start',
            _arguments(session),
          );
          if (started == true) {
            if (_session == session) {
              _nativeSession = session;
            } else {
              await channel.invokeMethod<void>('stop', _arguments(session));
            }
          } else {
            Log.warning(
              'Download background',
              'Foreground start was refused. '
                  'Downloads remain available in the app; return to the foreground to retry.',
            );
          }
        } catch (error, stack) {
          _reportError(error, stack);
        } finally {
          _starting = false;
        }
      }
    }
  }

  Future<void> _handleEvent(MethodCall call) async {
    if (!_ownsChannel) return;
    final data = call.arguments;
    if (data is! Map || data['owner'] != _owner) return;
    if (call.method == 'networkAvailable') {
      _task?.retryNow();
    } else if (call.method == 'stopped' && data['session'] == _session) {
      _session = _nativeSession = _attemptedSession = null;
      final task = _task;
      if (task == null) return;
      Log.warning(
        'Download background',
        'Download service stopped: ${data['reason']}',
      );
      try {
        // pause is synchronous; queued network events cannot revive this task.
        await manager.pauseDownload(task);
        await manager.saveCurrentDownloadingTasks();
        await manager.pendingDownloadTaskWrites;
      } catch (error, stack) {
        _reportError(error, stack);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_ownsChannel || state != AppLifecycleState.resumed) return;
    if (!_starting && _nativeSession == null) {
      _session = _attemptedSession = null;
    }
    _task?.retryNow();
    _changed();
  }

  static void _reportError(Object error, StackTrace stack) =>
      Log.error('Download background', error, stack);

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _heartbeat?.cancel();
    if (_started) {
      WidgetsBinding.instance.removeObserver(this);
      manager.removeListener(_changed);
      _task?.removeListener(_changed);
      if (identical(_current, this)) {
        _current = null;
        channel.setMethodCallHandler(null);
      }
    }
    await _pending;
    if (_bound) {
      await channel.invokeMethod<void>('dispose', {'owner': _owner});
    }
  }
}
