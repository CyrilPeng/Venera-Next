import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/log.dart';

import 'document_import.dart';

enum PdfImportStatus { imported, skipped, failed, cancelled }

enum PdfImportSkipReason { duplicateFile, duplicateTitle, unsupportedFileType }

class PdfImportResult {
  const PdfImportResult({
    required this.name,
    required this.status,
    this.skipReason,
    this.error,
  });

  final String name;
  final PdfImportStatus status;
  final PdfImportSkipReason? skipReason;
  final Object? error;
}

class PdfImportBatchResult {
  PdfImportBatchResult(List<PdfImportResult> items)
    : items = List.unmodifiable(items);

  final List<PdfImportResult> items;

  int count(PdfImportStatus status) =>
      items.where((item) => item.status == status).length;
}

class PdfImportBatchProgress {
  const PdfImportBatchProgress({
    required this.fileIndex,
    required this.fileCount,
    required this.fileName,
    this.currentPage = 0,
    this.pageCount,
  });

  final int fileIndex;
  final int fileCount;
  final String fileName;
  final int currentPage;
  final int? pageCount;
}

typedef PdfImportOperation =
    Future<void> Function(
      File file,
      String title,
      DocumentImportProgress onProgress,
      DocumentImportCancellation cancellation,
    );

class PdfImportBatch {
  const PdfImportBatch({required this.importFile, required this.containsTitle});

  final PdfImportOperation importFile;
  final bool Function(String title) containsTitle;

  Future<PdfImportBatchResult> run(
    List<FileSelection> files, {
    required DocumentImportCancellation cancellation,
    void Function(PdfImportBatchProgress progress)? onProgress,
  }) async {
    final results = <PdfImportResult>[];
    final seenFiles = <String>{};
    final importedTitles = <String>{};
    for (var index = 0; index < files.length; index++) {
      final selection = files[index];
      try {
        cancellation.throwIfCancelled();
        onProgress?.call(
          PdfImportBatchProgress(
            fileIndex: index,
            fileCount: files.length,
            fileName: selection.name,
          ),
        );
        final title = File(selection.name).basenameWithoutExt.trim();
        final PdfImportSkipReason? skipReason;
        if (File(selection.name).extension.toLowerCase() != 'pdf') {
          skipReason = PdfImportSkipReason.unsupportedFileType;
        } else if (!seenFiles.add(selection.identifier)) {
          skipReason = PdfImportSkipReason.duplicateFile;
        } else if (importedTitles.contains(title) || containsTitle(title)) {
          skipReason = PdfImportSkipReason.duplicateTitle;
        } else {
          skipReason = null;
        }
        if (skipReason != null) {
          results.add(
            PdfImportResult(
              name: selection.name,
              status: PdfImportStatus.skipped,
              skipReason: skipReason,
            ),
          );
          continue;
        }
        final file = await selection.prepare();
        cancellation.throwIfCancelled();
        await importFile(file, title, (current, total) {
          onProgress?.call(
            PdfImportBatchProgress(
              fileIndex: index,
              fileCount: files.length,
              fileName: selection.name,
              currentPage: current,
              pageCount: total,
            ),
          );
        }, cancellation);
        // Registration is part of importFile; a late cancellation must not
        // relabel a comic that has already been saved.
        importedTitles.add(title);
        results.add(
          PdfImportResult(
            name: selection.name,
            status: PdfImportStatus.imported,
          ),
        );
      } on DocumentImportCancelled {
        cancellation.cancel();
        results.add(
          PdfImportResult(
            name: selection.name,
            status: PdfImportStatus.cancelled,
          ),
        );
      } catch (error, stack) {
        Log.error('Import PDF', '${selection.name}: $error', stack);
        results.add(
          PdfImportResult(
            name: selection.name,
            status: PdfImportStatus.failed,
            error: error,
          ),
        );
      } finally {
        try {
          await selection.dispose();
        } catch (error, stack) {
          Log.error('Import PDF cleanup', error.toString(), stack);
        }
      }
    }
    return PdfImportBatchResult(results);
  }
}
