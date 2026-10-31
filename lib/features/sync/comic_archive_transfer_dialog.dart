import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/features/sync/comic_archive_batch.dart';
import 'package:venera_next/features/sync/comic_backup.dart';
import 'package:venera_next/foundation/translations.dart';

Future<BackupResult> showComicArchiveTransferDialog(
  BuildContext context, {
  required String title,
  required ComicArchiveBatch batch,
}) async {
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ComicArchiveTransferDialog(title: title, batch: batch),
    );
    return BackupResult.fromBatch(batch);
  } finally {
    batch.dispose();
  }
}

class ComicArchiveTransferDialog extends StatefulWidget {
  const ComicArchiveTransferDialog({
    super.key,
    required this.title,
    required this.batch,
  });

  final String title;
  final ComicArchiveBatch batch;

  @override
  State<ComicArchiveTransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends State<ComicArchiveTransferDialog> {
  ComicArchiveBatch get batch => widget.batch;

  @override
  void initState() {
    super.initState();
    batch.addListener(_update);
    unawaited(batch.run());
  }

  void _update() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    batch.removeListener(_update);
    batch.cancel();
    super.dispose();
  }

  static String _status(ArchiveItemState state) => switch (state) {
    ArchiveItemState.pending => 'Not started',
    ArchiveItemState.working => 'In progress',
    ArchiveItemState.success => 'Success',
    ArchiveItemState.skipped => 'Skipped (not verified)',
    ArchiveItemState.failed => 'Failed',
    ArchiveItemState.cancelled => 'Cancelled',
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !batch.running,
      child: Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: SizedBox(
          width: 600,
          height: MediaQuery.sizeOf(context).height * .85,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: batch.items.length + 1,
                  itemBuilder: (context, row) {
                    if (row == 0) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Semantics(
                              liveRegion: true,
                              child: Wrap(
                                spacing: 12,
                                runSpacing: 8,
                                children: [
                                  for (final state in ArchiveItemState.values)
                                    Text(
                                      '${_status(state).tl}: ${batch.count(state)}',
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Results and retries are available until this dialog is closed. No background or restart queue.'
                                  .tl,
                            ),
                            const SizedBox(height: 12),
                            if (batch.running) ...[
                              const LinearProgressIndicator(),
                              const SizedBox(height: 12),
                            ],
                            if (batch.cancelRequested)
                              Text(
                                'Cancellation requested. Waiting for the current operation to finish safely.'
                                    .tl,
                              ),
                            const Divider(),
                          ],
                        ),
                      );
                    }
                    final index = row - 1;
                    final item = batch.items[index];
                    return Padding(
                      key: ValueKey(index),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            item.title,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (item.title != item.fileName) Text(item.fileName),
                          Text(
                            _status(item.state).tl,
                            style: TextStyle(
                              color: item.state == ArchiveItemState.failed
                                  ? colors.error
                                  : colors.onSurface,
                            ),
                          ),
                          if (item.state == ArchiveItemState.skipped)
                            Text(
                              'Remote name already exists. Contents were not verified or overwritten.'
                                  .tl,
                            ),
                          if (item.error case final error?) ...[
                            SelectableText(batch.errorText(error).tl),
                            if (!item.canRetry)
                              Text(
                                'Import may already be saved. Check the local library before retrying; automatic retry is disabled.'
                                    .tl,
                              ),
                          ],
                          if (item.canRetry)
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                style: TextButton.styleFrom(
                                  minimumSize: const Size(48, 48),
                                ),
                                onPressed: batch.running
                                    ? null
                                    : () => unawaited(
                                        batch.run(
                                          retryFailed: true,
                                          onlyIndex: index,
                                        ),
                                      ),
                                child: Text('Retry this item'.tl),
                              ),
                            ),
                          const Divider(),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (batch.running)
                      TextButton(
                        onPressed: batch.cancelRequested ? null : batch.cancel,
                        child: Text('Cancel'.tl),
                      )
                    else ...[
                      if (batch.hasRetryableFailures)
                        OutlinedButton(
                          onPressed: () =>
                              unawaited(batch.run(retryFailed: true)),
                          child: Text('Retry all failed items'.tl),
                        ),
                      if (batch.hasPending)
                        OutlinedButton(
                          onPressed: () => unawaited(batch.run()),
                          child: Text('Continue unstarted items'.tl),
                        ),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text('Close'.tl),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
