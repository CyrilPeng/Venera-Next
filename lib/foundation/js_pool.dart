import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/foundation/log.dart';

abstract class JsPoolEngine {
  int get pendingTasks;

  Future<dynamic> execute(String jsFunction, List<dynamic> args);

  Future<void> close();
}

class JSPool {
  static final int _maxInstances = 4;
  final List<JsPoolEngine> _instances = [];
  Future<void>? _initFuture;
  Future<void>? _closeFuture;
  int _generation = 0;
  bool _cleanupRequired = false;

  /// Owns workers produced by this factory, including partial startup.
  JSPool.create({
    required Future<Uint8List> Function() loadJsInit,
    required JsPoolEngine Function(Uint8List) createEngine,
  }) : _loadJsInit = loadJsInit,
       _createEngine = createEngine;

  final Future<Uint8List> Function() _loadJsInit;
  final JsPoolEngine Function(Uint8List) _createEngine;

  Future<void> init() {
    if (_closeFuture != null) {
      return Future.error(StateError('JS pool is closing'));
    }
    if (_cleanupRequired) {
      return Future.error(
        StateError('JS pool requires failed resource cleanup'),
      );
    }
    if (_instances.isNotEmpty) {
      return Future.value();
    }
    return _initFuture ??= _init();
  }

  Future<void> _init() async {
    final created = <JsPoolEngine>[];
    try {
      if (_instances.isNotEmpty) {
        return;
      }
      var jsInit = await _loadJsInit();
      for (int i = 0; i < _maxInstances; i++) {
        created.add(_createEngine(jsInit));
      }
      _instances.addAll(created);
    } catch (error, stack) {
      final cleanupErrors = <Object>[];
      final failedCleanup = <JsPoolEngine>[];
      await Future.wait(
        created.map((engine) async {
          try {
            await engine.close();
          } catch (cleanupError) {
            cleanupErrors.add(cleanupError);
            failedCleanup.add(engine);
          }
        }),
      );
      if (cleanupErrors.isNotEmpty) {
        _instances.addAll(failedCleanup);
        _cleanupRequired = true;
        Error.throwWithStackTrace(
          JsPoolInitializationFailure(error, cleanupErrors),
          stack,
        );
      }
      Error.throwWithStackTrace(error, stack);
    } finally {
      _initFuture = null;
    }
  }

  Future<void> close() {
    final closing = _closeFuture;
    if (closing != null) return closing;
    final completion = Completer<void>();
    _closeFuture = completion.future;
    _generation++;
    _close().then<void>(
      (_) {
        _closeFuture = null;
        completion.complete();
      },
      onError: (Object error, StackTrace stack) {
        _closeFuture = null;
        completion.completeError(error, stack);
      },
    );
    return completion.future;
  }

  Future<void> _close() async {
    var initFuture = _initFuture;
    if (initFuture != null) {
      try {
        await initFuture;
      } catch (_) {
        // ignore initialization failures while closing
      }
    }
    var instances = List<JsPoolEngine>.from(_instances);
    _instances.clear();
    final errors = <({Object error, StackTrace stack})>[];
    await Future.wait(
      instances.map((instance) async {
        try {
          await instance.close();
        } catch (error, stack) {
          _instances.add(instance);
          errors.add((error: error, stack: stack));
        }
      }),
    );
    _cleanupRequired = errors.isNotEmpty;
    if (errors.isNotEmpty) {
      Error.throwWithStackTrace(errors.first.error, errors.first.stack);
    }
  }

  Future<dynamic> execute(String jsFunction, List<dynamic> args) async {
    final generation = _generation;
    await init();
    if (_closeFuture != null || generation != _generation) {
      throw StateError('JS pool closed before task admission');
    }
    if (_instances.isEmpty) {
      throw Exception("JSPool failed to initialize.");
    }
    var selectedInstance = _instances[0];
    for (var instance in _instances) {
      if (instance.pendingTasks < selectedInstance.pendingTasks) {
        selectedInstance = instance;
      }
    }
    return selectedInstance.execute(jsFunction, args);
  }
}

