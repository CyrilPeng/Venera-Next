import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/features/sync/comic_backup.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/translations.dart';

class ComicArchivePage extends StatefulWidget {
  const ComicArchivePage({super.key});

  @override
  State<ComicArchivePage> createState() => _ComicArchivePageState();
}

class _ComicArchivePageState extends State<ComicArchivePage> {
  List<BackupFile> files = [];
  final selected = <BackupFile>{};
  bool isLoading = true;
  bool isWorking = false;
  String? error;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    setState(() {
      isLoading = true;
      error = null;
      selected.clear();
    });
    final result = await ComicBackupManager.listBackups();
    if (!mounted) return;
    setState(() {
      isLoading = false;
      if (result.error) {
        error = result.errorMessage;
      } else {
        files = result.data;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Comic Archive".tl),
        actions: [
          IconButton(
            tooltip: "Refresh".tl,
            onPressed: isLoading || isWorking ? null : refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: buildBody()),
          if (selected.isNotEmpty) buildActions(),
        ],
      ),
    );
  }

  Widget buildBody() {
    if (isLoading) {
      return const ListLoadingIndicator().toCenter();
    }
    if (error != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(error!, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: refresh, child: Text("Retry".tl)),
        ],
      ).paddingHorizontal(16);
    }
    if (files.isEmpty) {
      return Center(child: Text("No archive files".tl));
    }
    return ListView.builder(
      itemCount: files.length,
      itemBuilder: (context, index) {
        final file = files[index];
        return CheckboxListTile(
          value: selected.contains(file),
          onChanged: isWorking
              ? null
              : (value) {
                  setState(() {
                    if (value == true) {
                      selected.add(file);
                    } else {
                      selected.remove(file);
                    }
                  });
                },
          title: Text(file.name),
          subtitle: Text(
            '${bytesToReadableString(file.size)} · ${_formatTime(file.modified)}',
          ),
        );
      },
    );
  }

  Widget buildActions() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: isWorking ? null : restoreSelected,
                icon: const Icon(Icons.download),
                label: Text("Download and Import".tl),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: isWorking ? null : deleteSelected,
                icon: const Icon(Icons.delete_outline),
                label: Text("Delete".tl),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> restoreSelected() async {
    final targets = selected.toList();
    if (targets.isEmpty) return;
    final result = await showArchiveProgressDialog(
      title: "Download and Import".tl,
      total: targets.length,
      task: (onProgress, isCancelled) => ComicBackupManager.restore(
        targets,
        onProgress: onProgress,
        isCancelled: isCancelled,
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      selected.clear();
    });
    context.showMessage(
      message: 'Success: @a, Failed: @b'.tlParams({
        'a': result.success,
        'b': result.failed,
      }),
    );
  }

  Future<void> deleteSelected() async {
    final targets = selected.toList();
    if (targets.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: "Delete".tl,
        content: Text(
          "Delete selected archive files?".tl,
        ).paddingHorizontal(16),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text("Cancel".tl),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text("Confirm".tl),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = await showArchiveProgressDialog(
      title: "Delete".tl,
      total: targets.length,
      task: (onProgress, isCancelled) async {
        var success = 0;
        var failed = 0;
        final errors = <String>[];
        for (var i = 0; i < targets.length; i++) {
          if (isCancelled()) break;
          final file = targets[i];
          onProgress(i + 1, targets.length, file.name);
          final result = await ComicBackupManager.deleteBackup(file);
          if (result.error) {
            failed++;
            errors.add('${file.name}: ${result.errorMessage}');
          } else {
            success++;
          }
        }
        return BackupResult(
          success: success,
          skipped: 0,
          failed: failed,
          errors: errors,
        );
      },
    );
    if (!mounted || result == null) return;
    context.showMessage(
      message: 'Deleted: @a, Failed: @b'.tlParams({
        'a': result.success,
        'b': result.failed,
      }),
    );
    await refresh();
  }

  Future<BackupResult?> showArchiveProgressDialog({
    required String title,
    required int total,
    required Future<BackupResult> Function(
      void Function(int current, int total, String currentTitle) onProgress,
      bool Function() isCancelled,
    )
    task,
  }) async {
    var current = 0;
    var currentTitle = "";
    var cancelled = false;
    var started = false;
    BackupResult? result;
    setState(() {
      isWorking = true;
    });
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            if (!started) {
              started = true;
              Future.microtask(() async {
                final taskResult = await task((progress, totalCount, title) {
                  if (!context.mounted) return;
                  setState(() {
                    current = progress;
                    currentTitle = title;
                  });
                }, () => cancelled);
                if (!context.mounted) return;
                result = taskResult;
                Navigator.of(dialogContext).pop();
              });
            }
            return ContentDialog(
              title: title,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: total > 0 ? current / total : null,
                  ),
                  const SizedBox(height: 16),
                  Text("$current / $total"),
                  if (currentTitle.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(currentTitle, overflow: TextOverflow.ellipsis),
                  ],
                ],
              ).paddingHorizontal(16),
              actions: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      cancelled = true;
                    });
                  },
                  child: Text("Cancel".tl),
                ),
              ],
            );
          },
        );
      },
    );
    if (mounted) {
      setState(() {
        isWorking = false;
      });
    }
    return result;
  }

  static String _formatTime(DateTime time) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${twoDigits(time.month)}-${twoDigits(time.day)} '
        '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
  }
}
