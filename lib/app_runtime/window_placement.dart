import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/material.dart' show Colors, Size;
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/window_placement.dart';
import 'package:venera_next/foundation/window_placement_tracker.dart';
import 'package:window_manager/window_manager.dart';

/// One native window owns initialization and the handoff between widget mounts.
class WindowPlacementHost {
  WindowPlacementHost({
    required Future<void> Function() initialize,
    required Future<WindowPlacement?> Function() read,
    required Future<void> Function(WindowPlacement placement) save,
    this.onError = _logError,
  }) : _initializeWindow = initialize,
       _read = read,
       _save = save {
    // Initialization can fail before a widget has attached. Keep the original
    // failure for initialize()/trackers without creating an unobserved Future.
    unawaited(_ready.future.then<void>((_) {}, onError: (Object _) {}));
  }

  factory WindowPlacementHost.platform({
    required String dataPath,
    required bool linux,
    required bool macos,
    void Function(Object error, StackTrace stack) onError = _logError,
  }) {
    // Capture the host's destination; a later global path change cannot redirect
    // an already accepted write to another window's data directory.
    final file = File('$dataPath/window_placement');
    return WindowPlacementHost(
      initialize: () async {
        await windowManager.ensureInitialized();
        await windowManager.setPreventClose(true);
        // The plugin's optional callback is void; await our whole restore chain
        // outside it, once per native host rather than once per widget mount.
        await windowManager.waitUntilReadyToShow();
        await windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: macos,
        );
        if (linux) await windowManager.setBackgroundColor(Colors.transparent);
        await windowManager.setMinimumSize(const Size(500, 600));
        WindowPlacement placement;
        try {
          placement = WindowPlacement.fromJson(
            jsonDecode(await file.readAsString()),
          );
        } catch (_) {
          placement = WindowPlacement.defaultPlacement;
        }
        Future<void> apply() async {
          await windowManager.setBounds(placement.rect);
          if (!WindowPlacement.validate(placement.rect)) {
            await windowManager.center();
          }
          if (placement.isMaximized) await windowManager.maximize();
        }

        if (linux) {
          await windowManager.show();
          await apply();
        } else {
          await apply();
          await windowManager.show();
        }
      },
      read: () async {
        // A minimized Windows window reports isMaximized=false and may return
        // sentinel bounds. Preserve its last visible placement instead.
        if (await windowManager.isMinimized()) return null;
        final bounds = await windowManager.getBounds();
        final maximized = await windowManager.isMaximized();
        if (await windowManager.isMinimized()) return null;
        return WindowPlacement(bounds, maximized);
      },
      save: (placement) async {
        await file.writeAsString(jsonEncode(placement.toJson()));
      },
      onError: onError,
    );
  }

  final Future<void> Function() _initializeWindow;
  final Future<WindowPlacement?> Function() _read;
  final Future<void> Function(WindowPlacement placement) _save;
  final void Function(Object error, StackTrace stack) onError;
  final _ready = Completer<void>();
  Future<void>? _initialization;
  Future<void> _handoff = Future.value();
  WindowPlacementTracker? _current;
  Rect? _lastValidRect;
  ({Object error, StackTrace stack})? _writeFailure;

  static void _logError(Object error, StackTrace stack) =>
      Log.error('Window placement', error, stack);

  void _reportError(Object error, StackTrace stack) {
    try {
      onError(error, stack);
    } catch (reportError, reportStack) {
      Zone.current.handleUncaughtError(reportError, reportStack);
    }
  }

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      await _initializeWindow();
      _ready.complete();
    } catch (error, stack) {
      _ready.completeError(error, stack);
      rethrow;
    }
  }

  Future<WindowPlacement?> _readSnapshot() async {
    final current = await _read();
    if (current == null) {
      final failure = _writeFailure;
      if (failure != null) {
        // A failed overwrite may have truncated the file. A new mount that
        // cannot sample while minimized must not acknowledge the old write.
        Error.throwWithStackTrace(failure.error, failure.stack);
      }
      return null;
    }
    if (WindowPlacement.validate(current.rect)) _lastValidRect = current.rect;
    // This fallback belongs to the native window, not one widget mount. A
    // maximized window can report negative borders across a remount. Handoff
    // serializes reads so even the old mount's late valid bounds are retained.
    return WindowPlacement(
      _lastValidRect ?? WindowPlacement.defaultPlacement.rect,
      current.isMaximized,
    );
  }

  Future<void> _saveSnapshot(WindowPlacement placement) async {
    try {
      await _save(placement);
      _writeFailure = null;
    } catch (error, stack) {
      _writeFailure = (error: error, stack: stack);
      rethrow;
    }
  }

  WindowPlacementTracker attach() {
    final previous = _current;
    if (previous != null) {
      // Stop immediately, even while waiting for an earlier mount's drain.
      final disposed = previous.dispose();
      _handoff = Future.wait<void>([
        _handoff,
        disposed.then<void>((_) {}, onError: _reportError),
      ]);
    }
    // Keep the entire predecessor chain. An intermediate tracker disposed while
    // waiting for ready must not let a third mount bypass the oldest writer.
    final ready = Future.wait<void>([_ready.future, _handoff]);
    final tracker = WindowPlacementTracker(
      ready: ready,
      read: _readSnapshot,
      save: _saveSnapshot,
      onError: _reportError,
    );
    _current = tracker;
    return tracker;
  }
}
