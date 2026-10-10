import 'dart:async';
import 'dart:convert';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/network/request_scope.dart';
import 'models.dart';
import 'normalization.dart';

/// A capability owns one runtime instance, including after an async boundary.
class SourceParserContext {
  SourceParserContext({
    required this.key,
    required this.name,
    required this.callbacks,
    JsSourceIdentity? identity,
  }) : identity = identity ?? _captureIdentity(key);
  final String key;
  final String name;
  final JsCallbackScope callbacks;
  final JsSourceIdentity identity;
  JsEngine get engine => identity.engine;

  static JsSourceIdentity _captureIdentity(String key) {
    final engine = JsEngine();
    return JsSourceIdentity(
      engine,
      engine.runCode(
            '__sourceRuntime.identity(ComicSource.sources[${jsonEncode(key)}])',
          )
          as String,
    );
  }

  String get sourceExpression {
    callbacks.checkActive();
    return '__sourceRuntime.require(${jsonEncode(key)}, ${jsonEncode(identity.id)})';
  }

  void checkCurrent() {
    engine.runCode('$sourceExpression != null');
  }

  dynamic _guardValue(dynamic value) {
    try {
      checkCurrent();
      return value;
    } catch (error, stack) {
      try {
        discardJsResult(value);
      } on JsResourceReleaseFailure catch (cleanup) {
        throw JsResourceReleaseFailure([
          (resource: 'source identity', error: error, stack: stack),
          ...cleanup.failures,
        ]);
      }
      rethrow;
    }
  }

  dynamic _guardResult(dynamic result) => result is Future
      ? result.then<dynamic>(_guardValue)
      : _guardValue(result);

  dynamic runCode(String code, [String? name]) {
    checkCurrent();
    return _guardResult(engine.runCode(code, name));
  }

  dynamic runOwnedCode(String code) {
    checkCurrent();
    return _guardResult(engine.runOwnedCode(code));
  }

  /// Synchronous capability contracts lend values only for conversion. An
  /// unsupported Promise result is observed and released under its runtime,
  /// while the immediate validator/selector retains its synchronous contract.
  T consumeSynchronous<T>(
    dynamic Function() evaluate,
    T Function(dynamic value) consume,
  ) {
    Object? result;
    Object? failure;
    StackTrace? failureStack;
    try {
      checkCurrent();
      result = evaluate();
      checkCurrent();
      return consume(result);
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
      rethrow;
    } finally {
      final graph = [result, failure];
      try {
        discardJsResult(graph);
      } on JsResourceReleaseFailure catch (cleanup) {
        if (failure == null) rethrow;
        throw JsResourceReleaseFailure([
          (
            resource: 'synchronous source call',
            error: failure,
            stack: failureStack!,
          ),
          ...cleanup.failures,
        ]);
      } finally {
        unawaited(
          drainJsResultDescendants(graph).catchError((
            Object error,
            StackTrace stack,
          ) {
            Log.error('Synchronous source result cleanup', error, stack);
          }),
        );
      }
    }
  }

  Future<T> runCodeToCompletion<T>(
    String code, {
    required T Function(dynamic result) consume,
    String? name,
  }) {
    checkCurrent();
    return engine.runCodeToCompletion<T>(
      code,
      consume: (value) {
        checkCurrent();
        return consume(value);
      },
      name: name,
    );
  }

  Future<T> runReadCodeToCompletion<T>(
    String code, {
    required T Function(dynamic result) consume,
    String? name,
  }) {
    checkCurrent();
    return engine.runReadCodeToCompletion<T>(
      code,
      consume: (value) {
        checkCurrent();
        return consume(value);
      },
      name: name,
    );
  }

  JsCallback retainCallback(JSInvokable function, {JsCallbackScope? scope}) {
    final callback = (scope ?? callbacks).retain(function);
    return (arguments, {consume}) {
      checkCurrent();
      if (consume != null) {
        return callback(
          arguments,
          consume: (value) {
            checkCurrent();
            consume(value);
          },
        );
      }
      return _guardResult(callback(arguments));
    };
  }

  bool checkExists(String index) => runCode('${_propertyPath(index)} != null');
  dynamic getValue(String index) => runCode(_propertyPath(index));
  String _propertyPath(String index) =>
      '$sourceExpression?.${index.replaceAll(RegExp(r'(?<!\?)\.'), '?.')}';

  Res<List<Comic>> parseComicListResult(dynamic value, String subDataKey) {
    final data = normalizeComicSourceStringKeyedMap(value);
    final comics = normalizeComicSourceComicList(data?["comics"], key);
    if (data == null || comics == null) throw "Invalid data";
    return Res(comics, subData: data[subDataKey]);
  }

  /// Cancellation retains its original cause/stack at every source boundary.
  Res<T> failureResult<T>(Object error, StackTrace stack) =>
      error is RequestCancelled
      ? Res.failure(
          OperationFailure(
            message: error.toString(),
            kind: FailureKind.cancelled,
            cause: error,
            stackTrace: stack,
          ),
        )
      : Res.fromException(error, stack);
}
