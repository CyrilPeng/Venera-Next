import 'dart:typed_data';
import 'package:venera_next/foundation/image_work.dart';

/// Reads the selected image and starts an external action only while its
/// originating content is current. An already started platform action may finish
/// after the reader closes; its late errors must not update the old UI.
Future<void> useReaderImage({
  required ImageWork work,
  required Future<Uint8List?> Function() read,
  required bool Function() isCurrent,
  required Future<void> Function(Uint8List) consume,
  required void Function() onMissing,
  required void Function(Object) onError,
}) async {
  if (!isCurrent()) return;
  final task = work.start();
  if (task == null) return;
  try {
    final image = await task.read(read);
    task.check();
    if (!isCurrent()) return;
    if (image == null) {
      onMissing();
    } else {
      await consume(image);
    }
  } catch (error, stack) {
    if (error is! ImageWorkTaskCancelled) {
      if (isCurrent() && !task.isCancelled) {
        try {
          onError(error);
        } catch (reportError, reportStack) {
          task.recordFailure(error, stack);
          task.recordFailure(reportError, reportStack);
        }
      } else {
        task.recordFailure(error, stack);
      }
    }
  } finally {
    task.finish();
  }
}
