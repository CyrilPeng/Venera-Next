import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/io.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:flutter/foundation.dart'
    show FlutterError, FlutterErrorDetails, protected, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart' as dom;
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asn1/asn1_parser.dart';
import 'package:pointycastle/asn1/primitives/asn1_integer.dart';
import 'package:pointycastle/asn1/primitives/asn1_sequence.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/asymmetric/pkcs1.dart';
import 'package:pointycastle/asymmetric/rsa.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/block/modes/cfb.dart';
import 'package:pointycastle/block/modes/ecb.dart';
import 'package:pointycastle/block/modes/ofb.dart';
import 'package:uuid/uuid.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_locale.dart';
import 'package:venera_next/foundation/js_pool.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/cache.dart';
import 'package:venera_next/network/cookie_jar.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/network/proxy.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:venera_next/foundation/init.dart';

import 'consts.dart';
import 'log.dart';

class JavaScriptRuntimeException implements Exception {
  final String message;

  JavaScriptRuntimeException(this.message);

  @override
  String toString() {
    return "JSException: $message";
  }
}

/// Identity belongs to one native runtime, never just the reusable source key.
class JsSourceIdentity {
  const JsSourceIdentity(this.engine, this.id);
  final JsEngine engine;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is JsSourceIdentity &&
      identical(engine, other.engine) &&
      id == other.id;
  @override
  int get hashCode => Object.hash(identityHashCode(engine), id);
}

class JsSourceDataBridge {
  final Object? Function(JsSourceIdentity identity, String key, String dataKey)
  loadData;

  final void Function(
    JsSourceIdentity identity,
    String key,
    String dataKey,
    Object? data,
  )
  saveData;

  final void Function(JsSourceIdentity identity, String key, String dataKey)
  deleteData;

  final Object? Function(
    JsSourceIdentity identity,
    String key,
    String settingKey,
  )
  loadSetting;

  final bool Function(JsSourceIdentity identity, String key) isLogged;

  const JsSourceDataBridge({
    required this.loadData,
    required this.saveData,
    required this.deleteData,
    required this.loadSetting,
    required this.isLogged,
  });
}

abstract interface class JsUiMessageHandler {
  Object? handleUIMessage(
    Map<String, dynamic> message, {
    required JsEngine engine,
  });
}

/// Expected termination when the owner releases a JavaScript operation.
class JsDisposedError extends StateError {
  JsDisposedError(super.message);
}

class JsResourceReleaseFailure implements Exception {
  JsResourceReleaseFailure(
    Iterable<({String resource, Object error, StackTrace stack})> failures,
  ) : failures = List.unmodifiable(failures);
  final List<({String resource, Object error, StackTrace stack})> failures;

  @override
  String toString() =>
      'JS resource release failed: ${failures.map((e) => '${e.resource}: ${e.error}').join('; ')}';
}

class JsEngineInitializationFailure implements Exception {
  JsEngineInitializationFailure(this.cause, this.cleanupError);
  final Object cause;
  final Object cleanupError;

  @override
  String toString() =>
      'JS initialization failed: $cause; cleanup: $cleanupError';
}

void _releaseJsResources(
  Iterable<({String name, void Function() release})> resources,
) {
  final failures = <({String resource, Object error, StackTrace stack})>[];
  for (final resource in resources) {
    try {
      resource.release();
    } catch (error, stack) {
      failures.add((resource: resource.name, error: error, stack: stack));
    }
  }
  if (failures.isNotEmpty) throw JsResourceReleaseFailure(failures);
}

void _visitJsResultGraph(
  Object? value,
  Set<Object> visited,
  void Function(JSRef) onReference, {
  void Function(Future<dynamic>)? onFuture,
}) {
  void visit(Object? current) {
    if (current == null || !visited.add(current)) return;
    if (current is JSRef) {
      onReference(current);
    } else if (current is Future) {
      onFuture?.call(current);
    } else if (current is Map) {
      for (final entry in current.entries.toList()) {
        visit(entry.key);
        visit(entry.value);
      }
    } else if (current is List && current is! TypedData) {
      for (final child in current.toList()) {
        visit(child);
      }
    }
  }

  visit(value);
}

/// A bridge result owns each distinct Dart reference once. The bridge may
/// produce several independently duplicated wrappers for the same JS function.
void _releaseJsResultReferences(Object? value) {
  final references = <JSRef>[];
  _visitJsResultGraph(value, Set<Object>.identity(), references.add);
  _releaseJsResources([
    for (final reference in references)
      (name: 'result reference', release: reference.free),
  ]);
}

/// Release a rejected result that no consumer will receive. Each distinct
/// native wrapper is released once, including aliases in a result graph.
void discardJsResult(Object? value) => _releaseJsResultReferences(value);

/// Ordinary calls retain their existing synchronous/Future result contract.
/// Supplying [consume] instead joins this invocation's actual top-level Promise
/// and lends its result to a synchronous consumer, releasing the result/error
/// graph before the returned `Future<void>` completes. Scope disposal does not
/// finish an accepted consuming call; native runtime termination does.
/// Descendant Promises and unreturned work are not joined by this contract.
typedef JsCallback =
    dynamic Function(
      List<dynamic> arguments, {
      void Function(dynamic result)? consume,
    });

/// Borrows the immediate success/rejection before its references are released.
/// A Promise is represented by a `Future<dynamic>` completion marker with no
/// native result. The returned Future joins the actual top-level invocation
/// and cleanup independently of scope disposal. The consumer runs only once.
typedef JsImmediateCallback =
    Future<void> Function(
      List<dynamic> arguments,
      void Function(dynamic result, StackTrace? rejectionStack) consume,
    );

/// Invoke an action once and release its unused result. Plain Dart callbacks
/// are also supported; scoped native callbacks provide their completion bridge.
Future<void> invokeJsCallbackToCompletion(
  dynamic Function(List<dynamic>) callback,
  List<dynamic> arguments,
) async {
  if (callback is JsCallback) {
    await callback(arguments, consume: (_) {});
    return;
  }
  Object? result;
  Object? failure;
  StackTrace? failureStack;
  try {
    result = await callback(arguments);
  } catch (error, stack) {
    failure = error;
    failureStack = stack;
    rethrow;
  } finally {
    try {
      discardJsResult([result, failure]);
    } on JsResourceReleaseFailure catch (cleanup) {
      if (failure == null) rethrow;
      throw JsResourceReleaseFailure([
        (resource: 'callback', error: failure, stack: failureStack!),
        ...cleanup.failures,
      ]);
    }
  }
}

/// Observe every Future reachable from a result graph whose synchronous
/// references have already been discarded. Release newly arriving references
/// once across all descendant graphs, including rejected values and map keys.
/// This never cancels a Future or closes its runtime; the returned Future joins
/// actual descendant settlement and retains rejection/cleanup diagnostics.
Future<void> drainJsResultDescendants(Object? value) =>
    _JsResultDescendantDrain().start(value);

class _JsResultDescendantDrain {
  final _visited = Set<Object>.identity();
  final _done = Completer<void>();
  final _failures = <({String resource, Object error, StackTrace stack})>[];
  int _pending = 0;
  bool _collecting = true;

  Future<void> start(Object? value) {
    final futures = <Future<dynamic>>[];
    try {
      // Seed references already handled by synchronous discard so aliases in
      // a later Promise value cannot free them again, even after a failed free.
      _visitJsResultGraph(value, _visited, (_) {}, onFuture: futures.add);
    } catch (error, stack) {
      _failures.add((
        resource: 'result graph scan',
        error: error,
        stack: stack,
      ));
    }
    // Seed the entire root before subscribing: a synchronous Future may yield
    // a reference that appears later in the already-discarded root graph.
    for (final future in futures) {
      _observe(future);
    }
    _collecting = false;
    _completeIfIdle();
    return _done.future;
  }

  void _observe(Future<dynamic> future) {
    _pending++;
    try {
      unawaited(
        future.then<void>(
          (value) => _settle(value, null),
          onError: (Object error, StackTrace stack) => _settle(error, stack),
        ),
      );
    } catch (error, stack) {
      _pending--;
      _failures.add((
        resource: 'Promise subscription',
        error: error,
        stack: stack,
      ));
    }
  }

