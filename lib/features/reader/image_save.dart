import 'package:flutter/material.dart';
import 'package:venera_next/components/file_save_task.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/image_directory_save.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';

/// Both reader save entries capture bytes/filename before consulting this
/// device's directory. A native save retains its original window completion.
Future<bool> saveReaderImageForWindow(
  BuildContext context, {
  required Uint8List data,
  required String filename,
  bool chooseLocation = false,
  void Function()? checkStop,
}) async {
  final configured = ImageSavePreferences.directory.normalize(
    appdata.settings[ImageSavePreferences.directory.key],
  );
  if (chooseLocation || configured == null || !ImageDirectorySaver.supported) {
    return saveFileForWindow(
      context,
      data: data,
      filename: filename,
      checkStop: checkStop,
    );
  }
  if (!context.mounted) return false;
  final task = WindowSelectionTask(context);
  try {
    final path = await task.run((operation) async {
      var directory = configured;
      return operation.useTemporaryFile(
        filename: imageSaveFilename(filename),
        cacheDirectory: Directory(App.cachePath),
        prepare: (source) => source.writeAsBytes(data),
        consume: (source) async {
          while (true) {
            operation.checkActive();
            checkStop?.call();
            try {
              return await const ImageDirectorySaver().save(
                directory: directory,
                source: source,
                filename: filename,
                checkStop: () {
                  operation.checkActive();
                  checkStop?.call();
                },
              );
            } on ImageSaveDirectoryUnavailable {
              operation.checkActive();
              if (!context.mounted) throw const SelectionCancelled();
              if (!await _chooseAnotherFolder(context, task)) return null;
              operation.checkActive();
              final selection = await operation.pickDirectory(
                () => DirectoryPicker().pickDirectory(),
              );
              if (selection == null) return null;
              directory = await operation.useDirectory(
                selection,
                (folder) async => folder.path,
              );
              operation.checkActive();
              await appdata.updateSettings(
                (draft) =>
                    draft[ImageSavePreferences.directory.key] = directory,
                sync: false,
              );
            }
          }
        },
      );
    }, reportFailureOnClose: true);
    if (path == null) return false;
    if (context.mounted && task.canPresent) {
      final display = path.startsWith('android://')
          ? path
                .substring('android://'.length)
                .replaceFirst(RegExp(r'^primary:'), '')
          : path;
      context.showMessage(
        message: 'Image saved to @a'.tlParams({'a': display}),
      );
    }
    return true;
  } on SelectionCancelled {
    return false;
  } on ImageWorkTaskCancelled {
    return false;
  } catch (error, stack) {
    Log.error('Reader image save', error, stack);
    if (context.mounted && task.canPresent) {
      context.showMessage(message: 'Unable to save image'.tl);
    }
    return false;
  }
}

Future<bool> _chooseAnotherFolder(
  BuildContext context,
  WindowSelectionTask task,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Image save directory unavailable'.tl),
      content: Text(
        'The folder was removed or access was lost. Choose another folder to save this image.'
            .tl,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text('Cancel'.tl),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text('Choose folder'.tl),
        ),
      ],
    ),
  );
  final release = task.retainPresentation(() {
    if (route.isActive && navigator.mounted) navigator.removeRoute(route);
  }, isCurrent: () => route.isCurrent);
  try {
    task.checkActive();
    return await navigator.push(route) == true;
  } finally {
    release();
  }
}