class JsPoolInitializationFailure implements Exception {
  JsPoolInitializationFailure(this.cause, Iterable<Object> cleanupErrors)
    : cleanupErrors = List.unmodifiable(cleanupErrors);

  final Object cause;
  final List<Object> cleanupErrors;

  @override
  String toString() =>
      'JS pool initialization failed: $cause; cleanup: $cleanupErrors';
}

/// A worker sends its task SendPort, then one TaskResult per accepted Task.
/// Isolate errors and exit notifications are managed by the owning engine.
typedef JsWorkerStart = ({SendPort replies, Uint8List script});

/// Sent after accepted tasks drain; the worker releases resources and replies
/// with JsWorkerStopped before exiting.
class JsWorkerStop {
  const JsWorkerStop();
}

class JsWorkerStopped {
  const JsWorkerStopped([this.error]);
  final String? error;
}

class IsolateJsEngine implements JsPoolEngine {
  Isolate? _isolate;

  ReceivePort? _receivePort;
  final Completer<SendPort> _sendPortCompleter = Completer<SendPort>();
  Completer<void>? _idleCompleter;

  int _counter = 0;
  final Map<int, Completer<dynamic>> _tasks = {};

  bool _isClosed = false;
  Future<void>? _closeFuture;
  late final Future<void> _spawnFuture;
  final _exited = Completer<void>();
  final _transportReady = Completer<SendPort>();
  bool _workerFailed = false;
  bool _stopRequested = false;
  bool _stopAcknowledged = false;
  String? _cleanupError;

  @override
  int get pendingTasks => _tasks.length;