  void _settle(Object? value, StackTrace? rejectionStack) {
    if (rejectionStack != null) {
      _failures.add((
        resource: 'nested Promise',
        error: value!,
        stack: rejectionStack,
      ));
    }
    final references = <JSRef>[];
    try {
      _visitJsResultGraph(value, _visited, references.add, onFuture: _observe);
    } catch (error, stack) {
      _failures.add((
        resource: 'nested result scan',
        error: error,
        stack: stack,
      ));
    }
    try {
      _releaseJsResources([
        for (final reference in references)
          (name: 'nested result reference', release: reference.free),
      ]);
    } on JsResourceReleaseFailure catch (error) {
      _failures.addAll(error.failures);
    }
    _pending--;
    _completeIfIdle();
  }

  void _completeIfIdle() {
    if (_collecting || _pending != 0 || _done.isCompleted) return;
    if (_failures.isEmpty) {
      _done.complete();
    } else {
      _done.completeError(JsResourceReleaseFailure(_failures));
    }
  }
}

class JsEngine with _JSEngineApi, Init {
  factory JsEngine() => _cache ?? (_cache = JsEngine._create());

  static JsEngine? _cache;

  JsEngine._create() : this.create();

  /// Owns clients returned by the factory and releases them with this engine.
  /// [loadInitScript] supplies the initialization image for this runtime and
  /// its compute workers. Each worker evaluates the image in a fresh runtime;
  /// unconditional top-level compute would recursively initialize more workers.
  JsEngine.create({
    Dio Function()? createHttpClient,
    Future<Uint8List> Function()? loadInitScript,
    JsPoolEngine Function(Uint8List)? createComputeWorker,
    JsUiMessageHandler? uiMessageHandler,
  }) : _createHttpClient = createHttpClient ?? _newHttpClient,
       _loadInitScript = loadInitScript ?? _readInitScript,
       _createComputeWorker = createComputeWorker ?? _newComputeWorker,
       _uiMessageHandler = uiMessageHandler;

  final Dio Function() _createHttpClient;
  final Future<Uint8List> Function() _loadInitScript;
  final JsPoolEngine Function(Uint8List) _createComputeWorker;
  Uint8List? _computeScript;
  JSPool? _computePool;
  final _computeClosures = <JSPool, Future<void>>{};
  bool _disposed = false;
  final _temporaryClients = <Dio>{};
  final _retiredClients = <Dio>{};
  final _httpScopes = <RequestScope>{};
  final _delays = <Timer, Completer<void>>{};
  final _pendingHttp = <Future<void>>{};
  final _bridgeDrains = <FlutterQjs, Set<Future<void>>>{};
  final _bridgeResults = <FlutterQjs, Set<Completer<dynamic>>>{};
  final _nativeReleases = <Future<void>>{};
  final _adapterDrains = <RHttpAdapter, Future<void>>{};
  final _failedAdapterDrains = <RHttpAdapter>{};
  final _shutdownFailures =
      <({String resource, Object error, StackTrace stack})>[];
  Future<void>? _closeFuture;
  final _pendingResults = <Completer<dynamic>>{};
  final _ownedReferences = Set<_OwnedJsReference>.identity();
  final _ownedByRawReference = Expando<_OwnedJsReference>();
  final _callbackInvocations = <_JsCallbackInvocation>{};

  @visibleForTesting
  int get debugOwnedReferenceCount => _ownedReferences.length;

  /// Exercises bridge-result ownership without requiring native evaluation.
  @visibleForTesting
  dynamic debugOwnResult(dynamic result) {
    _checkActive();
    return _trackOwnedResult(result, _pendingResults, _engine);
  }

  static JsPoolEngine _newComputeWorker(Uint8List script) =>
      IsolateJsEngine(script, entryPoint: runJsComputeWorker);

  Future<dynamic> _compute(String function, List<dynamic> args) {
    _checkActive();
    final script = _computeScript;
    if (script == null) {
      throw StateError('JS compute script is not initialized');
    }
    final pool = _computePool ??= JSPool.create(
      loadJsInit: () async => script,
      createEngine: _createComputeWorker,
    );
    return pool.execute(function, args);
  }

  void _closeComputePool() {
    final pool = _computePool;
    _computePool = null;
    if (pool == null) return;
    // Keep failed pools with their original owner and retain every close result.
    _computeClosures[pool] = Future<void>.sync(pool.close).catchError((
      Object error,
      StackTrace stack,
    ) {
      _shutdownFailures.add((
        resource: 'JS compute pool',
        error: error,
        stack: stack,
      ));
    });
  }

  Future<void> _drainComputePools() async {
    await Future.wait(_computeClosures.values.toList());
    final failures = _shutdownFailures.where(
      (failure) => failure.resource == 'JS compute pool',
    );
    if (failures.isNotEmpty) throw JsResourceReleaseFailure(failures);
  }

  static Dio _newHttpClient() => AppDio(
    BaseOptions(
      responseType: ResponseType.plain,
      validateStatus: (status) => true,
    ),
  );

  static Future<Uint8List> _readInitScript() async {
    final cached = _jsInitCache;
    if (cached != null) return cached;
    final buffer = await rootBundle.load('assets/init.js');
    return buffer.buffer.asUint8List();
  }

  void _checkActive() {
    if (_disposed) throw StateError('JS engine is disposed');
  }

  @override
  Future<void> init() {
    if (_disposed) return Future.error(StateError('JS engine is disposed'));
    return super.init();
  }

  FlutterQjs? _engine;
  final _callbackScopes = <JsCallbackScope>{};

  bool _closed = true;

  Dio? _dio;

  static JsSourceDataBridge? _sourceDataBridge;

  JsUiMessageHandler? _uiMessageHandler;

  static void configureSourceDataBridge(JsSourceDataBridge? bridge) {
    _sourceDataBridge = bridge;
  }

  /// Binds this runtime once, so another application's UI cannot replace it.
  void bindUiMessageHandler(JsUiMessageHandler handler) {
    _checkActive();
    final previous = _uiMessageHandler;
    if (previous != null && !identical(previous, handler)) {
      throw StateError('JavaScript UI handler is already bound');
    }
    _uiMessageHandler = handler;
  }

  JsSourceDataBridge get _sourceBridge =>
      _sourceDataBridge ?? (throw "JS source data bridge is not configured.");

  JsUiMessageHandler get _uiMessageBridge =>
      _uiMessageHandler ?? (throw "JS UI message handler is not configured.");

  void resetDio() {
    _checkActive();
    final replacement = _createHttpClient();
    final previous = _dio;
    _dio = replacement;
    // Let already accepted requests finish against the previous settings.
    if (previous != null) {
      _retiredClients.add(previous);
      try {
        previous.close();
      } catch (error, stack) {
        _shutdownFailures.add((
          resource: 'retired HTTP client',
          error: error,
          stack: stack,
        ));
        rethrow;
      } finally {
        final adapter = previous.httpClientAdapter;
        if (adapter is RHttpAdapter) {
          _drainAdapter(adapter).then((_) {
            if (!_failedAdapterDrains.contains(adapter)) {
              _retiredClients.remove(previous);
            }
          });
        }
      }
    }
  }

  static Uint8List? _jsInitCache;

  static void cacheJsInit(Uint8List jsInit) {
    _jsInitCache = jsInit;
  }

  @override
  @protected
  Future<void> doInit() async {
    if (!_closed) {
      return;
    }
    try {
      if (_computeClosures.isNotEmpty) await _drainComputePools();
      if (App.isInitialized) {
        await SingleInstanceCookieJar.createInstance();
      }
      _checkActive();
      _dio ??= _createHttpClient();
      _closed = false;
      _engine = FlutterQjs(
        hostPromiseRejectionHandler: _handleUnhandledPromiseRejection,
      );
      final nativeEngine = _engine!;
      _engine!.dispatch();
      var setGlobalFunc = _engine!.evaluate(
        "(key, value) => { this[key] = value; }",
      );
      try {
        (setGlobalFunc as JSInvokable)([
          "sendMessage",
          (dynamic message) => _messageReceiver(nativeEngine, message),
        ]);
        setGlobalFunc(["appVersion", App.version]);
      } finally {
        (setGlobalFunc as JSInvokable).free();
      }
      final jsInit = await _loadInitScript();
      _checkActive();
      _computeScript = Uint8List.fromList(jsInit);
      _engine!.evaluate(utf8.decode(_computeScript!), name: "<init>");
    } catch (e, s) {
      try {
        _releaseResources();
      } on JsResourceReleaseFailure {
        // Synchronous release already recorded the failures. Compute cleanup
        // must still finish before failed initialization returns to its owner.
      } catch (cleanupError, cleanupStack) {
        _shutdownFailures.add((
          resource: 'initialization cleanup',
          error: cleanupError,
          stack: cleanupStack,
        ));
      }
      await Future.wait(_computeClosures.values.toList());
      if (_shutdownFailures.isNotEmpty) {
        Error.throwWithStackTrace(
          JsEngineInitializationFailure(
            e,
            JsResourceReleaseFailure(_shutdownFailures),
          ),
          s,
        );
      }
      Log.error('JS Engine', 'JS Engine Init Error:\n$e\n$s');
      rethrow;
    }
  }

