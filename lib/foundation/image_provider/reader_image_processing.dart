import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/network/image_loading_config.dart';

import 'image_provider_lifecycle.dart';

class ReaderImageProcessingFailure implements Exception {
  ReaderImageProcessingFailure(
    Iterable<({Object error, StackTrace stack})> failures,
  ) : failures = List.unmodifiable(failures);

  final List<({Object error, StackTrace stack})> failures;

  @override
  String toString() =>
      'Image processing failed: '
      '${failures.map((failure) => failure.error).join('; ')}';
}

/// Cancellation asks the script to stop, but completion still belongs to its
/// original image Future and the optional asynchronous cancellation hook.
Future<dynamic> waitForReaderImageProcessingResult(
  Future<dynamic> image,
  dynamic Function() onCancel,
  void Function() checkStop, {
  required Future<void> cancelSignal,
  ImageLoadingConfigOwner? owner,
}) async {
  final references = owner ?? ImageLoadingConfigOwner(null);
  final failures = <({Object error, StackTrace stack})>[];
  var imageDone = false;
  Future<void>? cancelTask;
  Object? hookValue;
  Object? value;

  // Observe the hook independently so a rejection cannot become unhandled
  // while the original processing Future is still running.
  cancelSignal.then((_) {
    if (imageDone) return;
    cancelTask = Future<dynamic>.sync(onCancel).then<void>(
      (result) => hookValue = result,
      onError: (Object error, StackTrace stack) {
        failures.add((error: error, stack: stack));
      },
    );
  });
  try {
    value = await image;
  } catch (error, stack) {
    failures.add((error: error, stack: stack));
  }
  imageDone = true;
  await cancelTask;
  try {
    checkStop();
    if (cancelTask != null) throw const ImageProviderLoadCancelled();
  } catch (error, stack) {
    failures.add((error: error, stack: stack));
  }

  if (failures.isNotEmpty) {
    final error = failures.length == 1
        ? failures.single.error
        : ReaderImageProcessingFailure(failures);
    final stack = failures.first.stack;
    references.discard(
      [value, hookValue, for (final failure in failures) failure.error],
      cause: error,
      stackTrace: stack,
    );
    Error.throwWithStackTrace(error, stack);
  }
  references.discard(hookValue);
  return value ?? Uint8List(0);
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
  final values = <Object?>[];
  final owner = ImageLoadingConfigOwner(values);
  try {
    final function = JsEngine().runOwnedCode('''
      (() => {
        $script
        return processImage;
      })()
    ''');
    values.add(function);
    if (function is! JSInvokable) return bytes;
    final result = function([bytes, comicId, episodeId, page, sourceKey]);
    values.add(result);
    dynamic image = result;
    dynamic Function() onCancel = () {};
    if (result is Map) {
      image = result['image'];
      final cancel = result['onCancel'];
      if (cancel is JSInvokable) onCancel = () => cancel([]);
    }
    if (image is Future) {
      image = await waitForReaderImageProcessingResult(
        image,
        onCancel,
        checkStop,
        cancelSignal: cancelSignal,
        owner: owner,
      );
      values.add(image);
    }
    checkStop();
    return image is Uint8List ? image : bytes;
  } catch (error, stack) {
    owner.dispose(cause: error, stackTrace: stack);
    rethrow;
  } finally {
    owner.dispose();
  }
}
