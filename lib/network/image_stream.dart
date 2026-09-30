import 'dart:async';
import 'dart:typed_data';

import 'images.dart';

/// Consume one subscription, including cancellation while no events arrive.
/// Releasing this subscription leaves other shared download listeners intact.
Future<Uint8List?> readImageStream(
  Stream<ImageDownloadProgress> stream, {
  required Future<void> cancelSignal,
  required void Function() checkStop,
  void Function(ImageDownloadProgress)? onProgress,
}) async {
  checkStop();
  final iterator = StreamIterator(stream);
  final cancelled = cancelSignal.then((_) => false);
  try {
    while (await Future.any([iterator.moveNext(), cancelled])) {
      checkStop();
      final event = iterator.current;
      onProgress?.call(event);
      if (event.imageBytes != null) return event.imageBytes;
    }
    checkStop();
    return null;
  } finally {
    await iterator.cancel();
  }
}