  JsSourceIdentity _sourceIdentity(Map<dynamic, dynamic> message) {
    _checkActive();
    final id = message['source_id'];
    if (id is! String || id.isEmpty) {
      throw StateError('Source data messages require an instance identity');
    }
    return JsSourceIdentity(this, id);
  }

  Object? _messageReceiver(FlutterQjs nativeEngine, dynamic message) {
    if (_disposed || _closed || !identical(nativeEngine, _engine)) {
      throw JsDisposedError('JavaScript message owner is closed');
    }
    final result = _handleMessage(message);
    if (result is Future) {
      // The bridge owns a cancellable delivery, separately from the operation
      // itself. A UI dialog may never finish after the window has frozen, while
      // HTTP and native resource completion are joined by their own owners.
      final delivery = Completer<dynamic>();
      final deliveries = _bridgeResults.putIfAbsent(nativeEngine, () => {});
      deliveries.add(delivery);
      result.then<void>(
        (value) {
          if (!delivery.isCompleted) {
            delivery.complete(value);
          } else {
            try {
              _releaseJsResultReferences(value);
            } catch (error, stack) {
              _reportBridgeDiagnostic(error, stack, 'retired bridge result');
            }
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!delivery.isCompleted) delivery.completeError(error, stack);
        },
      );
      final pending = _bridgeDrains.putIfAbsent(nativeEngine, () => {});
      late final Future<void> settled;
      settled = delivery.future
          .then<void>((_) {}, onError: (Object _, StackTrace _) {})
          .then((_) async {
            // flutter_qjs converts a Dart Future using then/whenComplete to
            // invoke and free native promise resolvers. Keep this runtime live
            // through that microtask phase, including rejected Futures.
            await Future<void>.delayed(Duration.zero);
            deliveries.remove(delivery);
            pending.remove(settled);
          });
      pending.add(settled);
      return delivery.future;
    }
    return result;
  }

  Object? _handleMessage(dynamic message) {
    try {
      if (message is Map<dynamic, dynamic>) {
        if (message["method"] == null) return null;
        String method = message["method"] as String;
        switch (method) {
          case "log":
            String level = message["level"];
            Log.addLog(
              switch (level) {
                "error" => LogLevel.error,
                "warning" => LogLevel.warning,
                "info" => LogLevel.info,
                _ => LogLevel.warning,
              },
              message["title"],
              message["content"].toString(),
            );
          case 'load_data':
            String key = message["key"];
            String dataKey = message["data_key"];
            return _sourceBridge.loadData(
              _sourceIdentity(message),
              key,
              dataKey,
            );
          case 'save_data':
            String key = message["key"];
            String dataKey = message["data_key"];
            if (dataKey == 'setting') {
              throw "setting is not allowed to be saved";
            }
            var data = message["data"];
            _sourceBridge.saveData(
              _sourceIdentity(message),
              key,
              dataKey,
              data,
            );
          case 'delete_data':
            String key = message["key"];
            String dataKey = message["data_key"];
            _sourceBridge.deleteData(_sourceIdentity(message), key, dataKey);
          case 'http':
            return _http(Map.from(message));
          case 'html':
            return handleHtmlCallback(Map.from(message));
          case 'convert':
            return _convert(Map.from(message));
          case "random":
            return _random(
              message["min"] ?? 0,
              message["max"] ?? 1,
              message["type"],
            );
          case "cookie":
            return handleCookieCallback(Map.from(message));
          case "uuid":
            return const Uuid().v1();
          case "load_setting":
            String key = message["key"];
            String settingKey = message["setting_key"];
            return _sourceBridge.loadSetting(
              _sourceIdentity(message),
              key,
              settingKey,
            );
          case "isLogged":
            return _sourceBridge.isLogged(
              _sourceIdentity(message),
              message["key"],
            );
          // temporary solution for [setTimeout] function
          // TODO: implement [setTimeout] in quickjs project
          case "delay":
            return _delay(Duration(milliseconds: message["time"]));
          case "UI":
            return _uiMessageBridge.handleUIMessage(
              Map.from(message),
              engine: this,
            );
          case "getLocale":
            return "${appLocale.languageCode}_${appLocale.countryCode}";
          case "getPlatform":
            return Platform.operatingSystem;
          case "setClipboard":
            return Clipboard.setData(ClipboardData(text: message["text"]));
          case "getClipboard":
            return Future.sync(() async {
              var res = await Clipboard.getData(Clipboard.kTextPlain);
              return res?.text;
            });
          case "compute":
            final func = message["function"];
            final args = message["args"];
            if (func is JSInvokable) {
              func.free();
              throw "Function must be a string";
            }
            if (func is! String) {
              throw "Function must be a string";
            }
            if (args != null && args is! List) {
              throw "Args must be a list";
            }
            return _compute(func, args ?? []);
        }
      }
      return null;
    } catch (e, s) {
      Log.error("Failed to handle message: $message\n$e\n$s", "JsEngine");
      rethrow;
    }
  }

  Future<void> _delay(Duration duration) {
    final completion = Completer<void>();
    late final Timer timer;
    timer = Timer(duration, () {
      _delays.remove(timer);
      completion.complete();
    });
    _delays[timer] = completion;
    return completion.future;
  }

