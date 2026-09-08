import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/translations.dart';

import 'document_import.dart';
import 'pdf_import.dart';
import 'pdf_import_batch.dart';

Future<PdfImportBatchResult?> showPdfImportDialog({
  required BuildContext context,
  required List<FileSelection> files,
  required PdfImportBatch batch,
}) async {
  PdfImportBatchResult? result;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PdfImportDialog(
      files: files,
      batch: batch,
      onFinished: (value) => result = value,
    ),
  );
  return result;
}

class PdfImportDialog extends StatefulWidget {
  const PdfImportDialog({
    super.key,
    required this.files,
    required this.batch,
    this.onFinished,
  });

  final List<FileSelection> files;
  final PdfImportBatch batch;
  final ValueChanged<PdfImportBatchResult>? onFinished;

  @override
  State<PdfImportDialog> createState() => _PdfImportDialogState();
}

class _PdfImportDialogState extends State<PdfImportDialog> {
  final _cancellation = DocumentImportCancellation();
  PdfImportBatchProgress? _progress;
  PdfImportBatchResult? _result;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    final result = await widget.batch.run(
      widget.files,
      cancellation: _cancellation,
      onProgress: (value) {
        if (mounted) setState(() => _progress = value);
      },
    );
    widget.onFinished?.call(result);
    if (mounted) setState(() => _result = result);
  }

  void _cancel() {
    if (_cancellation.isCancelled) return;
    setState(_cancellation.cancel);
  }

  @override
  void dispose() {
    _cancellation.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final title = result != null
        ? (result.count(PdfImportStatus.cancelled) > 0
              ? 'PDF import cancelled'.tl
              : 'PDF import complete'.tl)
        : (_cancellation.isCancelled
              ? 'Cancelling import'.tl
              : 'Importing PDF'.tl);
    return PopScope(
      canPop: result != null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && result == null) _cancel();
      },
      child: ContentDialog(
        title: title,
        dismissible: result != null,
        content: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: SizedBox(
            width: 520,
            child: result == null ? _buildProgress() : _buildResult(result),
          ),
        ),
        actions: [
          if (result == null)
            TextButton.icon(
              onPressed: _cancellation.isCancelled ? null : _cancel,
              icon: const Icon(Icons.stop_circle_outlined),
              label: Text('Cancel'.tl),
            )
          else
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('OK'.tl),
            ),
        ],
      ),
    );
  }

  Widget _buildProgress() {
    final progress = _progress;
    if (progress == null) return const LinearProgressIndicator();
    final pageCount = progress.pageCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'File @current of @total'.tlParams({
            'current': progress.fileIndex + 1,
            'total': progress.fileCount,
          }),
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: progress.fileIndex / progress.fileCount),
        const SizedBox(height: 20),
        Tooltip(
          message: progress.fileName,
          child: Text(
            progress.fileName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          pageCount == null
              ? 'Preparing file'.tl
              : 'Pages: @current/@total'.tlParams({
                  'current': progress.currentPage,
                  'total': pageCount,
                }),
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: pageCount == null || pageCount == 0
              ? null
              : progress.currentPage / pageCount,
        ),
      ],
    );
  }

  Widget _buildResult(PdfImportBatchResult result) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            Text(
              'Imported: @a'.tlParams({
                'a': result.count(PdfImportStatus.imported),
              }),
            ),
            Text(
              'Failed: @a'.tlParams({
                'a': result.count(PdfImportStatus.failed),
              }),
            ),
            Text(
              'Skipped: @a'.tlParams({
                'a': result.count(PdfImportStatus.skipped),
              }),
            ),
            if (result.count(PdfImportStatus.cancelled) > 0)
              Text(
                'Not imported: @a'.tlParams({
                  'a': result.count(PdfImportStatus.cancelled),
                }),
              ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: math.min(320, MediaQuery.sizeOf(context).height * 0.4),
          child: ListView.separated(
            itemCount: result.items.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) =>
                _PdfImportResultRow(result.items[index]),
          ),
        ),
      ],
    );
  }
}

class _PdfImportResultRow extends StatelessWidget {
  const _PdfImportResultRow(this.result);

  final PdfImportResult result;

  String get _description => switch (result.status) {
    PdfImportStatus.imported => 'Imported'.tl,
    PdfImportStatus.cancelled => 'Not imported'.tl,
    PdfImportStatus.skipped => switch (result.skipReason!) {
      PdfImportSkipReason.duplicateFile => 'Duplicate file'.tl,
      PdfImportSkipReason.duplicateTitle =>
        'A comic with this title already exists'.tl,
      PdfImportSkipReason.unsupportedFileType => 'Unsupported file type'.tl,
    },
    PdfImportStatus.failed => _errorDescription(result.error!),
  };

  String _errorDescription(Object error) {
    if (error is PdfPageRenderException) {
      return 'Failed to render PDF page @a'.tlParams({'a': error.page});
    }
    final message = switch (error) {
      FormatException() => error.message,
      PlatformException() => error.message ?? error.code,
      FileSystemException() => error.message,
      _ => error.toString().replaceFirst(RegExp(r'^Exception:\s*'), ''),
    };
    return message.tl;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final icon = switch (result.status) {
      PdfImportStatus.imported => Icons.check_circle_outline,
      PdfImportStatus.failed => Icons.error_outline,
      PdfImportStatus.skipped => Icons.skip_next_outlined,
      PdfImportStatus.cancelled => Icons.stop_circle_outlined,
    };
    final description = _description;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            color: result.status == PdfImportStatus.failed
                ? colorScheme.error
                : colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Tooltip(
                  message: result.name,
                  child: Text(
                    result.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 4),
                Tooltip(
                  message: description,
                  child: Text(
                    description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
