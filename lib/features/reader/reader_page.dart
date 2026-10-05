import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_memory_info/flutter_memory_info.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/reader/gesture.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/images_host.dart';
import 'package:venera_next/features/reader/image_cache_policy.dart';
import 'package:venera_next/features/reader/layout_detection.dart';
import 'package:venera_next/features/reader/reader_mode_labels.dart';
import 'package:venera_next/features/reader/reading_session.dart';
import 'package:venera_next/features/reader/reader_session.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/features/reader/history_writer.dart';
import 'package:venera_next/features/reader/exit_guard.dart';
import 'package:venera_next/features/reader/reader_controller.dart';
import 'package:venera_next/features/reader/reader_viewport.dart';
import 'package:venera_next/features/reader/page_order_migration.dart';

import 'package:venera_next/features/reader/page_layout.dart';
import 'package:venera_next/features/reader/history_progress.dart';
import 'package:venera_next/features/reader/scaffold.dart';
import 'package:venera_next/features/reader/volume.dart';
import 'package:venera_next/features/reader/volume_controller.dart';
import 'package:venera_next/features/reader/window_controller.dart';
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

  void update() {
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
  )..addListener(update);

  bool get isDetectingLayout =>
      _layoutAttempt != null && !_layoutAttempt!.task.isCancelled;

  @protected
  ComicLayoutProbe createLayoutProbe() => ComicLayoutProbe();

  @protected
  Future<void> saveReadingSettings() => appdata.saveData(false);

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
      appdata.settings.setComicLayout(
        attempt.comicId,
        attempt.sourceKey,
        detection,
      );
      final saveRevision = ++_layoutSaveRevision;
      try {
        await saveReadingSettings();
      } catch (_) {
        // Saving can fail after part of the global settings is persisted.
        // The layout belongs to this comic, even if a different chapter or
        // probe now owns the UI. A newer successful save repairs old failures.
        if (saveRevision > _failedLayoutSaveRevision) {
          _failedLayoutSaveRevision = saveRevision;
        }
        rethrow;
      }
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
    if (!mounted || mode == next) return;
    resetPageAnimation();
    mode = next;
    // Convert the old display page to its source image before rebuilding.
    _checkImagesPerPageChange();
    viewportBinding.clear();
    update();
  }

  bool get isLoading => controller.content.isLoading;

  var focusNode = FocusNode();

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
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _session = ReaderSession(
      imageWork: imageWork,
      durations: ReadingSessionTracker(
        onDuration: (duration) =>
            HistoryManager().addReadDuration(widget.history, duration),
        onError: (error, stack) => Log.error(
          'Reader',
          'Failed to save reading duration: $error',
          stack,
        ),
      ),
      progress: ReaderHistoryWriter(
        write: () async {
          final item = history;
          if (item != null) await HistoryManager().addHistory(item);
        },
        onError: (error, stack) => Log.error(
          'Reader',
          'Failed to save reading progress: $error',
          stack,
        ),
      ),
      pauseAutoReading: (paused) => autoReading.pause('lifecycle', paused),
      onClosed: widget.onClosed,
      foreground: lifecycle == null || lifecycle == AppLifecycleState.resumed,
    );
    if (!appdata.settings
        .readerSettings(cid, type.sourceKey)
        .showSystemStatusBar) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    }
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
    if (!_isInitialized) {
      initImagesPerPage(widget.initialPage ?? 1);
      _isInitialized = true;
    } else {
      // For orientation changed
      _checkImagesPerPageChange();
    }
    initReaderWindow();
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
    events: readerVolumeEvents,
    nextPage: () {
      return !_session.isHeld && toNextPage();
    },
    previousPage: () {
      return !_session.isHeld && toPrevPage();
    },
    nextChapter: () {
      if (!_session.isHeld) toNextChapter();
    },
    previousChapter: () {
      if (!_session.isHeld) toPrevChapter(toLastPage: true);
    },
    onError: (error, stack) =>
        Log.error('Reader', 'Volume navigation failed: $error', stack),
  );

  void handleVolumeEvent() {
    if (App.isAndroid) unawaited(_volumeController.setEnabled(true));
  }

  void stopVolumeEvent() => unawaited(_volumeController.setEnabled(false));

  ReaderWindowController? _windowController;
  WindowFrameController? _exitFrame;
  final _exitGuardKey = GlobalKey<ReaderExitGuardState>();
  void Function()? _windowSessionHold;
  final Set<void Function()> _preparedSessionReleases = {};

  Future<void> requestExit() =>
      _exitGuardKey.currentState?.requestExit() ?? Future.value();

  void _holdWindowSession() {
    _windowSessionHold ??= _session.holdForExit();
  }

  Future<void> _prepareWindowSession() async {
    final frame = _exitFrame;
    final release = await _session.prepareForExit();
    if (!mounted || !identical(_exitFrame, frame)) {
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
    final frame = WindowFrame.of(context);
    _exitFrame = frame;
    frame.addCloseStartListener(_holdWindowSession);
    frame.addCloseFailureListener(_resumeWindowSession);
    frame.addExitTask(_prepareWindowSession);
    final navigator = Navigator.of(context, rootNavigator: true);
    _windowController = ReaderWindowController(
      hide: windowManager.hide,
      show: windowManager.show,
      setFullscreen: windowManager.setFullScreen,
      setFrameVisible: frame.setWindowFrame,
      addCloseListener: frame.addCloseListener,
      removeCloseListener: frame.removeCloseListener,
      canPop: navigator.canPop,
      pop: () {
        if (ModalRoute.of(context)?.isCurrent == true) {
          unawaited(requestExit());
        } else {
          unawaited(navigator.maybePop());
        }
      },
      onError: (error, stack) =>
          Log.error('Reader', 'Window transition failed: $error', stack),
    )..attach();
  }

  void fullscreen() {
    final window = _windowController;
    if (window != null) unawaited(window.toggle());
  }

  void disposeReaderWindow() {
    final window = _windowController;
    if (window != null) unawaited(window.dispose());
  }

  @override
  void dispose() {
    viewportBinding.dispose();
    controller.dispose();
    _layoutAttempt?.task.cancel();
    _layoutAttempt = null;
    WidgetsBinding.instance.removeObserver(this);
    final closing = _session.dispose();
    autoReading.dispose();
    _exitFrame?.removeCloseStartListener(_holdWindowSession);
    _exitFrame?.removeCloseFailureListener(_resumeWindowSession);
    _exitFrame?.removeExitTask(_prepareWindowSession);
    _exitFrame?.trackExitTask(closing);
    _exitFrame = null;
    _resumeWindowSession();
    unawaited(
      closing.catchError((Object error, StackTrace stack) {
        Log.error('Reader', 'Failed to close reading session: $error', stack);
      }),
    );
    focusNode.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    unawaited(_volumeController.dispose());
    _imageCachePolicy.dispose();
    disposeReaderWindow();
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
    _session.setForeground(state == AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) {
    _checkImagesPerPageChange();
    return ReaderExitGuard(
      key: _exitGuardKey,
      prepare: _session.prepareForExit,
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
      child: KeyboardListener(
        focusNode: focusNode,
        autofocus: true,
        onKeyEvent: onKeyEvent,
        child: Overlay.wrap(
          child: ReaderScaffold(
            imageWork: imageWork,
            child: ReaderGestureDetector(
              child: ReaderImagesHost(
                reader: this,
                key: Key(mode.isWaterfall ? mode.key : chapter.toString()),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void onKeyEvent(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.f12 && event is KeyUpEvent) {
      fullscreen();
    }
    imageViewController?.handleKeyEvent(event);
  }

  int get maxChapter => widget.chapters?.length ?? 1;

  void onPageChanged() {
    updateHistory();
  }

  void updateHistory() {
    // Initial layout and orientation can update the viewport before images
    // arrive. Keep the saved image index intact until loading/migration ends.
    if (isLoading || images == null) return;
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