  Future<Map<String, dynamic>> _http(Map<String, dynamic> req) {
    final scope = RequestScope(parent: RequestScope.current);
    _httpScopes.add(scope);
    final completion = Completer<Map<String, dynamic>>();
    late final Future<void> settled;
    settled = completion.future
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          scope.dispose();
          _httpScopes.remove(scope);
          _pendingHttp.remove(settled);
        });
    _pendingHttp.add(settled);
    _performHttp(
      req,
      scope,
    ).then(completion.complete, onError: completion.completeError);
    return completion.future;
  }

  Future<Map<String, dynamic>> _performHttp(
    Map<String, dynamic> req,
    RequestScope scope,
  ) async {
    Response? response;
    String? error;
    Dio? temporaryClient;

    try {
      _checkActive();
      scope.check();
      var headers = Map<String, dynamic>.from(req["headers"] ?? {});
      var extra = Map<String, dynamic>.from(req["extra"] ?? {});
      if (headers["user-agent"] == null && headers["User-Agent"] == null) {
        headers["User-Agent"] = webUA;
      }
      var dio = _dio;
      if (headers['http_client'] == "dart:io") {
        dio = Dio(
          BaseOptions(
            responseType: ResponseType.plain,
            validateStatus: (status) => true,
          ),
        );
        temporaryClient = dio;
        _temporaryClients.add(dio);
        var proxy = await getProxy();
        _checkActive();
        scope.check();
        dio.httpClientAdapter = IOHttpClientAdapter(
          createHttpClient: () {
            return HttpClient()
              ..findProxy = (uri) => proxy == null ? "DIRECT" : "PROXY $proxy";
          },
        );
        dio.interceptors.add(
          CookieManagerSql.dynamic(() => SingleInstanceCookieJar.instance),
        );
        dio.interceptors.add(LogInterceptor());
      }
      response = await dio!.request(
        req["url"],
        cancelToken: scope.cancelToken,
        data: req["data"],
        options: Options(
          method: req['http_method'],
          responseType: req["bytes"] == true
              ? ResponseType.bytes
              : ResponseType.plain,
          headers: headers,
          extra: extra,
        ),
      );
    } catch (e) {
      error = e.toString();
    } finally {
      if (temporaryClient != null &&
          _temporaryClients.remove(temporaryClient)) {
        try {
          temporaryClient.close(force: true);
        } catch (error, stack) {
          _shutdownFailures.add((
            resource: 'temporary HTTP client',
            error: error,
            stack: stack,
          ));
          rethrow;
        }
      }
    }

    Map<String, String> headers = {};

    response?.headers.forEach(
      (name, values) => headers[name] = values.join(','),
    );

    dynamic body = response?.data;
    if (body is! Uint8List && body is List<int>) {
      body = Uint8List.fromList(body);
    }

    return {
      "status": response?.statusCode,
      "headers": headers,
      "body": body,
      "error": error,
    };
  }

  dynamic runCode(String js, [String? name]) {
    _checkActive();
    return _trackResult(_engine!.evaluate(js, name: name), _pendingResults);
  }

  /// Transfers every result reference to this runtime while preserving the
  /// JSRef/JSInvokable API. Results of later callback calls keep this owner,
  /// including references nested in returned maps, lists, or rejected values.
  dynamic runOwnedCode(String js, [String? name]) {
    _checkActive();
    final nativeEngine = _engine;
    if (nativeEngine == null || _closed) {
      throw JsDisposedError('JavaScript runtime is not available');
    }
    final dynamic result;
    try {
      result = nativeEngine.evaluate(js, name: name);
    } catch (error, stack) {
      Error.throwWithStackTrace(
        _ownResult(error, _pendingResults, nativeEngine) as Object,
        stack,
      );
    }
    return _trackOwnedResult(result, _pendingResults, nativeEngine);
  }

  bool _ownsRuntime(FlutterQjs? nativeEngine) =>
      !_disposed &&
      identical(_engine, nativeEngine) &&
      (nativeEngine == null || !_closed);

  dynamic _unwrapInvocationGraph(dynamic value, FlutterQjs? nativeEngine) {
    final copies = Map<Object, dynamic>.identity();
    dynamic copy(dynamic current) {
      if (current == null) return null;
      if (copies.containsKey(current)) return copies[current];
      if (current is _OwnedJsReference) {
        if (!identical(current.owner, this) ||
            !identical(current.nativeEngine, nativeEngine)) {
          throw StateError('JavaScript argument belongs to another runtime');
        }
        current.checkActive();
        // Passing the public wrapper to flutter_qjs would create a new Dart
        // callback bridge instead of passing the original JavaScript value.
        return current._reference!;
      }
      if (current is TypedData || current is List<int>) return current;
      if (current is Map) {
        final Map<dynamic, dynamic> result = current is Map<String, dynamic>
            ? <String, dynamic>{}
            : <dynamic, dynamic>{};
        copies[current] = result;
        for (final entry in current.entries) {
          result[copy(entry.key)] = copy(entry.value);
        }
        return result;
      }
      if (current is List) {
        final result = <dynamic>[];
        copies[current] = result;
        for (final child in current) {
          result.add(copy(child));
        }
        return result;
      }
      return current;
    }

    return copy(value);
  }

  dynamic _ownResult(
    dynamic value,
    Set<Completer<dynamic>> pending,
    FlutterQjs? nativeEngine,
  ) {
    if (!_ownsRuntime(nativeEngine)) {
      throw JsDisposedError('JavaScript result belongs to a closed runtime');
    }
    final copies = Map<Object, dynamic>.identity();
    dynamic copy(dynamic current) {
      if (current == null) return null;
      if (copies.containsKey(current)) return copies[current];
      if (current is _OwnedJsReference) {
        if (!identical(current.owner, this) ||
            !identical(current.nativeEngine, nativeEngine)) {
          throw StateError('JavaScript reference belongs to another runtime');
        }
        current.checkActive();
        return current;
      }
      if (current is JSRef) {
        final previous = _ownedByRawReference[current];
        if (previous != null) {
          previous.checkActive();
          if (!identical(previous.nativeEngine, nativeEngine)) {
            throw JsDisposedError(
              'JavaScript reference belongs to an old runtime',
            );
          }
          return previous;
        }
        final owned = current is JSInvokable
            ? _OwnedJsInvokable(this, nativeEngine, current)
            : _OwnedJsReference(this, nativeEngine, current);
        _ownedByRawReference[current] = owned;
        _ownedReferences.add(owned);
        return owned;
      }
      if (current is Future) {
        final tracked = _trackOwnedResult(current, pending, nativeEngine);
        copies[current] = tracked;
        return tracked;
      }
      if (current is TypedData || current is List<int>) return current;
      if (current is Map) {
        final Map<dynamic, dynamic> result = current is Map<String, dynamic>
            ? <String, dynamic>{}
            : <dynamic, dynamic>{};
        copies[current] = result;
        for (final entry in current.entries) {
          result[copy(entry.key)] = copy(entry.value);
        }
        return result;
      }
      if (current is List) {
        final result = <dynamic>[];
        copies[current] = result;
        for (final child in current) {
          result.add(copy(child));
        }
        return result;
      }
      return current;
    }

    return copy(value);
  }

  dynamic _trackOwnedResult(
    dynamic result,
    Set<Completer<dynamic>> pending,
    FlutterQjs? nativeEngine,
  ) {
    if (result is! Future) return _ownResult(result, pending, nativeEngine);
    final completion = Completer<dynamic>();
    pending.add(completion);
    unawaited(completion.future.then<void>((_) {}, onError: (Object _) {}));
    void settle(dynamic value, StackTrace? failureStack) {
      pending.remove(completion);
      if (completion.isCompleted) {
        // The native bridge may deliver after a callback has been released.
        // Its runtime still owns any references until the runtime itself closes.
        if (_ownsRuntime(nativeEngine)) {
          try {
            _releaseJsResultReferences(value);
          } catch (error, stack) {
            _reportBridgeDiagnostic(
              error,
              stack,
              'late JavaScript result cleanup',
            );
          }
        }
        return;
      }
      try {
        // Register native references before making completion visible. A
        // separate .then(adopt) leaves a microtask where close can miss them.
        final owned = _ownResult(value, pending, nativeEngine);
        if (failureStack == null) {
          completion.complete(owned);
        } else {
          completion.completeError(owned as Object, failureStack);
        }
      } catch (error, stack) {
        completion.completeError(error, stack);
      }
    }

    unawaited(
      result.then<void>(
        (value) => settle(value, null),
        onError: (Object error, StackTrace stack) => settle(error, stack),
      ),
    );
    return completion.future;
  }

  void _handleUnhandledPromiseRejection(dynamic reason) {
    try {
      Log.error('JS Engine', 'Unhandled promise rejection: $reason');
    } catch (error, stack) {
      _reportBridgeDiagnostic(error, stack, 'JavaScript rejection logging');
    } finally {
      // QuickJS constructs a separate Dart graph for this diagnostic callback.
      // Merely printing it leaks its independently duplicated native wrappers.
      try {
        _releaseJsResultReferences(reason);
      } catch (error, stack) {
        _reportBridgeDiagnostic(error, stack, 'JavaScript rejection cleanup');
      }
    }
  }

  void _reportBridgeDiagnostic(Object error, StackTrace stack, String library) {
    try {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack, library: library),
      );
    } catch (_) {
      // Diagnostics must not escape into the native bridge or skip cleanup.
    }
  }

  dynamic _trackResult(dynamic result, Set<Completer<dynamic>> pending) {
    if (result is! Future) return result;
    final nativeEngine = _engine;
    final completion = Completer<dynamic>();
    pending.add(completion);
    // Match the native bridge: ignored Promises do not emit uncaught errors,
    // while callers awaiting the returned Future still observe their failure.
    unawaited(completion.future.then<void>((_) {}, onError: (Object _) {}));
    void discard(dynamic value) {
      // A closed scope can receive a late native result while its engine lives.
      // Never free old native references through a replacement runtime.
      if (!_closed && identical(_engine, nativeEngine)) {
        JSRef.freeRecursive(value);
      }
    }

    result.then<void>(
      (value) {
        pending.remove(completion);
        if (completion.isCompleted) {
          discard(value);
        } else {
          completion.complete(value);
        }
      },
      onError: (Object error, StackTrace stack) {
        pending.remove(completion);
        if (completion.isCompleted) {
          discard(error);
        } else {
          completion.completeError(error, stack);
        }
      },
    );
    return completion.future;
  }

  void _failPendingResults(Set<Completer<dynamic>> pending, String message) {
    for (final completion in pending) {
      completion.completeError(JsDisposedError(message));
    }
    pending.clear();
  }

  Future<void> _consumeCallbackResult(
    JSInvokable function,
    List<dynamic> arguments,
    void Function(dynamic result) consume, {
    void Function(dynamic result, StackTrace? rejectionStack)? consumeImmediate,
  }) {
    _checkActive();
    final nativeEngine = _engine;
    final invocation = _JsCallbackInvocation(this, nativeEngine, consume);
    _callbackInvocations.add(invocation);
    // A callback can synchronously reenter shutdown through a Dart bridge.
    // Keep its native stack alive until invocation and lease release return.
    final frame = Completer<void>();
    final bridges = nativeEngine == null
        ? null
        : _bridgeDrains.putIfAbsent(nativeEngine, () => {});
    bridges?.add(frame.future);
    JSInvokable? lease;
    Object? result;
    StackTrace? rejectionStack;
    try {
      try {
        final call =
            _unwrapInvocationGraph([function, arguments], nativeEngine) as List;
        final raw = call[0] as JSInvokable;
        raw.dup();
        lease = raw;
        // Invoke the original function directly. Calling an owned wrapper here
        // would add a logical cancellation waiter ahead of actual completion.
        result = raw.invoke(call[1] as List);
      } catch (error, stack) {
        result = error;
        rejectionStack = stack;
      } finally {
        try {
          lease?.free();
        } catch (error, stack) {
          invocation.cleanupFailures.add((
            resource: 'callback invocation lease',
            error: error,
            stack: stack,
          ));
        }
      }
      if (consumeImmediate != null) {
        invocation.inspectImmediate(result, rejectionStack, consumeImmediate);
      }
      if (rejectionStack != null || result is! Future) {
        invocation.settle(result, rejectionStack);
      } else {
        unawaited(
          result.then<void>(
            (value) => invocation.settle(value, null),
            onError: (Object error, StackTrace stack) =>
                invocation.settle(error, stack),
          ),
        );
      }
    } finally {
      // Immediate conversion may itself reenter shutdown. Keep the original
      // runtime alive until conversion, adoption and Promise observation end.
      bridges?.remove(frame.future);
      frame.complete();
    }
    return invocation.result;
  }

  Future<dynamic> runReadCode(String js, [String? name]) =>
      _runReadCode(js, name, waitForCompletion: false);

  /// Executes once and lends the completed result to a synchronous consumer.
  /// The consumer returns detached Dart data; result/error references are
  /// released before completion. Unlike reads, accepted actions are not
  /// retried or converted to cancellation after their Promise has completed.
  Future<T> runCodeToCompletion<T>(
    String js, {
    required T Function(dynamic result) consume,
    String? name,
  }) async => await _consumeCodeResult(js, name, consume) as T;

  /// Joins the original Promise and lends its result to a synchronous consumer.
  /// The consumer must return detached Dart data: all native result/error
  /// references are released before completion, including after cancellation.
  Future<T> runReadCodeToCompletion<T>(
    String js, {
    required T Function(dynamic result) consume,
    String? name,
  }) async =>
      await _runReadCode(js, name, waitForCompletion: true, consume: consume)
          as T;

  Future<dynamic> _consumeCodeResult(
    String js,
    String? name,
    dynamic Function(dynamic result) consume, {
    RequestScope? scope,
    String operation = 'source call',
  }) async {
    Object? result;
    Object? failure;
    StackTrace? failureStack;
    try {
      result = await runOwnedCode(js, name);
      scope?.check();
      return consume(result);
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
      rethrow;
    } finally {
      try {
        _releaseJsResultReferences([result, failure]);
      } on JsResourceReleaseFailure catch (cleanup) {
        if (failure == null) rethrow;
        throw JsResourceReleaseFailure([
          (resource: operation, error: failure, stack: failureStack!),
          ...cleanup.failures,
        ]);
      }
    }
  }

  Future<dynamic> _runReadCode(
    String js,
    String? name, {
    required bool waitForCompletion,
    dynamic Function(dynamic result)? consume,
  }) async {
    const maxRetries = 2;
    final scope = RequestScope.current;
    for (var retry = 0; ; retry++) {
      try {
        scope?.check();
        if (waitForCompletion) {
          return scope == null
              ? await _consumeCodeResult(
                  js,
                  name,
                  consume!,
                  operation: 'source read',
                )
              : await scope.runToCompletion(
                  () => _consumeCodeResult(
                    js,
                    name,
                    consume!,
                    scope: scope,
                    operation: 'source read',
                  ),
                );
        }
        return scope == null
            ? await runCode(js, name)
            : await scope.run(() => runCode(js, name));
      } catch (error) {
        if (waitForCompletion &&
            (scope?.isCancelled == true || error is JsResourceReleaseFailure)) {
          rethrow;
        }
        scope?.check();
        if (retry >= maxRetries || !_isRetryableReadError(error)) {
          rethrow;
        }
        Log.warning(
          'JS Engine',
          'Retrying a read-only source call after a transient failure '
              '(${retry + 1}/$maxRetries): $error',
        );
        NetworkCacheManager().clear();
        final delay = Duration(milliseconds: 200 * (retry + 1));
        if (scope == null) {
          await Future.delayed(delay);
        } else {
          await scope.wait(delay);
        }
      }
    }
  }

  @visibleForTesting
  static bool debugIsRetryableReadError(Object error) {
    return _isRetryableReadError(error);
  }

  void _releaseResources() {
    for (final entry in _delays.entries) {
      entry.key.cancel();
      entry.value.completeError(JsDisposedError('JavaScript timer is closed'));
    }
    _delays.clear();
    for (final scope in _httpScopes.toList()) {
      scope.cancel();
    }
    _failPendingResults(_pendingResults, 'JS engine is disposed');
    final scopes = _callbackScopes.toList();
    final ownedReferences = _ownedReferences.toList();
    _closed = true;
    _closeComputePool();
    final engine = _engine;
    if (engine != null) {
      for (final delivery in _bridgeResults[engine] ?? <Completer<dynamic>>{}) {
        if (!delivery.isCompleted) {
          delivery.completeError(
            JsDisposedError('JavaScript bridge is closed'),
          );
        }
      }
    }
    final client = _dio;
    final temporaryClients = _temporaryClients.toList();
    final retiredClients = _retiredClients.toList();
    _engine = null;
    _dio = null;
    _temporaryClients.clear();
    _retiredClients.clear();
    final clients = [?client, ...temporaryClients, ...retiredClients];
    final adapters = [
      for (final client in clients)
        if (client.httpClientAdapter case final RHttpAdapter adapter) adapter,
    ];
    try {
      _releaseJsResources([
        for (final reference in ownedReferences)
          (name: 'owned result reference', release: reference.destroy),
        for (final scope in scopes)
          (name: 'callback scope', release: scope.dispose),
        if (engine != null)
          (name: 'runtime', release: () => _releaseNative(engine)),
        if (client != null)
          (name: 'HTTP client', release: () => client.close(force: true)),
        for (final temporary in temporaryClients)
          (
            name: 'temporary HTTP client',
            release: () => temporary.close(force: true),
          ),
        for (final retired in retiredClients)
          (
            name: 'retired HTTP client',
            release: () => retired.close(force: true),
          ),
      ]);
    } on JsResourceReleaseFailure catch (error) {
      _shutdownFailures.addAll(error.failures);
      rethrow;
    } finally {
      for (final adapter in adapters) {
        unawaited(_drainAdapter(adapter));
      }
    }
  }

  void _releaseNative(FlutterQjs engine) {
    void release() {
      _bridgeDrains.remove(engine);
      _bridgeResults.remove(engine);
      Object? failure;
      StackTrace? failureStack;
      try {
        _releaseJsResources([
          (name: 'runtime', release: engine.close),
          (name: 'runtime port', release: engine.port.close),
        ]);
      } catch (error, stack) {
        failure = error;
        failureStack = stack;
        rethrow;
      } finally {
        for (final invocation in _callbackInvocations.toList()) {
          if (identical(invocation.nativeEngine, engine)) {
            invocation.runtimeClosed(failure, failureStack);
          }
        }
      }
    }

    final bridges = _bridgeDrains[engine];
    if (bridges == null || bridges.isEmpty) {
      release();
      return;
    }
    late final Future<void> settled;
    settled = Future<void>(() async {
      while (bridges.isNotEmpty) {
        await Future.wait(bridges.toList());
      }
      try {
        release();
      } on JsResourceReleaseFailure catch (error) {
        _shutdownFailures.addAll(error.failures);
      } finally {
        _nativeReleases.remove(settled);
      }
    });
    _nativeReleases.add(settled);
  }

  Future<void> _drainAdapter(RHttpAdapter adapter) =>
      _adapterDrains.putIfAbsent(adapter, () async {
        try {
          await adapter.waitForIdle();
        } catch (error, stack) {
          _failedAdapterDrains.add(adapter);
          _shutdownFailures.add((
            resource: 'native HTTP requests',
            error: error,
            stack: stack,
          ));
        }
      });

  /// Join actual bridge HTTP operations and native cleanup after invalidating
  /// JS callbacks. A logical disposed/cancelled result does not prove idle.
  Future<void> closeAndWait() {
    final closing = _closeFuture;
    if (closing != null) return closing;
    final completion = Completer<void>();
    _closeFuture = completion.future;
    try {
      dispose();
    } on JsResourceReleaseFailure {
      // Synchronous disposal recorded each failure; drain the other resources.
    } catch (error, stack) {
      _shutdownFailures.add((resource: 'dispose', error: error, stack: stack));
    }
    _finishClose().then(completion.complete, onError: completion.completeError);
    return completion.future;
  }

  Future<void> _finishClose() async {
    if (initializationState == InitializationState.initializing) {
      try {
        await ensureInit();
      } catch (_) {
        // Initialization has its own result; cleanup errors are retained below.
      }
    }
    while (_pendingHttp.isNotEmpty) {
      await Future.wait(_pendingHttp.toList());
    }
    while (_nativeReleases.isNotEmpty) {
      await Future.wait(_nativeReleases.toList());
    }
    while (_callbackInvocations.isNotEmpty) {
      await Future.wait(
        _callbackInvocations.map((call) => call.settled).toList(),
      );
    }
    await Future.wait(_adapterDrains.values.toList());
    await Future.wait(_computeClosures.values.toList());
    if (_shutdownFailures.isNotEmpty) {
      throw JsResourceReleaseFailure(_shutdownFailures);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (identical(_cache, this)) _cache = null;
    _releaseResources();
  }
}

