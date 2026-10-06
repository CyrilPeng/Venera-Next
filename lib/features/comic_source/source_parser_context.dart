import 'dart:convert';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/res.dart';
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

  Future<dynamic> runReadCode(String code, [String? name]) async {
    checkCurrent();
    return _guardValue(await engine.runReadCode(code, name));
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

  dynamic Function(List<dynamic>) retainCallback(
    JSInvokable function, {
    JsCallbackScope? scope,
  }) {
    final callback = (scope ?? callbacks).retain(function);
    return (arguments) {
      checkCurrent();
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
}
