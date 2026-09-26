import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/translations.dart';

import 'pdf_import.dart';
import 'pdf_import_batch.dart';
import 'pdf_import_tasks.dart';

class PdfImportTasksButton extends StatelessWidget {
  const PdfImportTasksButton({super.key, this.tasks});

  final PdfImportTasks? tasks;

  @override
  Widget build(BuildContext context) {
    final manager = tasks ?? PdfImportTasks.instance;
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        if (manager.tasks.isEmpty) return const SizedBox.shrink();
        return IconButton(
          tooltip: 'PDF import tasks'.tl,
          icon: Badge(
            label: Text('${manager.activeCount}'),
            isLabelVisible: manager.activeCount > 0,
            child: const Icon(Icons.picture_as_pdf_outlined),
          ),
          onPressed: () =>
              showPdfImportTasksDialog(context: context, tasks: manager),
        );
      },
    );
  }
}

Future<void> showPdfImportTasksDialog({
  required BuildContext context,
  PdfImportTasks? tasks,
}) {
  final manager = tasks ?? PdfImportTasks.instance;
  return showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: manager,
      builder: (context, _) => ContentDialog(
        title: 'PDF import tasks'.tl,
        content: SizedBox(
          width: 520,
          height: math.min(400, MediaQuery.sizeOf(context).height * 0.55),
          child: manager.tasks.isEmpty
              ? Center(child: Text('No import tasks'.tl))
              : ListView.builder(
                  itemCount: manager.tasks.length,
                  itemBuilder: (context, index) {
                    final task = manager.tasks[index];
                    final progress = task.progress;
                    return ListTile(
                      title: Text(
                        task.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          _taskTitle(task),
                          if (task.result case final result?)
                            'Imported: @a'.tlParams({
                              'a': result.count(PdfImportStatus.imported),
                            }),
                          if (task.result case final result?)
                            'Failed: @a'.tlParams({
                              'a': result.count(PdfImportStatus.failed),
                            }),
                          if (!task.isFinished)
                            'File @current of @total'.tlParams({
                              'current': progress == null
                                  ? 0
                                  : progress.fileIndex + 1,
                              'total': task.fileCount,
                            }),
                        ].join(' · '),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => showPdfImportDialog(
                        context: context,
                        task: task,
                        tasks: manager,
                      ),
                    );
                  },
                ),
        ),
        actions: [
          Flexible(
            child: TextButton(
              onPressed: manager.tasks.any((task) => task.isFinished)
                  ? manager.clearFinished
                  : null,
              child: Text('Clear completed tasks'.tl),
            ),
          ),
        ],
      ),
    ),
  );
}

Future<PdfImportBatchResult?> showPdfImportDialog({
  required BuildContext context,
  required PdfImportTask task,
  PdfImportTasks? tasks,
}) async {
  await showDialog<void>(
    context: context,
    builder: (context) =>
        PdfImportDialog(task: task, tasks: tasks ?? PdfImportTasks.instance),
  );
  return task.result;
}

String _taskTitle(PdfImportTask task) {
  if (task.result case final result?) {
    return result.count(PdfImportStatus.cancelled) > 0
        ? 'PDF import cancelled'.tl
        : 'PDF import complete'.tl;
  }
  if (task.isCancelling) return 'Cancelling import'.tl;
  return task.isQueued ? 'Waiting to import'.tl : 'Importing PDF'.tl;
}

class PdfImportDialog extends StatelessWidget {
  const PdfImportDialog({super.key, required this.task, required this.tasks});

  final PdfImportTask task;
  final PdfImportTasks tasks;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: task,
      builder: (context, _) {
        final result = task.result;
        return ContentDialog(
          title: _taskTitle(task),
          content: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: SizedBox(
              width: 520,
              child: result != null
                  ? _buildResult(context, result)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (task.isQueued)
                          Text(
                            task.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          )
                        else
                          _buildProgress(),
                        const SizedBox(height: 16),
                        Text(
                          'You can keep reading during import. View progress from PDF import tasks in Local.'
                              .tl,
                        ),
                      ],
                    ),
            ),
          ),
          actions: [
            Flexible(
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (result == null) ...[
                    TextButton.icon(
                      onPressed: task.isCancelling
                          ? null
                          : () => tasks.cancel(task),
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: Text('Cancel'.tl),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text('Run in background'.tl),
                    ),
                  ] else
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text('OK'.tl),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildProgress() {
    final progress = task.progress;
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

  Widget _buildResult(BuildContext context, PdfImportBatchResult result) {
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