/// One consuming call, independent of its snapshot scope's logical waiters.
class _JsCallbackInvocation {
  _JsCallbackInvocation(this.owner, this.nativeEngine, this.consume);
  final JsEngine owner;
  final FlutterQjs? nativeEngine;
  final void Function(dynamic result) consume;
  final _completion = Completer<void>();
  final cleanupFailures =
      <({String resource, Object error, StackTrace stack})>[];
  ({Object error, StackTrace stack})? _immediateFailure;
  bool _settling = false;
  late final Future<void> settled = result.then<void>(
    (_) {},
    onError: (Object _) {},
  );
  Future<void> get result => _completion.future;

  void inspectImmediate(
    Object? raw,
    StackTrace? rejectionStack,
    void Function(dynamic result, StackTrace? rejectionStack) inspect,
  ) {
    Object? value = raw;
    var stack = rejectionStack;
    if (stack == null && !owner._ownsRuntime(nativeEngine)) {
      value = JsDisposedError('JavaScript callback runtime is closed');
      stack = StackTrace.current;
    }
    if (cleanupFailures.isNotEmpty) {
      value = JsResourceReleaseFailure([
        if (stack != null) (resource: 'callback', error: value!, stack: stack),
        ...cleanupFailures,
      ]);
      stack ??= cleanupFailures.first.stack;
    }
    if (stack == null && raw is Future) {
      // Match ordinary scoped Future<dynamic> string conversion without
      // lending native values that would outlive this synchronous consumer.
      final marker = result.then<dynamic>((_) => null);
      marker.ignore();
      value = marker;
    }
    try {
      inspect(value, stack);
    } catch (error, stack) {
      _immediateFailure = (error: error, stack: stack);
    }
  }

