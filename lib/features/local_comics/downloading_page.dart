import 'package:flutter/material.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/image_provider/cached_image.dart';
import 'package:venera_next/features/local_comics/download_task.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

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
    final currentFirstTask = manager.downloadingTasks.firstOrNull;
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
    int speed = 0;
    if (manager.downloadingTasks.isNotEmpty) {
      speed = manager.downloadingTasks.first.speed;
    }
    var first = manager.downloadingTasks.firstOrNull;
    final resumePending = manager.isDownloadResumePending;
    return Container(
      height: 48,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Row(
        children: [
          if (first?.isPaused == true && !resumePending)
            Text("Paused".tl, style: ts.s18.bold)
          else if (first?.isError == true)
            Text("Error".tl, style: ts.s18.bold)
          else
            Text("${bytesToReadableString(speed)}/s", style: ts.s18.bold),
          const Spacer(),
          if (!resumePending &&
              (first?.isPaused == true || first?.isError == true))
            OutlinedButton(
              child: Row(
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
      ).paddingHorizontal(16),
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

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 136,
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
                        MenuEntry(
                          icon: Icons.close,
                          text: "Cancel".tl,
                          onClick: () {
                            widget.manager.cancelDownload(widget.task);
                          },
                        ),
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
                if (!widget.task.isPaused || widget.task.isError)
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
