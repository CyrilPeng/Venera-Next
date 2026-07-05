import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/foundation/js_engine.dart';
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

  static final JSPool _singleton = JSPool._internal();

  factory JSPool() {
    return _singleton;
  }

  JSPool._internal();

  Future<void> init() async {
    if (_instances.isNotEmpty) {
      return;
    }
    return _initFuture ??= _init();
  }

  Future<void> _init() async {
    try {
      if (_instances.isNotEmpty) {
        return;
      }
      var jsInit = await _loadJsInit();
      for (int i = 0; i < _maxInstances; i++) {
        _instances.add(_createEngine(jsInit));
      }
    } finally {
      _initFuture = null;
    }
  }

  Future<Uint8List> _loadJsInit() async {
    var debugLoad = debugLoadJsInit;
    if (debugLoad != null) {
      return debugLoad();
    }
    var jsInitBuffer = await rootBundle.load("assets/init.js");
    return jsInitBuffer.buffer.asUint8List();
  }

  JsPoolEngine _createEngine(Uint8List jsInit) {
    var debugCreate = debugCreateEngine;
    if (debugCreate != null) {
      return debugCreate(jsInit);
    }
    return IsolateJsEngine(jsInit);
  }

  Future<void> close() async {
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
    await Future.wait(instances.map((instance) => instance.close()));
  }

  @visibleForTesting
  static Future<Uint8List> Function()? debugLoadJsInit;

  @visibleForTesting
  static JsPoolEngine Function(Uint8List jsInit)? debugCreateEngine;

  @visibleForTesting
  static Future<void> resetForTesting() async {
    await _singleton.close();
    _singleton._initFuture = null;
    debugLoadJsInit = null;
    debugCreateEngine = null;
  }

  @visibleForTesting
  int get debugInstanceCount => _instances.length;

  Future<dynamic> execute(String jsFunction, List<dynamic> args) async {
    await init();
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

class _IsolateJsEngineInitParam {
  final SendPort sendPort;

  final Uint8List jsInit;

  _IsolateJsEngineInitParam(this.sendPort, this.jsInit);
}

class IsolateJsEngine implements JsPoolEngine {
  Isolate? _isolate;

  ReceivePort? _receivePort;
  final Completer<SendPort> _sendPortCompleter = Completer<SendPort>();
  Completer<void>? _idleCompleter;

  int _counter = 0;
  final Map<int, Completer<dynamic>> _tasks = {};

  bool _isClosed = false;

  @override
  int get pendingTasks => _tasks.length;

  IsolateJsEngine(Uint8List jsInit) {
    _receivePort = ReceivePort();
    _receivePort!.listen(_onMessage);
    Isolate.spawn(
      _run,
      _IsolateJsEngineInitParam(_receivePort!.sendPort, jsInit),
    ).then(
      (isolate) {
        if (_isClosed) {
          isolate.kill(priority: Isolate.immediate);
        } else {
          _isolate = isolate;
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _completeStartupError(error, stackTrace);
        _completeAllTasksError(error, stackTrace);
        _receivePort?.close();
        _isClosed = true;
      },
    );
  }

  void _onMessage(dynamic message) {
    if (message is SendPort) {
      if (!_sendPortCompleter.isCompleted) {
        _sendPortCompleter.complete(message);
      }
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
      unawaited(close());
    }
  }

  static void _run(_IsolateJsEngineInitParam params) async {
    var sendPort = params.sendPort;
    final port = ReceivePort();
    sendPort.send(port.sendPort);
    final engine = JsEngine();
    try {
      JsEngine.cacheJsInit(params.jsInit);
      await engine.init();
    } catch (e, s) {
      sendPort.send(Exception("Failed to initialize JS engine: $e\n$s"));
      return;
    }
    await for (final message in port) {
      if (message is Task) {
        try {
          final jsFunc = engine.runCode(message.jsFunction);
          if (jsFunc is! JSInvokable) {
            throw Exception(
              "The provided code does not evaluate to a function.",
            );
          }
          final result = jsFunc.invoke(message.args);
          jsFunc.free();
          sendPort.send(TaskResult(message.id, result, null));
        } catch (e) {
          sendPort.send(TaskResult(message.id, null, e.toString()));
        }
      }
    }
  }

  @override
  Future<dynamic> execute(String jsFunction, List<dynamic> args) async {
    if (_isClosed) {
      throw Exception("IsolateJsEngine is closed.");
    }
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
    sendPort.send(task);
    return completer.future;
  }

  @override
  Future<void> close() async {
    if (_isClosed) {
      return;
    }
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
      _receivePort?.close();
      _receivePort = null;
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
    }
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