  IsolateJsEngine(
    Uint8List jsInit, {
    required void Function(JsWorkerStart) entryPoint,
  }) {
    _receivePort = ReceivePort();
    _receivePort!.listen(_onMessage);
    _spawnFuture =
        Isolate.spawn(
          entryPoint,
          (replies: _receivePort!.sendPort, script: jsInit),
          onExit: _receivePort!.sendPort,
          onError: _receivePort!.sendPort,
          errorsAreFatal: true,
        ).then<void>(
          (isolate) {
            // close waits for spawn before releasing the owned isolate. Killing a
            // late handle here could interrupt tasks that close is still draining.
            if (!_exited.isCompleted) {
              _isolate = isolate;
              if (_workerFailed) isolate.kill(priority: Isolate.immediate);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            _completeStartupError(error, stackTrace);
            _completeAllTasksError(error, stackTrace);
            _exited.complete();
            _backgroundClose();
          },
        );
  }

  void _onMessage(dynamic message) {
    if (message == null) {
      if (_stopRequested && !_stopAcknowledged && !_workerFailed) {
        _cleanupError = 'JS worker exited without confirming resource cleanup';
      }
      if (!_isClosed || _tasks.isNotEmpty) {
        final error = StateError('JS worker exited before completing its work');
        _completeStartupError(error, StackTrace.current);
        _completeAllTasksError(error, StackTrace.current);
      }
      if (!_exited.isCompleted) _exited.complete();
      _isolate = null;
      _backgroundClose();
    } else if (message is List && message.length == 2) {
      final error = RemoteError(message[0].toString(), message[1].toString());
      _completeStartupError(error, error.stackTrace);
      _completeAllTasksError(error, error.stackTrace);
      _workerFailed = true;
      _isolate?.kill(priority: Isolate.immediate);
      _backgroundClose();
    } else if (message is SendPort) {
      if (!_transportReady.isCompleted) _transportReady.complete(message);
      if (!_sendPortCompleter.isCompleted) {
        _sendPortCompleter.complete(message);
      }
    } else if (message is JsWorkerStopped) {
      _stopAcknowledged = true;
      _cleanupError = message.error;
    } else if (message is TaskResult) {
      final completer = _tasks.remove(message.id);
      if (completer != null) {
        if (message.error != null) {
          completer.completeError(message.error!);
        } else {
          completer.complete(message.result);
        }
      }
      _completeIdleIfNeeded();
    } else if (message is Exception) {
      Log.error("IsolateJsEngine", message.toString());
      _completeStartupError(message, StackTrace.current);
      _completeAllTasksError(message, StackTrace.current);
      _workerFailed = true;
      _isolate?.kill(priority: Isolate.immediate);
      _backgroundClose();
    }
  }

  void _backgroundClose() {
    unawaited(
      close().catchError((Object error, StackTrace stack) {
        Log.error('JS worker close', error, stack);
      }),
    );
  }

  @override
  Future<dynamic> execute(String jsFunction, List<dynamic> args) async {
    if (_isClosed) {
      throw Exception("IsolateJsEngine is closed.");
    }
    validateJsComputeTransferValue(args, Set<Object>.identity());
    final sendPort = await _sendPortCompleter.future;
    if (_isClosed) {
      throw Exception("IsolateJsEngine is closed.");
    }
    final completer = Completer<dynamic>();
    final taskId = _counter++;
    if (_tasks.isEmpty) {
      _idleCompleter = Completer<void>();
    }
    _tasks[taskId] = completer;
    final task = Task(taskId, jsFunction, args);
    try {
      sendPort.send(task);
    } catch (_) {
      _tasks.remove(taskId);
      _completeIdleIfNeeded();
      rethrow;
    }
    return completer.future;
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _isClosed = true;
    if (!_sendPortCompleter.isCompleted) {
      _completeStartupError(
        Exception("IsolateJsEngine is closed."),
        StackTrace.current,
      );
    }
    try {
      await _waitForIdle();
    } finally {
      await _spawnFuture;
      await Future.any<void>([
        _transportReady.future.then<void>((_) {}),
        _exited.future,
      ]);
      if (!_exited.isCompleted) {
        if (_workerFailed) {
          _isolate?.kill(priority: Isolate.immediate);
        } else {
          _stopRequested = true;
          (await _transportReady.future).send(const JsWorkerStop());
        }
      }
      await _exited.future;
      _isolate = null;
      _receivePort?.close();
      _receivePort = null;
    }
    if (_cleanupError != null) throw StateError(_cleanupError!);
  }

  Future<void> _waitForIdle() {
    if (_tasks.isEmpty) {
      return Future.value();
    }
    return _idleCompleter?.future ?? Future.value();
  }

  void _completeIdleIfNeeded() {
    if (_tasks.isEmpty) {
      _idleCompleter?.complete();
      _idleCompleter = null;
    }
  }

  void _completeStartupError(Object error, StackTrace stackTrace) {
    if (!_sendPortCompleter.isCompleted) {
      unawaited(_ignoreStartupError());
      _sendPortCompleter.completeError(error, stackTrace);
    }
  }

  Future<void> _ignoreStartupError() async {
    try {
      await _sendPortCompleter.future;
    } catch (_) {
      // keep startup errors from becoming unhandled when nobody is waiting
    }
  }

  void _completeAllTasksError(Object error, StackTrace stackTrace) {
    for (var completer in _tasks.values) {
      completer.completeError(error, stackTrace);
    }
    _tasks.clear();
    _completeIdleIfNeeded();
  }
}

class Task {
  final int id;
  final String jsFunction;
  final List<dynamic> args;

  const Task(this.id, this.jsFunction, this.args);
}

class TaskResult {
  final int id;
  final Object? result;
  final String? error;

  const TaskResult(this.id, this.result, this.error);
}

void validateJsComputeTransferValue(dynamic value, Set<Object> seen) {
  if (value is JSRef) {
    throw StateError('JS compute cannot transfer native JavaScript references');
  }
  if (value is Map && seen.add(value)) {
    for (final entry in value.entries) {
      validateJsComputeTransferValue(entry.key, seen);
      validateJsComputeTransferValue(entry.value, seen);
    }
  } else if (value is List && seen.add(value)) {
    for (final item in value) {
      validateJsComputeTransferValue(item, seen);
    }
  }
}
