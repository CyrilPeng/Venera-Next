import 'dart:typed_data';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/foundation/js_engine.dart';

final Object _imageProcessingCanceled = Object();

Future<dynamic> waitForReaderImageProcessingResult(
  Future<dynamic> image,
  void Function() onCancel,
  void Function() checkStop, {
  required Future<void> cancelSignal,
}) async {
  var abandoned = false;
  var completed = false;
  dynamic completedValue;
  final tracked = image.then((value) {
    completed = true;
    completedValue = value;
    if (abandoned) JSRef.freeRecursive(value);
    return value;
  });
  void abandon() {
    if (abandoned) return;
    abandoned = true;
    if (completed) JSRef.freeRecursive(completedValue);
  }

  try {
    final result = await Future.any<dynamic>([
      tracked,
      cancelSignal.then((_) => _imageProcessingCanceled),
    ]);
    if (identical(result, _imageProcessingCanceled)) {
      abandon();
      onCancel();
      checkStop();
    }
    checkStop();
    return result ?? Uint8List(0);
  } catch (_) {
    abandon();
    rethrow;
  }
}

/// Execute the existing custom-image protocol with operation-owned callbacks.
Future<Uint8List> processReaderImageBytes(
  Uint8List bytes, {
  required String script,
  required String comicId,
  required String episodeId,
  required int page,
  required String? sourceKey,
  required void Function() checkStop,
  required Future<void> cancelSignal,
}) async {
  checkStop();
  final callbacks = JsCallbackScope();
  dynamic function;
  dynamic result;
  try {
    function = JsEngine().runCode('''
      (() => {
        $script
        return processImage;
      })()
    ''');
    if (function is! JSInvokable) return bytes;
    final process = callbacks.retain(function);
    JSRef.freeRecursive(function);
    function = null;
    result = process([bytes, comicId, episodeId, page, sourceKey]);
    dynamic image = result;
    void Function() onCancel = () {};
    if (result is Map) {
      image = result['image'];
      final cancel = result['onCancel'];
      if (cancel is JSInvokable) {
        final retained = callbacks.retain(cancel);
        onCancel = () => retained([]);
      }
    }
    JSRef.freeRecursive(result);
    result = null;
    if (image is Future) {
      final resolved = await waitForReaderImageProcessingResult(
        image,
        onCancel,
        checkStop,
        cancelSignal: cancelSignal,
      );
      try {
        return resolved is Uint8List ? resolved : bytes;
      } finally {
        JSRef.freeRecursive(resolved);
      }
    }
    checkStop();
    return image is Uint8List ? image : bytes;
  } finally {
    JSRef.freeRecursive(result);
    JSRef.freeRecursive(function);
    callbacks.dispose();
  }
}
