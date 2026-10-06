import 'package:flutter/widgets.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';

import 'window_selection_task.dart';

/// UI save boundary: the original window/host retains unfinished platform work
/// and failed cleanup even after this caller disappears.
Future<bool> saveFileForWindow(
  BuildContext context, {
  Uint8List? data,
  File? file,
  required String filename,
  void Function()? checkStop,
}) async {
  if (!context.mounted) return false;
  final task = WindowSelectionTask(context);
  try {
    return await task.run(
      (operation) => saveFile(
        operation: operation,
        data: data,
        file: file,
        filename: filename,
        checkStop: checkStop,
      ),
    );
  } on SelectionCancelled {
    return false;
  } on ImageWorkTaskCancelled {
    return false;
  } catch (error, stack) {
    Log.error('File save', error, stack);
    if (context.mounted && task.canPresent) {
      context.showMessage(message: 'Error'.tl);
    }
    return false;
  }
}
