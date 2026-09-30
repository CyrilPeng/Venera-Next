import 'package:venera_next/features/reader/reader_viewport.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/reader/chapter_loader.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/reader/reader_controller.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/reader/chapter_comments.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';

import 'gallery_view.dart';
import 'gallery_data.dart';
import 'continuous_data.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';
import 'continuous_view.dart';

class ReaderImages extends StatefulWidget {
  const ReaderImages({super.key});

  @override
  State<ReaderImages> createState() => ReaderImagesState();
}

class ReaderImagesState extends State<ReaderImages> {
  late ReaderContentLoad _contentLoad;
  String? get error => reader.controller.content.error;

  late ReaderState reader;

  @override
  void initState() {
    reader = context.reader;
    reader.onReaderContentLoading();
    _contentLoad = reader.controller.beginContentLoad();
    super.initState();
  }

  @override
  void dispose() {
    reader.controller.cancelContentLoad(_contentLoad);
    super.dispose();
  }

  /// Handle jumping to last page when jumpToLastPageOnLoad is true
  void _handleJumpToLastPage() {
    if (reader.jumpToLastPageOnLoad) {
      reader.controller.restorePage(reader.maxPage);
      reader.controller.setJumpToLastPage(false);
    }
  }

  void load() async {
    final attempt = _contentLoad;
    if (!reader.controller.startContentLoad(attempt)) return;
    try {
      if (!reader.localPageOrderChecked && reader.type == ComicType.local) {
        final history = reader.history;
        if (history != null) {
          final previousPage = history.page;
          await LocalManager().migrateLegacyPageOrder(history);
          if (!mounted) return;
          if ((reader.widget.initialChapter ?? 1) == history.ep &&
              reader.widget.initialPage == previousPage) {
            final imagePage = history.page;
            reader.controller.restorePage(
              reader.pageLayout.pageForImage(imagePage),
            );
          }
        }
        reader.localPageOrderChecked = true;
      }
      final images = await loadReaderChapterImages(
        scope: attempt.scope,
        comicId: reader.cid,
        type: reader.type,
        chapter: reader.chapter,
        chapters: reader.widget.chapters,
        onOnlineFallback: reader.onLocalChapterRecoveredOnline,
      );
      if (!mounted) return;
      if (!reader.controller.setContentImages(attempt, images)) return;
      await reader.prepareReadingMode();
      if (!mounted || !reader.controller.completeContentLoad(attempt)) return;
      setState(() {
        _handleJumpToLastPage();
        Future.microtask(() {
          if (!mounted) return;
          reader.updateHistory();
          reader.onReaderContentReady();
        });
      });
    } catch (e) {
      if (!mounted || !reader.controller.failContentLoad(attempt, e)) return;
      setState(() {});
    }
    if (mounted) {
      if (error != null || reader.images?.isEmpty == true) {
        reader.autoReading.stop();
      }
      context.readerScaffold.update();
    }
  }

  void _onViewportChanged(ReaderImageViewController viewport, bool attached) {
    if (attached) {
      reader.imageViewController = viewport;
    } else if (identical(reader.imageViewController, viewport)) {
      reader.imageViewController = null;
    }
  }

  Future<Uint8List?> _readImage(String key) async {
    if (key.startsWith('file://')) return File(key.substring(7)).readAsBytes();
    return (await CacheManager().findCache(
      '$key@${reader.type.sourceKey}@${reader.cid}@${reader.eid}',
    ))!.readAsBytes();
  }

