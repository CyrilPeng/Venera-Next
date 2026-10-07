import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_memory_info/flutter_memory_info.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/reader/gesture_host.dart';
import 'package:venera_next/features/reader/gesture_request.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/images_host.dart';
import 'package:venera_next/features/reader/image_cache_policy.dart';
import 'package:venera_next/features/reader/layout_detection.dart';
import 'package:venera_next/features/reader/reader_mode_labels.dart';
import 'package:venera_next/features/reader/reading_session.dart';
import 'package:venera_next/features/reader/reader_session.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/features/reader/history_writer.dart';
import 'package:venera_next/features/reader/exit_guard.dart';
import 'package:venera_next/features/reader/reader_controller.dart';
import 'package:venera_next/features/reader/reader_viewport.dart';
import 'package:venera_next/features/reader/page_order_migration.dart';
import 'package:venera_next/features/reader/chapter_menu.dart';
import 'chapter_loader.dart';
import 'chapter_request.dart';
import 'package:venera_next/features/reader/image_favorite_controller.dart';
import 'package:venera_next/features/reader/image_export.dart';
import 'package:venera_next/features/reader/settings_effects.dart';
import 'package:venera_next/features/reader/comments_controller.dart';
import 'package:venera_next/features/reader/chapter_navigation.dart';

import 'package:venera_next/features/reader/page_layout.dart';
import 'package:venera_next/features/reader/history_progress.dart';
import 'package:venera_next/features/reader/scaffold.dart';
import 'shell_host.dart';
import 'progress_navigation.dart';
import 'image_picker.dart';
import 'package:venera_next/features/reader/volume.dart';
import 'package:venera_next/features/reader/volume_controller.dart';
import 'package:venera_next/features/reader/window_controller.dart';
import 'package:venera_next/features/reader/platform_effects.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/reader_settings.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/comic_layout.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:window_manager/window_manager.dart';

extension ReaderContext on BuildContext {
  ReaderState get reader => findAncestorStateOfType<ReaderState>()!;

  ReaderScaffoldState get readerScaffold =>
      findAncestorStateOfType<ReaderScaffoldState>()!;
}

/// Value identity for captured progress and gesture targets, including mutable chapter maps.
class _ReaderInputTarget {
  const _ReaderInputTarget(this.key, this.ids, this.titles);
  final Object key;
  final List<String>? ids, titles;

  @override
  bool operator ==(Object other) =>
      other is _ReaderInputTarget &&
      other.key == key &&
      listEquals(ids, other.ids) &&
      listEquals(titles, other.titles);

  @override
  int get hashCode => Object.hash(
    key,
    Object.hashAll(ids ?? const []),
    Object.hashAll(titles ?? const []),
  );
}

class Reader extends StatefulWidget {
  const Reader({
    super.key,
    required this.type,
    required this.cid,
    required this.name,
    required this.chapters,
    required this.history,
    required this.onClosed,
    this.initialPage,
    this.initialChapter,
    this.initialChapterGroup,
    required this.author,
    required this.tags,
  });

  final ComicType type;

  final String author;

  final List<String> tags;

  final String cid;

  final String name;

  final ComicChapters? chapters;

  /// Starts from 1, invalid values equal to 1
  final int? initialPage;

  /// Starts from 1, invalid values equal to 1
  final int? initialChapter;

  /// Starts from 1, invalid values equal to 1
  final int? initialChapterGroup;

  final History history;

  final VoidCallback onClosed;

  @override
  State<Reader> createState() => ReaderState();
}