  void settle(Object? raw, StackTrace? rejectionStack) {
    if (_completion.isCompleted) return; // The original native runtime ended.
    _settling = true;
    Object? borrowed = raw;
    Object? failure;
    StackTrace? failureStack;
    try {
      if (owner._ownsRuntime(nativeEngine)) {
        borrowed = owner._ownResult(raw, owner._pendingResults, nativeEngine);
        final immediate = _immediateFailure;
        if (immediate != null) {
          _immediateFailure = (
            error:
                owner._ownResult(
                      immediate.error,
                      owner._pendingResults,
                      nativeEngine,
                    )
                    as Object,
            stack: immediate.stack,
          );
        }
      }
      if (rejectionStack != null) {
        Error.throwWithStackTrace(borrowed!, rejectionStack);
      }
      if (!owner._ownsRuntime(nativeEngine)) {
        throw JsDisposedError('JavaScript callback runtime is closed');
      }
      consume(borrowed);
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      try {
        discardJsResult([borrowed, failure, _immediateFailure?.error]);
      } catch (error, stack) {
        if (error is JsResourceReleaseFailure) {
          cleanupFailures.addAll(error.failures);
        } else {
          cleanupFailures.add((
            resource: 'callback result cleanup',
            error: error,
            stack: stack,
          ));
        }
      }
      owner._shutdownFailures.addAll(cleanupFailures);
      _finish(failure, failureStack);
    }
  }

  void runtimeClosed(Object? failure, StackTrace? stack) {
    if (_completion.isCompleted || _settling) return;
    if (failure != null) {
      cleanupFailures.add((
        resource: 'callback runtime',
        error: failure,
        stack: stack!,
      ));
    }
    _finish(
      JsDisposedError('JavaScript callback runtime is closed'),
      StackTrace.current,
    );
  }

  void _finish(Object? failure, StackTrace? stack) {
    owner._callbackInvocations.remove(this);
    // Observe ignored results without changing the Future seen by its caller.
    unawaited(settled);
    final immediate = _immediateFailure;
    if (cleanupFailures.isNotEmpty || (failure != null && immediate != null)) {
      _completion.completeError(
        JsResourceReleaseFailure([
          if (failure != null)
            (resource: 'callback', error: failure, stack: stack!),
          if (immediate != null)
            (
              resource: 'immediate callback consumer',
              error: immediate.error,
              stack: immediate.stack,
            ),
          ...cleanupFailures,
        ]),
        stack,
      );
    } else if (failure != null) {
      _completion.completeError(failure, stack);
    } else if (immediate != null) {
      _completion.completeError(immediate.error, immediate.stack);
    } else {
      _completion.complete();
    }
  }
}

/// The Dart reference count belongs to callers; runtime shutdown can still
/// destroy the adopted native reference regardless of outstanding dup calls.
class _OwnedJsReference extends JSRef {
  _OwnedJsReference(this.owner, this.nativeEngine, this._reference);

  final JsEngine owner;
  final FlutterQjs? nativeEngine;
  JSRef? _reference;
  final _pendingResults = <Completer<dynamic>>{};

  void checkActive() {
    if (_reference == null || !owner._ownsRuntime(nativeEngine)) {
      throw JsDisposedError('JavaScript reference has been released');
    }
  }

  @override
  void dup() {
    checkActive();
    super.dup();
  }

  @override
  void destroy() {
    final reference = _reference;
    if (reference == null) return;
    _reference = null;
    owner._ownedReferences.remove(this);
    _releaseJsResources([
      (
        name: 'pending callback results',
        release: () => owner._failPendingResults(
          _pendingResults,
          'JavaScript callback has been released',
        ),
      ),
      (name: 'native reference', release: reference.free),
    ]);
  }
}

class _OwnedJsInvokable extends _OwnedJsReference implements JSInvokable {
  _OwnedJsInvokable(
    super.owner,
    super.nativeEngine,
    JSInvokable super.reference,
  );

  @override
  dynamic invoke(List args, [dynamic thisVal]) {
    checkActive();
    // Both graphs share one identity map so argument/receiver aliases survive.
    final invocation =
        owner._unwrapInvocationGraph([args, thisVal], nativeEngine) as List;
    final dynamic result;
    try {
      result = (_reference! as JSInvokable).invoke(
        invocation[0] as List,
        invocation[1],
      );
    } catch (error, stack) {
      Error.throwWithStackTrace(
        owner._ownResult(error, _pendingResults, nativeEngine) as Object,
        stack,
      );
    }
    return owner._trackOwnedResult(result, _pendingResults, nativeEngine);
  }

  @override
  dynamic call(List args, [dynamic thisVal]) => invoke(args, thisVal);
}

