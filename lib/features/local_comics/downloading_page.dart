import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/image_provider/cached_image.dart';
import 'package:venera_next/features/local_comics/download_task.dart';
import 'package:venera_next/features/local_comics/images_download_task.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';
import 'package:venera_next/routing/local_reading.dart';

class DownloadingPage extends StatefulWidget {
  const DownloadingPage({super.key});

  @override
  State<DownloadingPage> createState() => _DownloadingPageState();
}

class _DownloadingPageState extends State<DownloadingPage> {
  DownloadTask? firstTask;

  late final LocalManager manager = LocalManager();

  @override
  void initState() {
    super.initState();
    manager.addListener(update);
    _syncFirstTask();
  }

  @override
  void dispose() {
    manager.removeListener(update);
    firstTask?.removeListener(update);
    super.dispose();
  }

  void _syncFirstTask() {
    final currentFirstTask = manager.currentDownloadingTask;
    if (!identical(currentFirstTask, firstTask)) {
      firstTask?.removeListener(update);
      firstTask = currentFirstTask;
      firstTask?.addListener(update);
    }
  }

  void update() {
    _syncFirstTask();
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "",
      body: ListView.builder(
        itemCount: manager.downloadingTasks.length + 1,
        itemBuilder: (BuildContext context, int i) {
          if (i == 0) {
            return buildTop();
          }
          i--;

          return _DownloadTaskTile(
            key: ValueKey(manager.downloadingTasks[i]),
            task: manager.downloadingTasks[i],
            manager: manager,
          );
        },
      ),
    );
  }

  Widget buildTop() {
    var first = manager.currentDownloadingTask;
    final speed = first?.speed ?? 0;
    final resumePending = manager.isDownloadResumePending;
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          if (first == null && manager.downloadingTasks.isNotEmpty)
            Text('Waiting for missing pages'.tl, style: ts.s18.bold)
          else if (first?.isError == true)
            Text("Error".tl, style: ts.s18.bold)
          else if (first?.isPaused == true && !resumePending)
            Text("Paused".tl, style: ts.s18.bold)
          else
            Text("${bytesToReadableString(speed)}/s", style: ts.s18.bold),
          if (!resumePending &&
              (first?.isPaused == true || first?.isError == true))
            OutlinedButton(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.play_arrow, size: 18),
                  const SizedBox(width: 4),
                  Text("Start".tl),
                ],
              ),
              onPressed: () {
                manager.resumeDownload(first!);
              },
            )
          else if (first != null)
            OutlinedButton(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.pause, size: 18),
                  const SizedBox(width: 4),
                  Text("Pause".tl),
                ],
              ),
              onPressed: () {
                manager.pauseDownload(first);
              },
            ),
        ],
      ),
    );
  }
}

class _DownloadTaskTile extends StatefulWidget {
  const _DownloadTaskTile({
    required this.task,
    required this.manager,
    super.key,
  });

  final DownloadTask task;
  final LocalManager manager;

  @override
  State<_DownloadTaskTile> createState() => _DownloadTaskTileState();
}

class _DownloadTaskTileState extends State<_DownloadTaskTile> {
  late DownloadTask task;

  @override
  void initState() {
    task = widget.task;
    task.addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    task.removeListener(update);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _DownloadTaskTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.task, widget.task)) {
      task.removeListener(update);
      task = widget.task;
      task.addListener(update);
    }
  }

  void update() {
    setState(() {});
  }

  void _showErrorDetails() {
    final message = widget.task.message;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          widget.task.isAwaitingMissingPages
              ? 'Missing page details'.tl
              : 'Download error'.tl,
        ),
        scrollable: true,
        content: SelectableText(message),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: message)),
            child: Text('Copy'.tl),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Close'.tl),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height:
          136 *
          (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
            1.0,
            double.infinity,
          ),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Row(
        children: [
          Container(
            width: 82,
            height: double.infinity,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: context.colorScheme.primaryContainer,
            ),
            clipBehavior: Clip.antiAlias,
            child: widget.task.cover == null
                ? null
                : Image(
                    image: CachedImageProvider(widget.task.cover!),
                    filterQuality: FilterQuality.medium,
                    fit: BoxFit.cover,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.task.title,
                        style: Theme.of(context).textTheme.bodyMedium,
                        maxLines: 2,
                      ),
                    ),
                    MenuButton(
                      entries: [
                        if (widget.task.isAwaitingMissingPages) ...[
                          MenuEntry(
                            icon: Icons.menu_book_outlined,
                            text: 'Read downloaded pages'.tl,
                            onClick: () {
                              final comic = widget.manager.find(
                                widget.task.id,
                                widget.task.comicType,
                              );
                              if (comic != null) openLocalComic(comic);
                            },
                          ),
                          MenuEntry(
                            icon: Icons.refresh,
                            text: 'Retry missing pages'.tl,
                            onClick: () =>
                                widget.manager.retryMissingPages(widget.task),
                          ),
                        ],
                        if (widget.task case ImagesDownloadTask imageTask)
                          MenuEntry(
                            icon: imageTask.skipUnavailableImages
                                ? Icons.check_box
                                : Icons.check_box_outline_blank,
                            text: 'Continue past unavailable images'.tl,
                            onClick: () async {
                              try {
                                await imageTask.updateSkipUnavailableImages(
                                  !imageTask.skipUnavailableImages,
                                );
                              } catch (error) {
                                if (context.mounted) {
                                  showDialog<void>(
                                    context: context,
                                    builder: (_) => AlertDialog(
                                      content: Text(error.toString()),
                                    ),
                                  );
                                }
                              }
                            },
                          ),
                        if (widget.task.isError ||
                            widget.task.isAwaitingMissingPages)
                          MenuEntry(
                            icon: Icons.error_outline,
                            text: widget.task.isAwaitingMissingPages
                                ? 'Missing page details'.tl
                                : 'Error details'.tl,
                            onClick: _showErrorDetails,
                          ),
                        MenuEntry(
                          icon: Icons.close,
                          text: widget.task.isAwaitingMissingPages
                              ? 'Remove task and keep local pages'.tl
                              : "Cancel".tl,
                          onClick: () {
                            widget.manager.cancelDownload(widget.task);
                          },
                        ),
                        if (!widget.task.isAwaitingMissingPages)
                          MenuEntry(
                            icon: Icons.vertical_align_top,
                            text: "Move To First".tl,
                            onClick: () {
                              widget.manager.moveToFirst(widget.task);
                            },
                          ),
                      ],
                    ),
                  ],
                ),
                const Spacer(),
                if (!widget.task.isPaused ||
                    widget.task.isError ||
                    widget.task.isAwaitingMissingPages)
                  Text(widget.task.message, style: ts.s12, maxLines: 3),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: widget.task.progress),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