class ReaderState extends State<Reader>
    with ReaderImagePerPageHandler, WidgetsBindingObserver {
  final imageWork = ImageWork();
  late final imageFavorites = ImageFavoriteManager();
  final _targetValidity = ValueNotifier(0);
  final _shellChanges = ValueNotifier(0);
  Listenable get shellChanges => _shellChanges;

  void updateShell() {
    if (!_stateDisposed && mounted) _shellChanges.value++;
  }

  void onViewportChanged(ReaderImageViewController viewport, bool attached) {
    viewportBinding.update(viewport, attached);
    // Attachment happens while building content. Refresh input after the tree
    // has installed the viewport, without rebuilding that content subtree.
    WidgetsBinding.instance.addPostFrameCallback((_) => updateShell());
  }

  ReaderImagePickContext? readImagePickContext() {
    if (!mounted || _stateDisposed || _sessionFrozen || _session.isHeld) {
      return null;
    }
    final viewport = imageViewController;
    final currentImages = images;
    if (viewport == null || currentImages == null) return null;
    return ReaderImagePickContext(
      viewport: viewport,
      images: currentImages,
      chapter: chapter,
    );
  }

  bool toggleAutomaticReading() {
    if (!mounted || _stateDisposed || _sessionFrozen || _session.isHeld) {
      return false;
    }
    autoReading.toggle();
    return autoReading.isActive;
  }

  VoidCallback acquireAutomaticReadingPause() {
    if (!mounted || _stateDisposed || _sessionFrozen) return () {};
    final original = autoReading;
    final reason = Object();
    original.pause(reason, true);
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (!_stateDisposed) original.pause(reason, false);
    };
  }

  ReaderProgressRequest createProgressRequest() {
    final content = controller.content;
    final route = ModalRoute.of(context);
    final viewport = imageViewController;
    final comic = cid, comicType = type, ep = chapter, currentMode = mode;
    final chapters = widget.chapters;
    final ids = chapters?.ids.toList(growable: false);
    final titles = chapters?.titles.toList(growable: false);
    final source = ComicSource.find(comicType.sourceKey);
    final layout = pageLayout;
    final count = maxPage;
    return ReaderProgressRequest(
      identity: _ReaderInputTarget(
        (
          content,
          viewport,
          comic,
          comicType,
          source,
          chapters,
          ep,
          currentMode,
          count,
          layout.imagesPerPage,
          layout.singleImageOnFirstPage,
        ),
        ids,
        titles,
      ),
      page: page,
      maxPage: count,
      chapter: ep,
      maxChapter: maxChapter,
      reversed:
          currentMode == ReaderMode.galleryRightToLeft ||
          currentMode == ReaderMode.continuousRightToLeft,
      isCurrent: () =>
          mounted &&
          !_stateDisposed &&
          !_sessionFrozen &&
          !_session.isHeld &&
          (route?.isCurrent ?? true) &&
          !controller.isDisposed &&
          identical(controller.content, content) &&
          !content.isLoading &&
          viewport != null &&
          identical(imageViewController, viewport) &&
          cid == comic &&
          type == comicType &&
          chapter == ep &&
          mode == currentMode &&
          maxPage == count &&
          pageLayout.imagesPerPage == layout.imagesPerPage &&
          pageLayout.singleImageOnFirstPage == layout.singleImageOnFirstPage &&
          identical(widget.chapters, chapters) &&
          identical(ComicSource.find(comicType.sourceKey), source) &&
          listEquals(chapters?.ids.toList(growable: false), ids) &&
          listEquals(chapters?.titles.toList(growable: false), titles),
      toPage: toPage,
      toChapter: toChapter,
    );
  }

  ReaderGestureRequest? createGestureRequest() {
    if (!mounted || _stateDisposed || _sessionFrozen || _session.isHeld) {
      return null;
    }
    final content = controller.content, viewport = imageViewController;
    final viewportSize = size;
    final route = ModalRoute.of(context);
    final comic = cid,
        comicType = type,
        ep = chapter,
        imagePage = page,
        currentMode = mode;
    final source = ComicSource.find(comicType.sourceKey);
    final sources = ComicSourceManager.current;
    final chapters = widget.chapters;
    final ids = chapters?.ids.toList(growable: false);
    final titles = chapters?.titles.toList(growable: false);
    final settings = preferences;
    final layout = pageLayout;
    bool targetCurrent() =>
        mounted &&
        !_stateDisposed &&
        !_sessionFrozen &&
        !_session.isHeld &&
        !controller.isDisposed &&
        identical(controller.content, content) &&
        identical(imageViewController, viewport) &&
        cid == comic &&
        type == comicType &&
        chapter == ep &&
        page == imagePage &&
        size == viewportSize &&
        mode == currentMode &&
        identical(ComicSource.find(comicType.sourceKey), source) &&
        (sources == null || identical(ComicSourceManager.current, sources)) &&
        identical(widget.chapters, chapters) &&
        listEquals(chapters?.ids.toList(growable: false), ids) &&
        listEquals(chapters?.titles.toList(growable: false), titles) &&
        pageLayout.imagesPerPage == layout.imagesPerPage &&
        pageLayout.singleImageOnFirstPage == layout.singleImageOnFirstPage &&
        preferences.enableDoubleTapToZoom == settings.enableDoubleTapToZoom &&
        preferences.enableTapToTurnPages == settings.enableTapToTurnPages &&
        preferences.reverseTapToTurnPages == settings.reverseTapToTurnPages &&
        preferences.longPressAction == settings.longPressAction;
    bool current() => targetCurrent() && (route?.isCurrent ?? true);
    void turn(bool forward) {
      if (current() && viewport != null && !content.isLoading) {
        toPage(imagePage + (forward ? 1 : -1));
      }
    }

    return ReaderGestureRequest(
      identity: _ReaderInputTarget(
        (
          content,
          viewport,
          source,
          comic,
          comicType,
          ep,
          imagePage,
          viewportSize,
          currentMode,
          layout.imagesPerPage,
          layout.singleImageOnFirstPage,
          settings.enableDoubleTapToZoom,
          settings.enableTapToTurnPages,
          settings.reverseTapToTurnPages,
          settings.longPressAction,
        ),
        ids,
        titles,
      ),
      isCurrent: current,
      isTargetCurrent: targetCurrent,
      targetChanges: Listenable.merge([sources, _targetValidity]),
      viewport: viewport,
      preferences: settings,
      vertical: currentMode.isTopToBottom,
      reversed:
          currentMode == ReaderMode.galleryRightToLeft ||
          currentMode == ReaderMode.continuousRightToLeft,
      onCommentsPage: isOnChapterCommentsPage,
      canUseImage: !content.isLoading && viewport != null,
      turnPage: turn,
      turnWheel: (forward) {
        if (!current() ||
            viewport == null ||
            content.isLoading ||
            !currentMode.isGallery) {
          return;
        }
        if (!toPage(imagePage + (forward ? 1 : -1)) && current()) {
          if (forward && !isLastChapterOfGroup) toNextChapter();
          if (!forward && !isFirstChapterOfGroup) {
            toPrevChapter(toLastPage: true);
          }
        }
      },
      toggleAutomaticReading: () {
        if (current()) toggleAutomaticReading();
      },
      stopAutomaticReading: () {
        if (current()) autoReading.stop();
      },
      acquirePause: () => current() ? acquireAutomaticReadingPause() : () {},
      fullscreen: () {
        if (current()) fullscreen();
      },
      exit: () => current() ? requestExit() : Future.value(),
    );
  }

  VoidCallback _observeCommentsValidity(
    VoidCallback listener,
    ComicSourceManager? sources,
    bool Function() isCurrent,
  ) {
    if (_stateDisposed || _sessionFrozen) return () {};
    _targetValidity.addListener(listener);
    void sourceChanged() {
      if (mounted && !_stateDisposed && !isCurrent()) update();
    }

    sources?.addListener(sourceChanged);
    return () {
      _targetValidity.removeListener(listener);
      sources?.removeListener(sourceChanged);
    };
  }

  @override
  void didUpdateWidget(covariant Reader oldWidget) {
    super.didUpdateWidget(oldWidget);
    _targetValidity.value++;
  }

  ReaderChapterCommentsRequest? createChapterCommentsRequest() {
    if (_sessionFrozen ||
        controller.isDisposed ||
        !preferences.showChapterComments) {
      return null;
    }
    final chapters = widget.chapters;
    if (chapters == null) return null;
    final comic = cid, comicType = type, ep = chapter, chapterId = eid;
    final sourceKey = comicType.sourceKey;
    final source = ComicSource.find(sourceKey);
    final load = source?.chapterCommentsLoader;
    if (source == null || load == null || ep < 1 || ep > chapters.length) {
      return null;
    }
    final ids = chapters.ids.toList(growable: false);
    final titles = chapters.titles.toList(growable: false);
    final send = source.sendChapterCommentFunc,
        like = source.likeCommentFunc,
        vote = source.voteCommentFunc;
    final sources = ComicSourceManager.current;
    final comicTitle = widget.name;
    bool current() =>
        mounted &&
        !_stateDisposed &&
        !_sessionFrozen &&
        !controller.isDisposed &&
        preferences.showChapterComments &&
        cid == comic &&
        type == comicType &&
        chapter == ep &&
        eid == chapterId &&
        widget.name == comicTitle &&
        identical(widget.chapters, chapters) &&
        identical(ComicSource.find(sourceKey), source) &&
        (sources == null || identical(ComicSourceManager.current, sources)) &&
        listEquals(chapters.ids.toList(growable: false), ids) &&
        listEquals(chapters.titles.toList(growable: false), titles);
    return ReaderChapterCommentsRequest(
      identity: (
        this,
        source,
        comic,
        chapterId,
        ep,
        widget.name,
        titles[ep - 1],
      ),
      sourceKey: sourceKey,
      comicTitle: widget.name,
      chapterTitle: titles[ep - 1],
      isCurrent: current,
      observeValidity: (listener) => current()
          ? _observeCommentsValidity(listener, sources, current)
          : () {},
      load: (page, reply) => load(comic, chapterId, page, reply),
      send: send == null
          ? null
          : (text, reply) => send(comic, chapterId, text, reply),
      like: like == null
          ? null
          : (id, liked) => like(comic, chapterId, id, liked),
      vote: vote == null
          ? null
          : (id, up, cancel) => vote(comic, chapterId, id, up, cancel),
    );
  }

  ReaderSettingsRequest? createSettingsRequest() {
    if (_sessionFrozen || controller.isDisposed) return null;
    final comic = cid, comicType = type;
    final sourceKey = comicType.sourceKey;
    final source = ComicSource.find(sourceKey);
    return ReaderSettingsRequest(
      comicId: comic,
      sourceKey: sourceKey,
      isCurrent: () =>
          mounted &&
          !_sessionFrozen &&
          !controller.isDisposed &&
          cid == comic &&
          type == comicType &&
          identical(ComicSource.find(sourceKey), source),
      currentMode: () => mode.key,
      isDetectingLayout: () => isDetectingLayout,
      detectLayout: () => detectLayout(force: true),
      applyReaderEffect: (effect) {
        switch (effect) {
          case ReaderSettingEffect.applyMode:
            applyReadingMode(ReaderMode.fromKey(preferences.readerMode));
          case ReaderSettingEffect.detectLayout:
            unawaited(detectLayout());
          case ReaderSettingEffect.updateVolumeListener:
            if (preferences.enableTurnPageByVolumeKey) {
              handleVolumeEvent();
            } else {
              stopVolumeEvent();
            }
          case ReaderSettingEffect.rebuildReader:
            update();
          default:
            throw ArgumentError.value(effect, 'effect', 'Not a reader effect');
        }
      },
    );
  }

  ReaderImageExportRequest? createImageExportRequest() {
    final content = controller.content;
    final originalImages = content.images;
    if (_sessionFrozen ||
        content.isLoading ||
        originalImages == null ||
        originalImages.isEmpty ||
        isOnChapterCommentsPage) {
      return null;
    }
    final snapshot = List<String>.unmodifiable(originalImages);
    final comic = cid, comicType = type, chapterId = eid, ep = chapter;
    final sourceKey = comicType.sourceKey;
    final source = ComicSource.find(sourceKey);
    final chapters = widget.chapters;
    final ids = chapters?.ids.toList(growable: false);
    final titles = chapters?.titles.toList(growable: false);
    return ReaderImageExportRequest(
      images: snapshot,
      sourceKey: sourceKey,
      comicId: comic,
      chapterId: chapterId,
      title: widget.name,
      chapter: ep,
      isCurrent: () =>
          mounted &&
          !_sessionFrozen &&
          !controller.isDisposed &&
          identical(controller.content, content) &&
          cid == comic &&
          type == comicType &&
          chapter == ep &&
          eid == chapterId &&
          identical(widget.chapters, chapters) &&
          listEquals(chapters?.ids.toList(growable: false), ids) &&
          listEquals(chapters?.titles.toList(growable: false), titles) &&
          listEquals(images, snapshot) &&
          identical(ComicSource.find(sourceKey), source),
    );
  }

  ReaderImageFavoriteQuery? createImageFavoriteQuery() {
    final currentImages = images;
    if (_sessionFrozen ||
        currentImages == null ||
        currentImages.isEmpty ||
        isOnChapterCommentsPage) {
      return null;
    }
    final access = imageFavorites.capture();
    final comic = cid, comicType = type, chapterId = eid, imagePage = page;
    final layout = pageLayout;
    final currentMode = mode;
    final range = layout.imageRange(imagePage, currentImages.length);
    final sourcePage = range.$2 - range.$1 == 1 ? range.$1 + 1 : null;
    final source = ComicSource.find(comicType.sourceKey);
    return ReaderImageFavoriteQuery(
      key: (
        access.identity,
        comic,
        comicType,
        source,
        chapterId,
        imagePage,
        currentImages,
        currentMode,
        range,
      ),
      isCurrent: () =>
          mounted &&
          !_sessionFrozen &&
          access.isCurrent &&
          cid == comic &&
          type == comicType &&
          eid == chapterId &&
          page == imagePage &&
          mode == currentMode &&
          pageLayout.imagesPerPage == layout.imagesPerPage &&
          pageLayout.singleImageOnFirstPage == layout.singleImageOnFirstPage &&
          identical(images, currentImages) &&
          identical(ComicSource.find(comicType.sourceKey), source),
      read: () => sourcePage == null
          ? Future.value()
          : access.isCollected(
              comic,
              comicType.sourceKey,
              chapterId,
              sourcePage,
            ),
    );
  }

  ReaderImageFavoriteRequest? createImageFavoriteRequest() {
    final originalImages = images;
    if (_sessionFrozen || originalImages == null || originalImages.isEmpty) {
      return null;
    }
    final access = imageFavorites.capture();
    final comic = cid, comicType = type, chapterId = eid, ep = chapter;
    final source = ComicSource.find(comicType.sourceKey);
    final snapshot = List<String>.unmodifiable(originalImages);
    final title = history?.title ?? widget.name,
        subtitle = history?.subtitle ?? '';
    final author = widget.author;
    final tags = List<String>.unmodifiable(widget.tags);
    final translatedTags = tags
        .map((tag) => tag.translateTagsToCN)
        .toList(growable: false);
    final epName = widget.chapters?.titles.elementAtOrNull(ep - 1) ?? 'E$ep';
    bool current() =>
        mounted &&
        !_sessionFrozen &&
        access.isCurrent &&
        cid == comic &&
        type == comicType &&
        eid == chapterId &&
        chapter == ep &&
        identical(images, originalImages) &&
        listEquals(images, snapshot) &&
        identical(ComicSource.find(comicType.sourceKey), source);
    return ReaderImageFavoriteRequest(
      supported: !snapshot.first.startsWith('file://'),
      isCurrent: current,
      toggle: (index, checkActive) {
        checkActive();
        if (!current() || index < 0 || index >= snapshot.length) {
          throw const ImageWorkTaskCancelled();
        }
        return access.toggle(
          ImageFavoriteInput(
            id: comic,
            sourceKey: comicType.sourceKey,
            eid: chapterId,
            ep: ep,
            epName: epName,
            title: title,
            subtitle: subtitle,
            author: author,
            tags: tags,
            translatedTags: translatedTags,
            maxPage: snapshot.length,
            page: index + 1,
            imageKey: snapshot[index],
            coverKey: snapshot.first,
          ),
          checkActive: checkActive,
        );
      },
    );
  }

  late final chapterNavigation = ReaderChapterNavigationController(
    onChanged: update,
  );

  ReaderChapterNavigationRequest? createChapterNavigationRequest(
    ReaderContentState content,
  ) {
    final chapters = widget.chapters;
    if (chapters == null || _sessionFrozen || controller.isDisposed) {
      return null;
    }
    final comic = cid, comicType = type, ep = chapter, currentMode = mode;
    final sourceKey = comicType.sourceKey;
    final source = ComicSource.find(sourceKey);
    final ids = chapters.ids.toList(growable: false);
    final titles = chapters.titles.toList(growable: false);
    final supported = !currentMode.isGallery && !currentMode.isWaterfall;
    return ReaderChapterNavigationRequest(
      identity: (
        this,
        content,
        chapters,
        source,
        comic,
        comicType,
        ep,
        currentMode,
      ),
      isCurrent: () =>
          mounted &&
          !_stateDisposed &&
          !_sessionFrozen &&
          !_session.isHeld &&
          !controller.isDisposed &&
          identical(controller.content, content) &&
          !content.isLoading &&
          cid == comic &&
          type == comicType &&
          chapter == ep &&
          mode == currentMode &&
          type.sourceKey == sourceKey &&
          identical(widget.chapters, chapters) &&
          identical(ComicSource.find(sourceKey), source) &&
          listEquals(chapters.ids.toList(growable: false), ids) &&
          listEquals(chapters.titles.toList(growable: false), titles),
      canPrevious: supported && !isFirstChapterOfGroup,
      canNext: supported && !isLastChapterOfGroup,
      reversed: currentMode == ReaderMode.continuousRightToLeft,
      select: (direction) => controller.toChapter(ep + direction),
    );
  }

  ReaderChapterRequest createChapterRequest() {
    final comic = cid, comicType = type, chapters = widget.chapters;
    final source = comicType == ComicType.local
        ? null
        : ComicSource.find(comicType.sourceKey);
    final sources = comicType == ComicType.local
        ? null
        : ComicSourceManager.current;
    final local = LocalManager();
    final ids = chapters?.ids.toList(growable: false);
    final titles = chapters?.titles.toList(growable: false);
    final route = ModalRoute.of(context);
    bool current() =>
        mounted &&
        !_stateDisposed &&
        !_sessionFrozen &&
        !controller.isDisposed &&
        cid == comic &&
        type == comicType &&
        identical(widget.chapters, chapters) &&
        identical(LocalManager(), local) &&
        (comicType == ComicType.local ||
            (identical(ComicSource.find(comicType.sourceKey), source) &&
                identical(ComicSourceManager.current, sources))) &&
        listEquals(chapters?.ids.toList(growable: false), ids);
    return ReaderChapterRequest(
      identity: _ReaderInputTarget(
        (this, comic, comicType, chapters, source, sources, local),
        ids,
        null,
      ),
      chapters: chapters,
      isCurrent: current,
      canInteract: () =>
          current() &&
          !_session.isHeld &&
          (route?.isCurrent ?? true) &&
          listEquals(chapters?.titles.toList(growable: false), titles),
      load: (chapter, snapshot, scope) => loadReaderChapterImages(
        comicId: comic,
        type: comicType,
        chapter: chapter,
        chapters: snapshot,
        scope: scope,
        onOnlineFallback: () {
          if (current()) onLocalChapterRecoveredOnline();
        },
      ),
    );
  }

  late final controller = ReaderController(
    pageCount: () => totalPages,
    chapterCount: () => maxChapter,
    animationEnabled: () => preferences.enablePageAnimation,
    viewport: () => imageViewController,
    onChanged: update,
    onPageChanged: onPageChanged,
    onError: (error, stack) =>
        Log.error('Reader', 'Page navigation failed: $error', stack),
  );

  @override
  int get page => controller.state.page;
  @override
  set page(int value) => controller.setPage(value);
  int get chapter => controller.state.chapter;
  bool get jumpToLastPageOnLoad => controller.state.jumpToLastPageOnLoad;

  final viewportBinding = ReaderViewportBinding();
  ReaderImageViewController? get imageViewController => viewportBinding.current;

  void setPage(int page) => controller.reportPage(page);
  void resetPageAnimation() => controller.resetAnimation();
  bool get isPageAnimating => controller.state.isAnimating;
  bool toPage(int page, {bool animated = true}) =>
      controller.toPage(page, animated: animated);
  bool toNextPage() => toPage(page + 1);
  bool toPrevPage() => toPage(page - 1);
  bool toChapter(int chapter, {bool toLastPage = false}) =>
      controller.toChapter(chapter, toLastPage: toLastPage);
  bool toNextChapter() => toChapter(chapter + 1);
  bool toPrevChapter({bool toLastPage = false}) =>
      toChapter(chapter - 1, toLastPage: toLastPage);

  ReaderChapterMenuRequest? createChapterMenu() {
    final chapters = widget.chapters;
    if (chapters == null || _sessionFrozen || controller.isDisposed) {
      return null;
    }
    final comic = cid, comicType = type;
    final source = ComicSource.find(comicType.sourceKey);
    final data = ReaderChapterMenuData(
      chapters,
      currentChapter: chapter,
      downloaded:
          LocalManager().find(comic, comicType)?.downloadedChapters ?? const [],
    );
    return ReaderChapterMenuRequest(
      data: data,
      isCurrent: () =>
          mounted &&
          !_sessionFrozen &&
          !controller.isDisposed &&
          cid == comic &&
          type == comicType &&
          identical(widget.chapters, chapters) &&
          identical(ComicSource.find(comicType.sourceKey), source) &&
          data.matches(chapters),
      select: toChapter,
    );
  }

  void update() {
    if (!_stateDisposed) _targetValidity.value++;
    if (_sessionClosing != null || _sessionFrozen) return;
    _cancelOutdatedLayout();
    if (mounted) setState(() {});
  }

  /// The maximum page number for images only (excluding chapter comments page).
  /// This is used for display purposes and history recording.
  int get maxPage => pageLayout.pageCount(images?.length);

  /// Total pages including chapter comments page (used for internal page control).
  int get totalPages {
    var pages = maxPage;
    if (_shouldShowChapterCommentsAtEnd) pages++;
    return pages;
  }

  /// Whether the current page is the chapter comments page.
  bool get isOnChapterCommentsPage {
    return _shouldShowChapterCommentsAtEnd && page > maxPage;
  }

  bool get _shouldShowChapterCommentsAtEnd {
    if (mode != ReaderMode.galleryLeftToRight &&
        mode != ReaderMode.galleryRightToLeft) {
      return false;
    }
    if (widget.chapters == null) return false;
    var source = ComicSource.find(type.sourceKey);
    if (source?.chapterCommentsLoader == null) return false;
    return appdata.settings
                .readerSettings(cid, type.sourceKey)
                .showChapterComments ==
            true &&
        appdata.settings
                .readerSettings(cid, type.sourceKey)
                .showChapterCommentsAtEnd ==
            true;
  }

  @override
  ComicType get type => widget.type;

  @override
  String get cid => widget.cid;

  String get eid => widget.chapters?.ids.elementAtOrNull(chapter - 1) ?? '0';

  @override
  List<String>? get images => controller.content.images;

  @override
  late ReaderMode mode;

  @override
  bool get isPortrait =>
      MediaQuery.of(context).orientation == Orientation.portrait;

  History? history;

  late final _pageOrderMigration = ReaderPageOrderMigration(
    migrate: () async {
      final saved = history;
      if (saved == null) return null;
      final previousPage = saved.page;
      final savedChapter = saved.ep;
      await LocalManager().migrateLegacyPageOrder(saved);
      return MigratedReaderPosition(
        chapter: savedChapter,
        previousPage: previousPage,
        imagePage: saved.page,
      );
    },
    initialChapter: widget.initialChapter ?? 1,
    initialPage: widget.initialPage,
    currentChapter: () => chapter,
    displayPage: (imagePage) => pageLayout.pageForImage(imagePage),
    restorePage: controller.restorePage,
  );

  Future<void> prepareLocalPageOrder(bool Function() isCancelled) async {
    if (type != ComicType.local) return;
    await _pageOrderMigration.prepare(
      isCancelled: () => !mounted || isCancelled(),
    );
  }

  bool _reportedMissingLocalFiles = false;

  void onLocalChapterRecoveredOnline() {
    if (!mounted || _reportedMissingLocalFiles) return;
    _reportedMissingLocalFiles = true;
    showToast(
      context: context,
      message:
          'Local chapter files are unavailable. Reading online instead.'.tl,
    );
  }

  late final ReaderSession _session;
  SelectionTaskRegistry? _sessionRegistry;
  void Function()? _releaseSessionHost;
  Future<void>? _sessionClosing;
  bool _sessionFrozen = false;
  bool _stateDisposed = false;

  void _freezeSession() {
    if (_sessionFrozen) return;
    _sessionFrozen = true;
    _targetValidity.value++;
    chapterNavigation.dispose();
    _beginCloseVolume();
    _platformEffects?.dispose();
    disposeReaderWindow();
    controller.dispose();
    autoReading.pause('session closed', true);
    autoReading.stop();
    _layoutAttempt?.task.cancel();
    // A host can close from inside a child's callback or dependency rebuild.
    // Admission freezes now; the visual update waits until that build ends.
    scheduleMicrotask(() {
      if (mounted && !_stateDisposed) setState(() {});
    });
  }

  Future<void> _closeSession() {
    if (_sessionClosing case final closing?) return closing;
    _freezeSession();
    final closing = _sessionClosing = _session.dispose();
    _exitFrame?.removeCloseStartListener(_holdWindowSession);
    _exitFrame?.removeCloseFailureListener(_resumeWindowSession);
    _exitFrame?.removeExitTask(_prepareWindowSession);
    _exitFrame?.trackExitTask(closing);
    _resumeWindowSession();
    unawaited(
      closing.then<void>(
        (_) {
          _releaseSessionHost?.call();
          _releaseSessionHost = null;
        },
        onError: (Object error, StackTrace stack) {
          Log.error('Reader', 'Failed to close reading session: $error', stack);
        },
      ),
    );
    return closing;
  }

  void _bindSessionOwner() {
    _bindVolumeOwner();
    final registry = _sessionRegistry;
    if (registry != null) {
      // Every shared image/settings task keeps independent error evidence even
      // after a reversible page drain has already reported the failure.
      imageWork.retainTasks(
        (task) =>
            registry.retain(cancel: task.cancel, close: task.closeAndWait),
      );
      _releaseSessionHost = registry.retain(
        cancel: () {
          unawaited(_closeSession());
        },
        close: _closeSession,
      );
    }
    final frame = _exitFrame;
    if (_sessionFrozen || frame == null) return;
    frame.addCloseStartListener(_holdWindowSession);
    frame.addCloseFailureListener(_resumeWindowSession);
    frame.addExitTask(_prepareWindowSession);
    if (frame.isClosing) {
      _holdWindowSession();
      frame.trackExitTask(_prepareWindowSession());
    }
  }

  bool _hasPresentedImages = false;
  _ReaderLayoutAttempt? _layoutAttempt;
  final _sampledChapters = <String>{};
  int _layoutSaveRevision = 0;
  int _successfulLayoutSaveRevision = 0;
  int _failedLayoutSaveRevision = 0;

  bool get _needsLayoutSaveRetry =>
      _failedLayoutSaveRevision > _successfulLayoutSaveRevision;

  ReaderSettings get preferences =>
      appdata.settings.readerSettings(cid, type.sourceKey);

  bool _automaticReadingRefreshQueued = false;

  void _automaticReadingChanged() {
    if (_stateDisposed) return;
    // Input ownership can end while a replacement gesture widget is built.
    // Release the pause synchronously; defer only the ancestor's UI refresh.
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_automaticReadingRefreshQueued) return;
      _automaticReadingRefreshQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _automaticReadingRefreshQueued = false;
        if (mounted && !_stateDisposed) update();
      });
    } else {
      update();
    }
  }

  late final autoReading = AutoReadingController(
    settings: () {
      final current = preferences;
      return AutoReadingSettings(
        gallery: mode.isGallery,
        pageInterval: current.autoPageTurningInterval,
        pixelsPerSecond: current.autoScrollSpeed,
        stepped: current.autoScrollStyle == 'stepped',
        stepsPerSecond: current.autoScrollFrequency,
        pixelsPerStep: current.autoScrollDistance,
      );
    },
    canAdvance: () {
      final viewport = imageViewController;
      return mounted &&
          _session.contentReady &&
          !isLoading &&
          !isPageAnimating &&
          (ModalRoute.of(context)?.isCurrent ?? true) &&
          viewport is AutoReadingViewport &&
          (viewport as AutoReadingViewport).autoReadingReady;
    },
    advance: (distance) {
      final across = preferences.autoReadingAcrossChapters;
      if (!mode.isGallery) {
        return (imageViewController as AutoReadingViewport).autoScroll(
          distance,
          acrossChapters: across,
        );
      }
      if (page < maxPage) {
        return toNextPage()
            ? AutoReadingStep.advanced
            : AutoReadingStep.waiting;
      }
      if (across && chapter < maxChapter) {
        return toNextChapter()
            ? AutoReadingStep.advanced
            : AutoReadingStep.waiting;
      }
      return AutoReadingStep.finished;
    },
  )..addListener(_automaticReadingChanged);

  bool get isDetectingLayout =>
      _layoutAttempt != null && !_layoutAttempt!.task.isCancelled;

  @protected
  ComicLayoutProbe createLayoutProbe() => ComicLayoutProbe();

  @protected
  Future<void> saveReadingSettings(void Function(Settings draft) edit) =>
      appdata.updateSettings(edit, sync: false);

  bool get _usesAutomaticReadingMode =>
      preferences.autoReaderMode &&
      appdata.settings.comicReaderModeOverride(cid, type.sourceKey) == null;

  bool get _shouldDetectLayout =>
      _usesAutomaticReadingMode &&
      (appdata.settings.comicLayout(cid, type.sourceKey) ==
              ComicLayout.unknown ||
          _needsLayoutSaveRetry);

  /// Give first-open detection a small budget, then let reading proceed.
  Future<void> prepareReadingMode() async {
    if (_shouldDetectLayout &&
        (!_sampledChapters.contains(eid) || _needsLayoutSaveRetry)) {
      final detection = detectLayout();
      if (!_hasPresentedImages) {
        await Future.any([
          detection,
          Future<void>.delayed(const Duration(milliseconds: 700)),
        ]);
      }
    }
    _hasPresentedImages = true;
  }

  Future<void> detectLayout({bool force = false}) {
    final currentImages = images;
    if (!mounted || currentImages == null) return Future.value();
    final previous = _layoutAttempt;
    if (previous != null) {
      if (!force &&
          _matchesLayoutInput(previous) &&
          !previous.task.isCancelled &&
          !previous.probe.isCancelled) {
        return previous.result.future;
      }
      previous.task.cancel();
    }
    if (!force &&
        (!_shouldDetectLayout ||
            (_sampledChapters.contains(eid) && !_needsLayoutSaveRetry))) {
      return Future.value();
    }
    ComicLayoutProbe? probe;
    _ReaderLayoutAttempt? attempt;
    final task = imageWork.start(
      onCancel: () {
        try {
          probe?.cancel();
        } finally {
          attempt?.completeResult();
        }
      },
    );
    if (task == null) return Future.value();
    try {
      probe = createLayoutProbe();
      final started = _ReaderLayoutAttempt(
        probe: probe,
        task: task,
        images: currentImages,
        comicId: cid,
        sourceKey: type.sourceKey,
        networkSourceKey: type.comicSource?.key,
        chapter: chapter,
        chapterId: eid,
      );
      attempt = started;
      _layoutAttempt = started;
      update();
      unawaited(_runLayoutDetection(started));
      return started.result.future;
    } catch (error, stack) {
      task.recordFailure(error, stack);
      task.finish();
      Log.error('Reader', 'Failed to start layout detection: $error', stack);
      return Future.value();
    }
  }

  bool _matchesLayoutInput(_ReaderLayoutAttempt attempt) =>
      mounted &&
      identical(images, attempt.images) &&
      chapter == attempt.chapter &&
      eid == attempt.chapterId &&
      cid == attempt.comicId &&
      type.sourceKey == attempt.sourceKey;

  void _cancelOutdatedLayout() {
    final attempt = _layoutAttempt;
    if (attempt != null && !_matchesLayoutInput(attempt)) {
      attempt.task.cancel();
    }
  }

  bool _canPublishLayout(_ReaderLayoutAttempt attempt) =>
      identical(_layoutAttempt, attempt) &&
      _matchesLayoutInput(attempt) &&
      !attempt.task.isCancelled &&
      !attempt.probe.isCancelled;

  Future<void> _runLayoutDetection(_ReaderLayoutAttempt attempt) async {
    final reported = Set<Object>.identity();
    void report(Object error, StackTrace stack) {
      if (!reported.add(error)) return;
      attempt.task.recordFailure(error, stack);
      Log.error('Reader', 'Layout detection failed: $error', stack);
    }

    // Observe cleanup immediately, even if the presentation result is still
    // pending. Both channels may report the same original failure.
    var cleanupFailed = false;
    final cleanup = attempt.probe.done.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        cleanupFailed = true;
        report(error, stack);
      },
    );
    try {
      final detection = await attempt.probe.detect(
        images: List.of(attempt.images),
        sourceKey: attempt.networkSourceKey,
        comicId: attempt.comicId,
        chapterId: attempt.chapterId,
      );
      if (!_canPublishLayout(attempt)) return;
      await cleanup;
      if (cleanupFailed || !_canPublishLayout(attempt)) return;
      final saveRevision = ++_layoutSaveRevision;
      var applied = false;
      try {
        await saveReadingSettings((draft) {
          if (!_canPublishLayout(attempt)) return;
          draft.setComicLayout(attempt.comicId, attempt.sourceKey, detection);
          applied = true;
        });
      } catch (_) {
        // Saving can fail after part of the global settings is persisted.
        // The layout belongs to this comic, even if a different chapter or
        // probe now owns the UI. A newer successful save repairs old failures.
        if (saveRevision > _failedLayoutSaveRevision) {
          _failedLayoutSaveRevision = saveRevision;
        }
        rethrow;
      }
      if (!applied) return;
      if (saveRevision > _successfulLayoutSaveRevision) {
        _successfulLayoutSaveRevision = saveRevision;
      }
      if (!_canPublishLayout(attempt)) return;
      _sampledChapters.add(attempt.chapterId);
      if (detection.layout == ComicLayout.unknown ||
          !_usesAutomaticReadingMode) {
        return;
      }
      final next = ReaderMode.fromKey(preferences.readerMode);
      if (!mounted || next == mode) return;
      applyReadingMode(next);
      showToast(
        context: context,
        message: 'Switched to @mode'.tlParams({
          'mode': readerModeLabels[next.key] ?? next.key,
        }),
      );
    } catch (error, stack) {
      report(error, stack);
      attempt.task.cancel();
    } finally {
      if (identical(_layoutAttempt, attempt)) {
        _layoutAttempt = null;
        if (mounted) update();
      }
      // Cancellation/timeout releases the UI budget while the original work
      // and any accepted settings save remain owned by the reading session.
      attempt.completeResult();
      await cleanup;
      attempt.task.finish();
    }
  }

  void applyReadingMode(ReaderMode next) {
    if (!mounted || _sessionFrozen || mode == next) return;
    resetPageAnimation();
    mode = next;
    // Convert the old display page to its source image before rebuilding.
    _checkImagesPerPageChange();
    viewportBinding.clear();
    update();
  }

  bool get isLoading => controller.content.isLoading;

  late final focusNode = FocusNode()..addListener(_keyboardFocusChanged);

  void _keyboardFocusChanged() {
    if (!_stateDisposed && !focusNode.hasPrimaryFocus) {
      imageViewController?.cancelKeyboardInput();
    }
  }

  @override
  void initState() {
    page = widget.initialPage ?? 1;
    if (page < 1) {
      page = 1;
    }
    final initialChapter = widget.initialChapter ?? 1;
    controller.restoreChapter(initialChapter < 1 ? 1 : initialChapter);
    if (widget.initialChapterGroup != null) {
      controller.restoreChapter(
        widget.chapters!.chapterIndex(
          chapter,
          group: widget.initialChapterGroup,
        ),
      );
    }
    if (widget.initialPage != null) {
      page = widget.initialPage!;
      if (page < 1) {
        page = 1;
      }
    }
    mode = ReaderMode.fromKey(
      appdata.settings.readerSettings(cid, type.sourceKey).readerMode,
    );
    history = widget.history;
    final historyManager = HistoryManager();
    final durationHistory = widget.history;
    _sessionRegistry = context
        .getInheritedWidgetOfExactType<SelectionTasksScope>()
        ?.registry;
    _exitFrame = context.getInheritedWidgetOfExactType<WindowFrameController>();
    final admitted = _sessionRegistry?.isClosing != true;
    final onClosed = widget.onClosed;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _volumeForeground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _session = ReaderSession(
      imageWork: imageWork,
      durations: ReadingSessionTracker(
        onDuration: (duration) =>
            historyManager.addReadDuration(durationHistory, duration),
        onError: (error, stack) => Log.error(
          'Reader',
          'Failed to save reading duration: $error',
          stack,
        ),
      ),
      progress: ReaderHistoryWriter(
        write: () async {
          final item = history;
          if (item != null) await historyManager.addHistory(item);
        },
        onError: (error, stack) => Log.error(
          'Reader',
          'Failed to save reading progress: $error',
          stack,
        ),
      ),
      pauseAutoReading: (paused) {
        autoReading.pause('lifecycle', paused);
        _observeVolume(_updateVolume());
      },
      onClosed: () {
        if (admitted) onClosed();
      },
      foreground: lifecycle == null || lifecycle == AppLifecycleState.resumed,
    );
    _bindSessionOwner();
    if (_sessionFrozen) {
      super.initState();
      return;
    }
    _platformEffects = ReaderPlatformEffectsBinding(
      context,
      systemBarsVisible: preferences.showSystemStatusBar,
    );
    if (appdata.settings
        .readerSettings(cid, type.sourceKey)
        .enableTurnPageByVolumeKey) {
      handleVolumeEvent();
    }
    setImageCacheSize();
    final favorites = LocalFavoritesManager();
    final favoriteGeneration = favorites.connectionGeneration;
    final comicId = cid;
    final comicType = type;
    final readingDelay = Completer<void>();
    Timer? readingTimer;
    final readingTask = imageWork.start(
      onCancel: () {
        readingTimer?.cancel();
        if (!readingDelay.isCompleted) readingDelay.complete();
      },
    );
    if (readingTask != null) {
      readingTimer = Timer(
        const Duration(milliseconds: 200),
        readingDelay.complete,
      );
      unawaited(() async {
        try {
          // Retain the original post-navigation delay, but own it through exit.
          await readingDelay.future;
          readingTask.check();
          await favorites.onRead(
            comicId,
            comicType,
            generation: favoriteGeneration,
            checkActive: readingTask.check,
          );
        } on ImageWorkTaskCancelled {
          // Leaving before admission does not start another write.
        } catch (error, stack) {
          readingTask.recordFailure(error, stack);
          Log.error('Reader favorites', error, stack);
        } finally {
          readingTask.finish();
        }
      }());
    }
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  bool _isInitialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final registry = context
        .dependOnInheritedWidgetOfExactType<SelectionTasksScope>()
        ?.registry;
    final frame = context
        .dependOnInheritedWidgetOfExactType<WindowFrameController>();
    ReaderPlatformEffectsScope.watch(context);
    if (_platformEffects?.belongsTo(context) == false ||
        registry != _sessionRegistry ||
        frame?.trackExitTask != _exitFrame?.trackExitTask) {
      unawaited(_closeSession());
    }
    _volumeRoute = ModalRoute.of(context);
    _volumeCurrent = _volumeRoute?.isCurrent ?? true;
    _observeVolume(_updateVolume());
    if (!_isInitialized) {
      initImagesPerPage(widget.initialPage ?? 1);
      _isInitialized = true;
    } else {
      // For orientation changed
      _checkImagesPerPageChange();
    }
    if (!_sessionFrozen) initReaderWindow();
  }

  late final _imageCachePolicy = ReaderImageCachePolicy(
    readAvailableMemory: MemoryInfo.getFreePhysicalMemorySize,
    setLimit: (bytes) =>
        PaintingBinding.instance.imageCache.maximumSizeBytes = bytes,
    onConfigured: (memory, limit) => Log.info(
      'Reader',
      'Detect available RAM: $memory, set image cache size to $limit',
    ),
    onError: (error, stack) =>
        Log.error('Reader', 'Failed to size image cache: $error', stack),
  );

  void setImageCacheSize() => unawaited(_imageCachePolicy.configure());

  late final _volumeController = ReaderVolumeController(
    connect: createVolumeConnection,
    nextPage: () {
      return _canReceiveVolume && toNextPage();
    },
    previousPage: () {
      return _canReceiveVolume && toPrevPage();
    },
    nextChapter: () {
      if (_canReceiveVolume) toNextChapter();
    },
    previousChapter: () {
      if (_canReceiveVolume) toPrevChapter(toLastPage: true);
    },
    onError: (error, stack) =>
        Log.error('Reader', 'Volume navigation failed: $error', stack),
  );

  bool get supportsVolumeKeys => App.isAndroid;

  ReaderVolumeConnection createVolumeConnection(
    void Function(Object?) onEvent,
  ) => connectReaderVolume(onEvent);

  bool _volumeRequested = false;
  bool _volumeForeground = true;
  bool _volumeCurrent = false;
  ModalRoute<dynamic>? _volumeRoute;
  bool _volumeWindowHeld = false;
  bool _volumeClosed = false;
  Future<void>? _volumeClosing;
  void Function()? _releaseVolumeHost;

  bool get _canReceiveVolume =>
      supportsVolumeKeys &&
      _volumeRequested &&
      _volumeForeground &&
      _volumeCurrent &&
      (_volumeRoute?.isCurrent ?? true) &&
      !_volumeWindowHeld &&
      !_volumeClosed &&
      !_sessionFrozen &&
      !_session.isHeld;

  Future<void> _updateVolume() => _volumeClosed
      ? Future.value()
      : _volumeController.setEnabled(_canReceiveVolume);

  void _observeVolume(Future<void> operation) {
    // The controller reports the error; the retained close callback owns retry.
    unawaited(
      operation.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  void handleVolumeEvent() {
    _volumeRequested = true;
    _observeVolume(_updateVolume());
  }

  void stopVolumeEvent() {
    _volumeRequested = false;
    _observeVolume(_updateVolume());
  }

  void _bindVolumeOwner() {
    _releaseVolumeHost = _sessionRegistry?.retain(
      cancel: _beginCloseVolume,
      close: _closeVolume,
    );
    final frame = _exitFrame;
    if (frame == null) return;
    frame.addCloseStartListener(_holdVolume);
    frame.addCloseFailureListener(_resumeVolume);
    frame.addExitTask(_prepareVolume);
    if (frame.isClosing) _holdVolume();
  }

  void _holdVolume() {
    _volumeWindowHeld = true;
    _observeVolume(_updateVolume());
  }

  void _resumeVolume() {
    _volumeWindowHeld = false;
    _observeVolume(_updateVolume());
  }

  Future<void> _prepareVolume() =>
      _volumeClosed ? _closeVolume() : _volumeController.setEnabled(false);

  void _beginCloseVolume() => _observeVolume(_closeVolume());

  Future<void> _closeVolume() {
    if (_volumeClosing case final closing?) return closing;
    _volumeClosed = true;
    final closing = _volumeClosing = _volumeController.dispose();
    unawaited(
      closing.then<void>(
        (_) {
          _releaseVolumeHost?.call();
          _releaseVolumeHost = null;
          _exitFrame?.removeCloseStartListener(_holdVolume);
          _exitFrame?.removeCloseFailureListener(_resumeVolume);
          _exitFrame?.removeExitTask(_prepareVolume);
        },
        onError: (Object _, StackTrace _) {
          _volumeClosing = null;
        },
      ),
    );
    return closing;
  }

  Future<void Function()> _prepareReaderExit() async {
    final effects = _platformEffects?.prepareForExit();
    void Function()? release;
    final failures =
        <({String operation, Object error, StackTrace stackTrace})>[];
    Future<void> attempt(
      String operation,
      Future<void> Function() action,
    ) async {
      try {
        await action();
      } catch (error, stackTrace) {
        failures.add((
          operation: operation,
          error: error,
          stackTrace: stackTrace,
        ));
      }
    }

    await Future.wait([
      attempt('reading preparation', () async {
        release = await _session.prepareForExit();
        await _updateVolume();
      }),
      if (effects != null) attempt('platform restoration', () => effects.ready),
    ]);
    if (failures.isNotEmpty) {
      await attempt('resume platform effects', () async => effects?.release());
      await attempt('resume reading', () async => release?.call());
      if (failures.length == 1) {
        Error.throwWithStackTrace(
          failures.single.error,
          failures.single.stackTrace,
        );
      }
      throw ReaderWindowFailure(failures);
    }
    return () {
      effects?.release();
      release?.call();
    };
  }

  ReaderPlatformEffectsBinding? _platformEffects;
  ReaderOrientation get readerOrientation =>
      _platformEffects?.handle.orientation ?? ReaderOrientation.system;

  void cycleReaderOrientation() {
    if (_sessionFrozen) return;
    if (_platformEffects?.cycleOrientation() == true) setState(() {});
  }

  void updateSystemUi(bool menuOpen) {
    if (_sessionFrozen) return;
    _platformEffects?.setSystemBarsVisible(
      menuOpen || preferences.showSystemStatusBar,
    );
  }

  ReaderWindowController? _windowController;
  Future<void>? _windowClosing;
  void Function()? _releaseWindowHost;
  WindowFrameController? _exitFrame;
  final _exitGuardKey = GlobalKey<ReaderExitGuardState>();
  void Function()? _windowSessionHold;
  final Set<void Function()> _preparedSessionReleases = {};

  Future<void> requestExit() => _sessionFrozen
      ? Future.value()
      : _exitGuardKey.currentState?.requestExit() ?? Future.value();

  void _holdWindowSession() {
    if (_sessionFrozen) return;
    _windowSessionHold ??= _session.holdForExit();
    _targetValidity.value++;
  }

  Future<void> _prepareWindowSession() async {
    if (_sessionFrozen) {
      await _closeSession();
      return;
    }
    final frame = _exitFrame;
    final release = await _session.prepareForExit();
    if (!mounted || _sessionFrozen || !identical(_exitFrame, frame)) {
      release();
      return;
    }
    _preparedSessionReleases.add(release);
  }

  void _resumeWindowSession() {
    final releases = _preparedSessionReleases.toList();
    final hold = _windowSessionHold;
    _preparedSessionReleases.clear();
    _windowSessionHold = null;
    final failures =
        <({String operation, Object error, StackTrace stackTrace})>[];
    for (final release in [...releases, ?hold]) {
      try {
        release();
      } catch (error, stackTrace) {
        failures.add((
          operation: 'resume',
          error: error,
          stackTrace: stackTrace,
        ));
      }
    }
    if (failures.isNotEmpty) throw ReaderSessionFailure(failures);
  }

  void initReaderWindow() {
    if (!App.isDesktop || _windowController != null) return;
    final frame = _exitFrame;
    if (frame == null || frame.isClosing) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    _windowController = ReaderWindowController(
      coordinator: windowCoordinator,
      frameIdentity: frame.setWindowFrame,
      initialFrameVisible: !frame.isWindowFrameHidden,
      setFrameVisible: frame.setWindowFrame,
      addCloseListener: frame.addCloseListener,
      removeCloseListener: frame.removeCloseListener,
      canPop: navigator.canPop,
      pop: () {
        if (_sessionFrozen) return;
        if (ModalRoute.of(context)?.isCurrent == true) {
          unawaited(requestExit());
        } else {
          unawaited(navigator.maybePop());
        }
      },
      onError: (error, stack) =>
          Log.error('Reader', 'Window transition failed: $error', stack),
    );
    _releaseWindowHost = _sessionRegistry?.retain(
      cancel: disposeReaderWindow,
      close: _closeReaderWindow,
    );
    frame.addCloseStartListener(_holdWindowEffects);
    frame.addCloseFailureListener(_resumeWindowEffects);
    frame.addExitTask(_prepareWindowEffects);
    if (frame.isClosing) _holdWindowEffects();
    _observeWindow(_windowController!.attach());
  }

  // window_manager addresses one native window per engine. Keep its serial
  // coordinator across route and WindowFrame replacements, with scoped owners.
  static final _nativeWindowCoordinator = ReaderWindowCoordinator(
    hide: windowManager.hide,
    show: windowManager.show,
    setFullscreen: windowManager.setFullScreen,
  );

  ReaderWindowCoordinator get windowCoordinator => _nativeWindowCoordinator;

  void _observeWindow(Future<void> operation) {
    unawaited(
      operation.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  void _holdWindowEffects() {
    final window = _windowController;
    if (window != null) _observeWindow(window.setHeld(true));
  }

  void _resumeWindowEffects() {
    final window = _windowController;
    if (window != null) _observeWindow(window.setHeld(false));
  }

  Future<void> _prepareWindowEffects() => _sessionFrozen
      ? _closeReaderWindow()
      : _windowController?.setHeld(true) ?? Future.value();

  void fullscreen() {
    if (_sessionFrozen) return;
    final window = _windowController;
    if (window != null) _observeWindow(window.toggle());
  }

  void disposeReaderWindow() => _observeWindow(_closeReaderWindow());

  Future<void> _closeReaderWindow() {
    if (_windowClosing case final closing?) return closing;
    final window = _windowController;
    if (window == null) return Future.value();
    final closing = _windowClosing = window.dispose();
    unawaited(
      closing.then<void>(
        (_) {
          _releaseWindowHost?.call();
          _releaseWindowHost = null;
          _exitFrame?.removeCloseStartListener(_holdWindowEffects);
          _exitFrame?.removeCloseFailureListener(_resumeWindowEffects);
          _exitFrame?.removeExitTask(_prepareWindowEffects);
        },
        onError: (Object _, StackTrace _) {
          _windowClosing = null;
        },
      ),
    );
    return closing;
  }

  @override
  void dispose() {
    _stateDisposed = true;
    _targetValidity.value++;
    viewportBinding.dispose();
    controller.dispose();
    _layoutAttempt?.task.cancel();
    _layoutAttempt = null;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_closeSession());
    autoReading.dispose();
    focusNode.dispose();
    _platformEffects?.dispose();
    _beginCloseVolume();
    _imageCachePolicy.dispose();
    disposeReaderWindow();
    _targetValidity.dispose();
    _shellChanges.dispose();
    super.dispose();
  }

  void onReaderContentLoading() {
    // A reload can retain the old images while the replacement is fetched.
    _layoutAttempt?.task.cancel();
    _session.setContentReady(false);
  }

  void onReaderContentReady() => _session.setContentReady(true);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _volumeForeground = state == AppLifecycleState.resumed;
    _session.setForeground(state == AppLifecycleState.resumed);
    _observeVolume(_updateVolume());
  }

  @override
  Widget build(BuildContext context) {
    _checkImagesPerPageChange();
    return ReaderExitGuard(
      key: _exitGuardKey,
      prepare: _prepareReaderExit,
      holdForLeave: _session.holdForExit,
      onError: (error, stack) {
        Log.error('Reader', 'Failed to save before leaving: $error', stack);
        if (mounted) {
          showToast(
            message: 'Unable to close. Please try again.'.tl,
            context: context,
            seconds: 10,
            trailing: TextButton(
              onPressed: () => _exitGuardKey.currentState?.leaveWithoutSaving(),
              child: Text('Leave without saving'.tl),
            ),
          );
        }
      },
      child: ExcludeFocus(
        excluding: _sessionFrozen,
        child: AbsorbPointer(
          absorbing: _sessionFrozen,
          child: KeyboardListener(
            focusNode: focusNode,
            autofocus: true,
            onKeyEvent: onKeyEvent,
            child: Overlay.wrap(
              child: ReaderShellHost(
                reader: this,
                child: ReaderGestureHost(
                  reader: this,
                  child: ReaderImagesHost(
                    reader: this,
                    key: Key(mode.isWaterfall ? mode.key : chapter.toString()),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void onKeyEvent(KeyEvent event) {
    if (_sessionFrozen) return;
    if (event.logicalKey == LogicalKeyboardKey.f12 && event is KeyUpEvent) {
      fullscreen();
    }
    if (!focusNode.hasPrimaryFocus) return;
    imageViewController?.handleKeyEvent(event);
  }

  int get maxChapter => widget.chapters?.length ?? 1;

  void onPageChanged() {
    updateHistory();
    if (!_stateDisposed) _targetValidity.value++;
  }

  void updateHistory() {
    // Initial layout and orientation can update the viewport before images
    // arrive. Keep the saved image index intact until loading/migration ends.
    if (_sessionFrozen || isLoading || images == null) return;
    if (history != null) {
      applyReaderHistoryProgress(
        history: history!,
        page: page,
        imageCount: images!.length,
        chapter: chapter,
        chapters: widget.chapters,
        layout: pageLayout,
        time: DateTime.now(),
      );
      _session.scheduleProgress();
      // A content/animation completion can arrive after the reader's own exit
      // task returned while another owner is still preparing. Register the
      // fresh drain so the window joins it before proceeding or restoring UI.
      if (_windowSessionHold != null) {
        _exitFrame?.trackExitTask(_prepareWindowSession());
      }
    }
  }

  bool get isFirstChapterOfGroup => widget.chapters?.isGrouped == true
      ? widget.chapters!.positionAt(chapter).isFirstInGroup
      : chapter == 1;

  bool get isLastChapterOfGroup => widget.chapters?.isGrouped == true
      ? widget.chapters!.positionAt(chapter).isLastInGroup
      : chapter == maxChapter;

  /// Get the size of the reader.
  /// The size is not always the same as the size of the screen.
  Size get size {
    var renderBox = context.findRenderObject() as RenderBox;
    return renderBox.size;
  }
}

abstract mixin class ReaderImagePerPageHandler {
  late int _lastImagesPerPage;

  late bool _lastOrientation;

  bool get isPortrait;

  int get page;

  set page(int value);

  ReaderMode get mode;

  String get cid;

  ComicType get type;

  /// Images used to bound page remapping
  List<String>? get images;

  void initImagesPerPage(int initialPage) {
    _lastImagesPerPage = imagesPerPage;
    _lastOrientation = isPortrait;
    if (imagesPerPage != 1) page = pageLayout.pageForImage(initialPage);
  }

  ReaderPageLayout get pageLayout => ReaderPageLayout(
    imagesPerPage: imagesPerPage,
    singleImageOnFirstPage: showSingleImageOnFirstPage(),
  );

  bool showSingleImageOnFirstPage() => appdata.settings
      .readerSettings(cid, type.sourceKey)
      .showSingleImageOnFirstPage;

  /// The number of images displayed on one screen
  int get imagesPerPage {
    if (mode.isContinuous) return 1;
    if (isPortrait) {
      return appdata.settings
          .readerSettings(cid, type.sourceKey)
          .readerScreenPicNumberForPortrait;
    } else {
      return appdata.settings
          .readerSettings(cid, type.sourceKey)
          .readerScreenPicNumberForLandscape;
    }
  }

  /// Check if the number of images per page has changed.
  void _checkImagesPerPageChange() {
    final currentImagesPerPage = imagesPerPage;
    final currentOrientation = isPortrait;
    if (_lastImagesPerPage != currentImagesPerPage ||
        _lastOrientation != currentOrientation) {
      final previousLayout = ReaderPageLayout(
        imagesPerPage: _lastImagesPerPage,
        singleImageOnFirstPage: showSingleImageOnFirstPage(),
      );
      page = previousLayout.remapPage(
        page,
        pageLayout,
        imageCount: images?.length,
      );
      _lastImagesPerPage = currentImagesPerPage;
      _lastOrientation = currentOrientation;
    }
  }
}

class _ReaderLayoutAttempt {
  _ReaderLayoutAttempt({
    required this.probe,
    required this.task,
    required this.images,
    required this.comicId,
    required this.sourceKey,
    required this.networkSourceKey,
    required this.chapter,
    required this.chapterId,
  });
  final ComicLayoutProbe probe;
  final ImageWorkTask task;
  final List<String> images;
  final String comicId;
  final String sourceKey;
  final String? networkSourceKey;
  final int chapter;
  final String chapterId;
  final result = Completer<void>();

  void completeResult() {
    if (!result.isCompleted) result.complete();
  }
}

enum ReaderMode {
  waterfallTopToBottom('waterfallTopToBottom'),
  galleryLeftToRight('galleryLeftToRight'),
  galleryRightToLeft('galleryRightToLeft'),
  galleryTopToBottom('galleryTopToBottom'),
  continuousTopToBottom('continuousTopToBottom'),
  continuousLeftToRight('continuousLeftToRight'),
  continuousRightToLeft('continuousRightToLeft');

  final String key;

  bool get isGallery => key.startsWith('gallery');

  bool get isWaterfall => key.startsWith('waterfall');

  bool get isContinuous => key.startsWith('continuous') || isWaterfall;

  bool get isTopToBottom =>
      this == galleryTopToBottom ||
      this == continuousTopToBottom ||
      this == waterfallTopToBottom;

  const ReaderMode(this.key);

  static ReaderMode fromKey(String key) {
    for (var mode in values) {
      if (mode.key == key) {
        return mode;
      }
    }
    return waterfallTopToBottom;
  }
}