bool _isRetryableReadError(Object error) {
  final message = error.toString().toLowerCase();
  final isJsonParseFailure =
      (message.contains('syntaxerror') || message.contains('syntax error')) &&
      (message.contains('json') ||
          message.contains('unexpected token') ||
          message.contains('unexpected end'));
  if (isJsonParseFailure) {
    return true;
  }

  const transientNetworkFailures = [
    'connection timeout',
    'connection timed out',
    'receive timeout',
    'send timeout',
    'connection reset',
    'connection closed',
    'connection aborted',
    'connection terminated',
    'failed host lookup',
    'temporary failure in name resolution',
    'unexpected end of file',
    'unexpected eof',
    'response ended prematurely',
    'stream was reset',
    'http2',
    'http/2',
  ];
  return transientNetworkFailures.any(message.contains);
}

mixin class _JSEngineApi {
  final _documents = <int, DocumentWrapper>{};

  Object? handleHtmlCallback(Map<String, dynamic> data) {
    switch (data["function"]) {
      case "parse":
        if (_documents.length > 8) {
          var shouldDelete = _documents.keys.first;
          Log.warning(
            "JS Engine",
            "Too many documents, deleting the oldest: $shouldDelete\n"
                "Current documents: ${_documents.keys}",
          );
          _documents.remove(shouldDelete);
        }
        _documents[data["key"]] = DocumentWrapper.parse(data["data"]);
        return null;
      case "querySelector":
        var key = data["key"];
        return _documents[key]!.querySelector(data["query"]);
      case "querySelectorAll":
        var key = data["key"];
        return _documents[key]!.querySelectorAll(data["query"]);
      case "getText":
        return _documents[data["doc"]]!.elementGetText(data["key"]);
      case "getAttributes":
        var res = _documents[data["doc"]]!.elementGetAttributes(data["key"]);
        return res;
      case "dom_querySelector":
        var doc = _documents[data["doc"]]!;
        return doc.elementQuerySelector(data["key"], data["query"]);
      case "dom_querySelectorAll":
        var doc = _documents[data["doc"]]!;
        return doc.elementQuerySelectorAll(data["key"], data["query"]);
      case "getChildren":
        var doc = _documents[data["doc"]]!;
        return doc.elementGetChildren(data["key"]);
      case "getNodes":
        var doc = _documents[data["doc"]]!;
        return doc.elementGetNodes(data["key"]);
      case "getInnerHTML":
        var doc = _documents[data["doc"]]!;
        return doc.elementGetInnerHTML(data["key"]);
      case "getParent":
        var doc = _documents[data["doc"]]!;
        return doc.elementGetParent(data["key"]);
      case "node_text":
        return _documents[data["doc"]]!.nodeGetText(data["key"]);
      case "node_type":
        return _documents[data["doc"]]!.nodeType(data["key"]);
      case "node_to_element":
        return _documents[data["doc"]]!.nodeToElement(data["key"]);
      case "dispose":
        var docKey = data["key"];
        _documents.remove(docKey);
        return null;
      case "getClassNames":
        return _documents[data["doc"]]!.getClassNames(data["key"]);
      case "getId":
        return _documents[data["doc"]]!.getId(data["key"]);
      case "getLocalName":
        return _documents[data["doc"]]!.getLocalName(data["key"]);
      case "getElementById":
        return _documents[data["key"]]!.getElementById(data["id"]);
      case "getPreviousSibling":
        return _documents[data["doc"]]!.getPreviousSibling(data["key"]);
      case "getNextSibling":
        return _documents[data["doc"]]!.getNextSibling(data["key"]);
    }
    return null;
  }

  dynamic handleCookieCallback(Map<String, dynamic> data) =>
      AppDataOperations.instance.accessSync(() {
        final cookieJar =
            SingleInstanceCookieJar.instance ??
            (throw StateError('Cookie database is not initialized'));
        switch (data["function"]) {
          case "set":
            cookieJar.saveFromResponse(
              Uri.parse(data["url"]),
              (data["cookies"] as List).map((e) {
                var c = Cookie(e["name"], e["value"]);
                if (e['domain'] != null) {
                  c.domain = e['domain'];
                }
                return c;
              }).toList(),
            );
            return null;
          case "get":
            var cookies = cookieJar.loadForRequest(Uri.parse(data["url"]));
            return cookies
                .map(
                  (e) => {
                    "name": e.name,
                    "value": e.value,
                    "domain": e.domain,
                    "path": e.path,
                    "expires": e.expires,
                    "max-age": e.maxAge,
                    "secure": e.secure,
                    "httpOnly": e.httpOnly,
                    "session": e.expires == null,
                  },
                )
                .toList();
          case "delete":
            cookieJar.deleteUri(Uri.parse(data["url"]));
            return null;
        }
        return null;
      });

  Object? _convert(Map<String, dynamic> data) {
    String type = data["type"];
    var value = data["value"];
    bool isEncode = data["isEncode"];
    try {
      switch (type) {
        case "utf8":
          return isEncode ? utf8.encode(value) : utf8.decode(value);
        case "gbk":
          final codec = const GbkCodec();
          return isEncode
              ? Uint8List.fromList(codec.encode(value))
              : codec.decode(value);
        case "base64":
          return isEncode ? base64Encode(value) : base64Decode(value);
        case "md5":
          return Uint8List.fromList(md5.convert(value).bytes);
        case "sha1":
          return Uint8List.fromList(sha1.convert(value).bytes);
        case "sha256":
          return Uint8List.fromList(sha256.convert(value).bytes);
        case "sha512":
          return Uint8List.fromList(sha512.convert(value).bytes);
        case "hmac":
          var key = data["key"];
          var hash = data["hash"];
          var hmac = Hmac(switch (hash) {
            "md5" => md5,
            "sha1" => sha1,
            "sha256" => sha256,
            "sha512" => sha512,
            _ => throw "Unsupported hash: $hash",
          }, key);
          if (data['isString'] == true) {
            return hmac.convert(value).toString();
          } else {
            return Uint8List.fromList(hmac.convert(value).bytes);
          }
        case "aes-ecb":
          var key = data["key"];
          var cipher = ECBBlockCipher(AESEngine());
          cipher.init(isEncode, KeyParameter(key));
          var offset = 0;
          var result = Uint8List(value.length);
          while (offset < value.length) {
            offset += cipher.processBlock(value, offset, result, offset);
          }
          return result;
        case "aes-cbc":
          var key = data["key"];
          var iv = data["iv"];
          var cipher = CBCBlockCipher(AESEngine());
          cipher.init(isEncode, ParametersWithIV(KeyParameter(key), iv));
          var offset = 0;
          var result = Uint8List(value.length);
          while (offset < value.length) {
            offset += cipher.processBlock(value, offset, result, offset);
          }
          return result;
        case "aes-cfb":
          var key = data["key"];
          var iv = data["iv"];
          var blockSize = data["blockSize"];
          var cipher = CFBBlockCipher(AESEngine(), blockSize);
          cipher.init(isEncode, ParametersWithIV(KeyParameter(key), iv));
          var offset = 0;
          var result = Uint8List(value.length);
          while (offset < value.length) {
            offset += cipher.processBlock(value, offset, result, offset);
          }
          return result;
        case "aes-ofb":
          var key = data["key"];
          var blockSize = data["blockSize"];
          var cipher = OFBBlockCipher(AESEngine(), blockSize);
          cipher.init(isEncode, KeyParameter(key));
          var offset = 0;
          var result = Uint8List(value.length);
          while (offset < value.length) {
            offset += cipher.processBlock(value, offset, result, offset);
          }
          return result;
        case "rsa":
          if (!isEncode) {
            var key = data["key"];
            final cipher = PKCS1Encoding(RSAEngine());
            cipher.init(
              false,
              PrivateKeyParameter<RSAPrivateKey>(_parsePrivateKey(key)),
            );
            return _processInBlocks(cipher, value);
          }
          return null;
        default:
          return value;
      }
    } catch (e, s) {
      Log.error("JS Engine", "Failed to convert $type: $e", s);
      return null;
    }
  }

  RSAPrivateKey _parsePrivateKey(String privateKeyString) {
    List<int> privateKeyDER = base64Decode(privateKeyString);
    var asn1Parser = ASN1Parser(privateKeyDER as Uint8List);
    final topLevelSeq = asn1Parser.nextObject() as ASN1Sequence;
    final privateKey = topLevelSeq.elements![2];

    asn1Parser = ASN1Parser(privateKey.valueBytes!);
    final pkSeq = asn1Parser.nextObject() as ASN1Sequence;

    final modulus = pkSeq.elements![1] as ASN1Integer;
    final privateExponent = pkSeq.elements![3] as ASN1Integer;
    final p = pkSeq.elements![4] as ASN1Integer;
    final q = pkSeq.elements![5] as ASN1Integer;

    return RSAPrivateKey(
      modulus.integer!,
      privateExponent.integer!,
      p.integer!,
      q.integer!,
    );
  }

  Uint8List _processInBlocks(AsymmetricBlockCipher engine, Uint8List input) {
    final numBlocks =
        input.length ~/ engine.inputBlockSize +
        ((input.length % engine.inputBlockSize != 0) ? 1 : 0);

    final output = Uint8List(numBlocks * engine.outputBlockSize);

    var inputOffset = 0;
    var outputOffset = 0;
    while (inputOffset < input.length) {
      final chunkSize = (inputOffset + engine.inputBlockSize <= input.length)
          ? engine.inputBlockSize
          : input.length - inputOffset;

      outputOffset += engine.processBlock(
        input,
        inputOffset,
        chunkSize,
        output,
        outputOffset,
      );

      inputOffset += chunkSize;
    }

    return (output.length == outputOffset)
        ? output
        : output.sublist(0, outputOffset);
  }

  num _random(num min, num max, String type) {
    if (type == "double") {
      return min + (max - min) * math.Random().nextDouble();
    }
    return (min + (max - min) * math.Random().nextDouble()).toInt();
  }
}