  @override
  Widget build(BuildContext context) {
    if (reader.isLoading) {
      load();
      return const Center(child: CircularProgressIndicator());
    } else if (error != null) {
      return GestureDetector(
        onTap: () {
          context.readerScaffold.openOrClose();
        },
        child: SizedBox.expand(
          child: NetworkError(
            message: error!,
            retry: () {
              setState(() {
                _contentLoad = reader.controller.beginContentLoad();
              });
            },
          ),
        ),
      );
    } else {
      if (reader.mode.isGallery) {
        var showComments = reader.preferences.showChapterComments == true;
        var showCommentsAtEnd =
            reader.preferences.showChapterCommentsAtEnd == true;
        final preferences = reader.preferences;
        final source = reader.type.comicSource;
        final chapters = reader.widget.chapters;
        return ReaderGalleryView(
          key: Key(
            '${reader.mode.key}_${reader.imagesPerPage}_${showComments}_$showCommentsAtEnd',
          ),
          data: ReaderGalleryData(
            content: reader.controller.content,
            layout: reader.pageLayout,
            vertical: reader.mode == ReaderMode.galleryTopToBottom,
            reverse: reader.mode == ReaderMode.galleryRightToLeft,
            commentsAtEnd: reader.totalPages > reader.maxPage,
            firstChapter: reader.isFirstChapterOfGroup,
            lastChapter: reader.isLastChapterOfGroup,
            preloadCount:
                appdata.settings.globalReaderSettings.preloadImageCount,
            doubleTapCollect:
                appdata.settings.globalReaderSettings.quickCollectImage ==
                'DoubleTap',
            centerLongPressZoom: preferences.longPressZoomPosition == 'center',
            pageAnimation: preferences.enablePageAnimation,
            sourceKey: source?.key,
            comicId: reader.cid,
            chapterId: reader.eid,
          ),
          navigation: reader.controller,
          onViewportChanged: _onViewportChanged,
          onReady: () => context.readerScaffold.setFloatingButton(0),
          onPageReported: (comments, refreshEInk) {
            final scaffold = context.readerScaffold;
            scaffold.update();
            if (comments && scaffold.isOpen) scaffold.openOrClose();
            if (refreshEInk) scaffold.requestEInkRefresh();
          },
          onChapterChanged: () => context.readerScaffold.requestEInkRefresh(),
          onCollectImage: () => context.readerScaffold.addImageFavorite(),
          readerSize: () => reader.size,
          readImage: _readImage,
          commentsBuilder: source == null || chapters == null
              ? null
              : (_) => EmbeddedChapterCommentsPage(
                  comicId: reader.cid,
                  epId: chapters.ids.elementAt(reader.chapter - 1),
                  source: source,
                  comicTitle: reader.widget.name,
                  chapterTitle: chapters.titles.elementAt(reader.chapter - 1),
                ),
        );
      } else {
        final preferences = reader.preferences;
        return ReaderContinuousView(
          key: Key(reader.mode.key),
          data: ReaderContinuousData(
            vertical: reader.mode.isTopToBottom,
            reverse: reader.mode == ReaderMode.continuousRightToLeft,
            crossChapter: reader.mode.isWaterfall,
            firstChapter: reader.isFirstChapterOfGroup,
            lastChapter: reader.isLastChapterOfGroup,
            maxChapter: reader.maxChapter,
            preloadCount:
                appdata.settings.globalReaderSettings.preloadImageCount,
            splitWideImages: preferences.splitDualPage == true,
            invertSplit: preferences.splitDualPageInvert == true,
            scrollSpeed: preferences.readerScrollSpeed,
            limitImageWidth: preferences.limitImageWidth == true,
            sideMargin: preferences.readerSideMargin,
            doubleTapCollect:
                appdata.settings.globalReaderSettings.quickCollectImage ==
                'DoubleTap',
            centerLongPressZoom: preferences.longPressZoomPosition == 'center',
            sourceKey: reader.type.comicSource?.key,
            comicId: reader.cid,
          ),
          navigation: reader.controller,
          loadChapter: (chapter, scope) => loadReaderChapterImages(
            scope: scope,
            comicId: reader.cid,
            type: reader.type,
            chapter: chapter,
            chapters: reader.widget.chapters,
            onOnlineFallback: reader.onLocalChapterRecoveredOnline,
          ),
          chapterId: (chapter) =>
              reader.widget.chapters?.ids.elementAtOrNull(chapter - 1) ?? '0',
          chapterTitle: (chapter) =>
              reader.widget.chapters?.titles.elementAtOrNull(chapter - 1) ??
              '${'Chapter'.tl} $chapter',
          onViewportChanged: _onViewportChanged,
          onUpdate: () => context.readerScaffold.update(),
          onFloatingButton: (value) =>
              context.readerScaffold.setFloatingButton(value),
          onCollectImage: () => context.readerScaffold.addImageFavorite(),
          onActiveChapterChanged: () => reader.detectLayout(),
          onContentLoading: (loading) {
            if (loading) {
              reader.onReaderContentLoading();
            } else {
              reader.onReaderContentReady();
            }
          },
          onPreviousError: (error, stack) => Log.error(
            'Reader',
            'Failed to load previous chapter: $error',
            stack,
          ),
          onNavigationError: (chapter, error, stack) {
            Log.error(
              'Reader',
              'Failed to load chapter $chapter: $error',
              stack,
            );
            context.showMessage(message: error.toString());
          },
          readerSize: () => reader.size,
          readImage: _readImage,
        );
      }
    }
  }
}
