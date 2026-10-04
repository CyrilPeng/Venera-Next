import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:venera_next/components/loading.dart';
import 'images.dart';
import 'package:venera_next/features/reader/chapter_loader.dart';
import 'package:venera_next/features/reader/reader_page.dart';
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

/// Application composition for reader content, view inputs and shell actions.
class ReaderImagesHost extends StatelessWidget {
  const ReaderImagesHost({super.key, required this.reader});
  final ReaderState reader;

  Future<Uint8List?> _readImage(String key) async {
    if (key.startsWith('file://')) return File(key.substring(7)).readAsBytes();
    return (await CacheManager().findCache(
      '$key@${reader.type.sourceKey}@${reader.cid}@${reader.eid}',
    ))!.readAsBytes();
  }

  @override
  Widget build(BuildContext context) => ReaderImages(
    imageWork: reader.imageWork,
    controller: reader.controller,
    beforeLoad: (scope) =>
        reader.prepareLocalPageOrder(() => scope.isCancelled),
    loadImages: (scope) => loadReaderChapterImages(
      scope: scope,
      comicId: reader.cid,
      type: reader.type,
      chapter: reader.chapter,
      chapters: reader.widget.chapters,
      onOnlineFallback: reader.onLocalChapterRecoveredOnline,
    ),
    prepareMode: reader.prepareReadingMode,
    onLoading: reader.onReaderContentLoading,
    onCommitted: () {
      if (reader.jumpToLastPageOnLoad) {
        reader.controller.restorePage(reader.maxPage);
        reader.controller.setJumpToLastPage(false);
      }
    },
    onReady: () {
      reader.updateHistory();
      reader.onReaderContentReady();
    },
    onSettled: () {
      if (reader.controller.content.error != null ||
          reader.images?.isEmpty == true) {
        reader.autoReading.stop();
      }
      context.readerScaffold.update();
    },
    errorBuilder: (context, error, retry) => GestureDetector(
      onTap: () => context.readerScaffold.openOrClose(),
      child: SizedBox.expand(
        child: NetworkError(message: error, retry: retry),
      ),
    ),
    contentBuilder: _buildContent,
  );

  Widget _buildContent(BuildContext context, ReaderContentState content) {
    if (reader.mode.isGallery) {
      var showComments = reader.preferences.showChapterComments == true;
      var showCommentsAtEnd =
          reader.preferences.showChapterCommentsAtEnd == true;
      final preferences = reader.preferences;
      final source = reader.type.comicSource;
      final chapters = reader.widget.chapters;
      return ReaderGalleryView(
        imageWork: reader.imageWork,
        key: Key(
          '${reader.mode.key}_${reader.imagesPerPage}_${showComments}_$showCommentsAtEnd',
        ),
        data: ReaderGalleryData(
          content: content,
          layout: reader.pageLayout,
          vertical: reader.mode == ReaderMode.galleryTopToBottom,
          reverse: reader.mode == ReaderMode.galleryRightToLeft,
          commentsAtEnd: reader.totalPages > reader.maxPage,
          firstChapter: reader.isFirstChapterOfGroup,
          lastChapter: reader.isLastChapterOfGroup,
          preloadCount: appdata.settings.globalReaderSettings.preloadImageCount,
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
        onViewportChanged: reader.viewportBinding.update,
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
        imageWork: reader.imageWork,
        key: Key(reader.mode.key),
        data: ReaderContinuousData(
          vertical: reader.mode.isTopToBottom,
          reverse: reader.mode == ReaderMode.continuousRightToLeft,
          crossChapter: reader.mode.isWaterfall,
          firstChapter: reader.isFirstChapterOfGroup,
          lastChapter: reader.isLastChapterOfGroup,
          maxChapter: reader.maxChapter,
          preloadCount: appdata.settings.globalReaderSettings.preloadImageCount,
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
        onViewportChanged: reader.viewportBinding.update,
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
          Log.error('Reader', 'Failed to load chapter $chapter: $error', stack);
          context.showMessage(message: error.toString());
        },
        readerSize: () => reader.size,
        readImage: _readImage,
      );
    }
  }
}