class DocumentWrapper {
  final dom.Document doc;

  DocumentWrapper.parse(String doc) : doc = html.parse(doc);

  var elements = <dom.Element>[];

  var nodes = <dom.Node>[];

  int? querySelector(String query) {
    var element = doc.querySelector(query);
    if (element == null) return null;
    elements.add(element);
    return elements.length - 1;
  }

  List<int> querySelectorAll(String query) {
    var res = doc.querySelectorAll(query);
    var keys = <int>[];
    for (var element in res) {
      elements.add(element);
      keys.add(elements.length - 1);
    }
    return keys;
  }

  String? elementGetText(int key) {
    return elements[key].text;
  }

  Map<String, String> elementGetAttributes(int key) {
    return elements[key].attributes.map(
      (key, value) => MapEntry(key.toString(), value),
    );
  }

  String? elementGetInnerHTML(int key) {
    return elements[key].innerHtml;
  }

  int? elementGetParent(int key) {
    var res = elements[key].parent;
    if (res == null) return null;
    elements.add(res);
    return elements.length - 1;
  }

  int? elementQuerySelector(int key, String query) {
    var res = elements[key].querySelector(query);
    if (res == null) return null;
    elements.add(res);
    return elements.length - 1;
  }

  List<int> elementQuerySelectorAll(int key, String query) {
    var res = elements[key].querySelectorAll(query);
    var keys = <int>[];
    for (var element in res) {
      elements.add(element);
      keys.add(elements.length - 1);
    }
    return keys;
  }

  List<int> elementGetChildren(int key) {
    var res = elements[key].children;
    var keys = <int>[];
    for (var element in res) {
      elements.add(element);
      keys.add(elements.length - 1);
    }
    return keys;
  }

  List<int> elementGetNodes(int key) {
    var res = elements[key].nodes;
    var keys = <int>[];
    for (var node in res) {
      nodes.add(node);
      keys.add(nodes.length - 1);
    }
    return keys;
  }

  String? nodeGetText(int key) {
    return nodes[key].text;
  }

  String nodeType(int key) {
    return switch (nodes[key].nodeType) {
      dom.Node.ELEMENT_NODE => "element",
      dom.Node.TEXT_NODE => "text",
      dom.Node.COMMENT_NODE => "comment",
      dom.Node.DOCUMENT_NODE => "document",
      _ => "unknown",
    };
  }

  int? nodeToElement(int key) {
    if (nodes[key] is dom.Element) {
      elements.add(nodes[key] as dom.Element);
      return elements.length - 1;
    }
    return null;
  }

  List<String> getClassNames(int key) {
    return (elements[key]).classes.toList();
  }

  String? getId(int key) {
    return (elements[key]).id;
  }

  String? getLocalName(int key) {
    return (elements[key]).localName;
  }

  int? getElementById(String id) {
    var element = doc.getElementById(id);
    if (element == null) return null;
    elements.add(element);
    return elements.length - 1;
  }

  int? getPreviousSibling(int key) {
    var res = elements[key].previousElementSibling;
    if (res == null) return null;
    elements.add(res);
    return elements.length - 1;
  }

  int? getNextSibling(int key) {
    var res = elements[key].nextElementSibling;
    if (res == null) return null;
    elements.add(res);
    return elements.length - 1;
  }
}

/// Explicit ownership for native callbacks retained beyond one evaluation.
/// Scopes are released by their owner, or before their engine closes.
class JsCallbackScope {
  JsCallbackScope({JsEngine? engine})
    : _engine = engine ?? JsEngine(),
      _parent = null {
    _engine._callbackScopes.add(this);
  }
  JsCallbackScope._child(this._engine, this._parent);
  final JsEngine _engine;
  final JsCallbackScope? _parent;
  final _children = <JsCallbackScope>{};

  void checkActive() {
    if (_disposed) throw JsDisposedError('JavaScript callback scope is closed');
  }

  JsCallbackScope fork() {
    if (_disposed) throw StateError('JavaScript callback scope is closed');
    final child = JsCallbackScope._child(_engine, this);
    _children.add(child);
    return child;
  }

  final _functions = <JSInvokable>{};
  final _pendingResults = <Completer<dynamic>>{};
  bool _disposed = false;

  void _retain(JSInvokable function) {
    if (_disposed) throw StateError('JavaScript callback scope is closed');
    if (_functions.add(function)) function.dup();
  }

  JsCallback retain(JSInvokable function) {
    _retain(function);
    return (args, {consume}) {
      if (_disposed) throw StateError('JavaScript callback scope is closed');
      if (consume != null) {
        return _engine._consumeCallbackResult(function, args, consume);
      }
      return _engine._trackResult(function(args), _pendingResults);
    };
  }

  JsImmediateCallback retainImmediate(JSInvokable function) {
    _retain(function);
    return (arguments, consume) {
      if (_disposed) throw StateError('JavaScript callback scope is closed');
      return _engine._consumeCallbackResult(
        function,
        arguments,
        (_) {},
        consumeImmediate: consume,
      );
    };
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _engine._failPendingResults(
      _pendingResults,
      'JavaScript callback scope is closed',
    );
    final children = _children.toList();
    final functions = _functions.toList();
    _parent?._children.remove(this);
    _engine._callbackScopes.remove(this);
    _children.clear();
    _functions.clear();
    _releaseJsResources([
      for (final child in children)
        (name: 'child scope', release: child.dispose),
      for (final function in functions)
        (name: 'callback', release: function.free),
    ]);
  }
}

/// Worker bootstrap belongs to the runtime; the pool owns only scheduling and ports.
void runJsComputeWorker(JsWorkerStart params) async {
  var sendPort = params.replies;
  final port = ReceivePort();
  sendPort.send(port.sendPort);
  final engine = JsEngine.create(loadInitScript: () async => params.script);
  Exception? failure;
  try {
    await engine.init();
    await for (final message in port) {
      if (message is JsWorkerStop) break;
      if (message is Task) {
        JSInvokable? jsFunc;
        dynamic result;
        try {
          final evaluated = engine.runCode(message.jsFunction);
          if (evaluated is! JSInvokable) {
            result = evaluated;
            throw Exception(
              "The provided code does not evaluate to a function.",
            );
          }
          jsFunc = evaluated;
          result = await jsFunc.invoke(message.args);
          validateJsComputeTransferValue(result, Set<Object>.identity());
          sendPort.send(TaskResult(message.id, result, null));
        } catch (e) {
          sendPort.send(TaskResult(message.id, null, e.toString()));
        } finally {
          JSRef.freeRecursive(result);
          jsFunc?.free();
        }
      }
    }
  } catch (e, s) {
    // Publishing the failure triggers the parent's forced-close path. Defer
    // it until owned resources finish cleanup so that path cannot interrupt us.
    failure = Exception("JS worker failed: $e\n$s");
  } finally {
    final errors = <String>[];
    try {
      await engine.closeAndWait();
    } catch (error) {
      errors.add('engine: $error');
    }
    port.close();
    sendPort.send(JsWorkerStopped(errors.isEmpty ? null : errors.join('; ')));
    if (failure != null) sendPort.send(failure);
    Isolate.exit();
  }
}
