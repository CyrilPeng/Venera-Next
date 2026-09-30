import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/reader/chapter_loader.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/reader/reader_controller.dart';

import 'gallery_view.dart';
import 'continuous_view.dart';

// Transitional exports for existing viewport consumers.
export 'gallery_view.dart' show GalleryModeState;
export 'continuous_view.dart' show ContinuousModeState;

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
        return ReaderGalleryView(
          key: Key(
            '${reader.mode.key}_${reader.imagesPerPage}_${showComments}_$showCommentsAtEnd',
          ),
        );
      } else {
        return ReaderContinuousView(
          key: Key(reader.mode.key),
          crossChapter: reader.mode.isWaterfall,
        );
      }
    }
  }
}
