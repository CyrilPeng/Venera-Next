import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'thumbnail_pages.dart';
import 'thumbnail_image.dart';
import 'package:flutter/material.dart';
import 'package:sliver_tools/sliver_tools.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/image.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart'
    show ComicThumbnailLoader;
import 'package:venera_next/foundation/consts.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/image_provider/cached_image.dart';
import 'package:venera_next/foundation/translations.dart';

class ComicThumbnails extends StatefulWidget {
  const ComicThumbnails({
    super.key,
    required this.comicId,
    required this.sourceKey,
    required this.initialThumbnails,
    required this.loadComicThumbnail,
    required this.readPage,
  });

  final String comicId;
  final String sourceKey;
  final List<String> initialThumbnails;
  final ComicThumbnailLoader? loadComicThumbnail;
  final void Function(int page) readPage;

  @override
  State<ComicThumbnails> createState() => _ComicThumbnailsState();
}

class _ComicThumbnailsState extends State<ComicThumbnails> {
  ComicThumbnailPages? _pages;
  ComicThumbnailPages? _scheduled;
  SelectionTaskRegistry? _registry;
  WindowFrameController? _window;
  List<String> _initial = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final registry = context
        .dependOnInheritedWidgetOfExactType<SelectionTasksScope>()
        ?.registry;
    final window = context
        .dependOnInheritedWidgetOfExactType<WindowFrameController>();
    if (_pages == null ||
        registry != _registry ||
        window?.addExitTask != _window?.addExitTask) {
      _window?.removeCloseFailureListener(_resume);
      _registry = registry;
      _window = window;
      _window?.addCloseFailureListener(_resume);
      _replacePages();
    }
  }

  @override
  void didUpdateWidget(covariant ComicThumbnails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.comicId != widget.comicId ||
        oldWidget.sourceKey != widget.sourceKey ||
        oldWidget.loadComicThumbnail != widget.loadComicThumbnail ||
        !listEquals(_initial, widget.initialThumbnails)) {
      _replacePages();
    }
  }

  void _resume() {
    scheduleMicrotask(() {
      if (mounted) {
        _scheduleLoad();
        WidgetsBinding.instance.scheduleFrame();
      }
    });
  }

  void _replacePages() {
    unawaited(_pages?.closeAndWait());
    final registry = _registry;
    final window = _window;
    _initial = List.of(widget.initialThumbnails);
    _pages = ComicThumbnailPages(
      comicId: widget.comicId,
      load: widget.loadComicThumbnail,
      initial: _initial,
      canLoad: () =>
          mounted && registry?.isClosing != true && window?.isClosing != true,
      retain: (scope, settled) {
        void cancel() => scope.cancel();
        Future<void> close() {
          cancel();
          return settled;
        }

        final release = registry?.retain(cancel: cancel, close: close);
        window?.addCloseStartListener(cancel);
        window?.addExitTask(close);
        window?.trackExitTask(settled);
        return () {
          window?.removeCloseStartListener(cancel);
          window?.removeExitTask(close);
          release?.call();
        };
      },
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
    _scheduleLoad();
  }

  void _scheduleLoad() {
    final pages = _pages!;
    if (!pages.hasMore ||
        pages.isLoading ||
        pages.failure != null ||
        identical(_scheduled, pages)) {
      return;
    }
    _scheduled = pages;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (identical(_scheduled, pages)) _scheduled = null;
      if (mounted && identical(_pages, pages)) unawaited(pages.loadNext());
    });
  }

  @override
  void dispose() {
    _window?.removeCloseFailureListener(_resume);
    unawaited(_pages?.closeAndWait());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = _pages!;
    final thumbnails = pages.items;
    final error = pages.failure?.errorMessage;
    return MultiSliver(
      children: [
        SliverToBoxAdapter(child: ListTile(title: Text("Preview".tl))),
        SliverGrid(
          delegate: SliverChildBuilderDelegate((context, index) {
            if (index == thumbnails.length - 1 && error == null) {
              _scheduleLoad();
            }
            final thumbnail = ThumbnailImage.parse(thumbnails[index]);
            final url = thumbnail.url;
            final crop = thumbnail.crop;
            final part = crop == null
                ? null
                : ImagePart(x1: crop.x1, x2: crop.x2, y1: crop.y1, y2: crop.y2);
            return Padding(
              padding: context.width < changePoint
                  ? const EdgeInsets.all(4)
                  : const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Expanded(
                    child: ClickInkWell(
                      onTap: () => widget.readPage(index + 1),
                      borderRadius: const BorderRadius.all(Radius.circular(8)),
                      child: Container(
                        foregroundDecoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        width: double.infinity,
                        height: double.infinity,
                        clipBehavior: Clip.antiAlias,
                        child: AnimatedImage(
                          image: CachedImageProvider(
                            url,
                            sourceKey: widget.sourceKey,
                          ),
                          fit: BoxFit.contain,
                          width: double.infinity,
                          height: double.infinity,
                          part: part,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text((index + 1).toString()),
                ],
              ),
            );
          }, childCount: thumbnails.length),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 200,
            childAspectRatio: 0.68,
          ),
        ),
        if (error != null)
          SliverToBoxAdapter(
            child: Column(
              children: [
                Text(error),
                Button.outlined(
                  onPressed: pages.loadNext,
                  child: Text("Retry".tl),
                ),
              ],
            ),
          )
        else if (pages.isLoading)
          const SliverListLoadingIndicator(),
        const SliverToBoxAdapter(child: Divider()),
      ],
    );
  }
}
