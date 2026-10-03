import 'dart:typed_data';

/// Reads the selected image and starts an external action only while its
/// originating content is current. An already started platform action may finish
/// after the reader closes; its late errors must not update the old UI.
Future<void> useReaderImage({
  required Future<Uint8List?> Function() read,
  required bool Function() isCurrent,
  required Future<void> Function(Uint8List) consume,
  required void Function() onMissing,
  required void Function(Object) onError,
}) async {
  if (!isCurrent()) return;
  try {
    final image = await read();
    if (!isCurrent()) return;
    if (image == null) {
      onMissing();
    } else {
      await consume(image);
    }
  } catch (error) {
    if (isCurrent()) onError(error);
  }
}
