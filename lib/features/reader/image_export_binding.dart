import 'package:flutter/widgets.dart';
import 'package:venera_next/components/file_save_task.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/log.dart';

import 'image_export.dart';
import 'image_read.dart';

/// File and platform adapters for one shell's original image-work owner.
/// The exporter owns complete Futures; this binding adds no task queue.
class ReaderImageExportBinding {
  ReaderImageExportBinding({
    required BuildContext context,
    required ImageWork work,
    required ReaderImageExportRequest? Function() createRequest,
    required Future<int?> Function() pick,
    required void Function() cancelSelection,
  }) : _exporter = ReaderImageExporter(
         work: work,
         cancelSelection: cancelSelection,
         select: () async {
           final request = createRequest();
           if (request == null || !request.isCurrent()) return null;
           return request.resolve(await pick());
         },
         read: (selection) async {
           final bytes = await readReaderImageBytes(selection.address);
           if (bytes == null) {
             throw StateError('Selected image is no longer cached');
           }
           return bytes;
         },
         save: (image) async {
           await saveFileForWindow(
             context,
             data: image.bytes,
             filename: image.filename,
             checkStop: image.checkStop,
           );
         },
         share: (image) => Share.shareFile(
           data: image.bytes,
           filename: image.filename,
           mime: image.type.mime,
           resolveOrigin: () => context.sharePositionOrigin,
           checkStop: image.checkStop,
         ),
         onError: (error, stack) {
           Log.error('Reader', 'Failed to export image: $error', stack);
           if (context.mounted) context.showMessage(message: error.toString());
         },
       );

  final ReaderImageExporter _exporter;

  Future<void> export({required bool sharing}) =>
      _exporter.export(sharing: sharing);

  Future<void> dispose() => _exporter.dispose();
}
