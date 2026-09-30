import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_memory_info/flutter_memory_info.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/reader/gesture.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/images.dart';
import 'package:venera_next/features/reader/layout_detection.dart';
import 'package:venera_next/features/reader/reader_mode_labels.dart';
import 'package:venera_next/features/reader/reading_session.dart';
import 'package:venera_next/features/reader/reader_controller.dart';
import 'package:venera_next/features/reader/page_layout.dart';
import 'package:venera_next/features/reader/scaffold.dart';
import 'package:venera_next/features/reader/volume.dart';
import 'package:venera_next/features/sync/sync.dart';
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

  @override
  State<Reader> createState() => ReaderState();
}

class ReaderState extends State<Reader>
    with
        ReaderLocation,
        ReaderWindow,
        ReaderVolumeListener,
        ReaderImagePerPageHandler,
        WidgetsBindingObserver {
  @override
  void update() {
    if (mounted) setState(() {});
  }

  /// The maximum page number for images only (excluding chapter comments page).
  /// This is used for display purposes and history recording.
  @override
  int get maxPage => pageLayout.pageCount(images?.length);

  /// Total pages including chapter comments page (used for internal page control).
  @override
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
  List<String>? images;

  @override
  late ReaderMode mode;

  @override
  bool get isPortrait =>
      MediaQuery.of(context).orientation == Orientation.portrait;

  History? history;

  bool localPageOrderChecked = false;

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

  late final ReadingSessionTracker _readingSession;
  bool _readerContentReady = false;
  bool _hasPresentedImages = false;
  ComicLayoutProbe? _layoutProbe;
  final _sampledChapters = <String>{};

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
          _readerContentReady &&
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

  bool get isDetectingLayout => _layoutProbe != null;

  @protected
  ComicLayoutProbe createLayoutProbe() => ComicLayoutProbe();

  @protected
  Future<void> saveReadingSettings() => appdata.saveData(false);

  bool get _usesAutomaticReadingMode =>
      preferences.autoReaderMode &&
      appdata.settings.comicReaderModeOverride(cid, type.sourceKey) == null;

  bool get _shouldDetectLayout =>
      _usesAutomaticReadingMode &&
      appdata.settings.comicLayout(cid, type.sourceKey) == ComicLayout.unknown;

  /// Give first-open detection a small budget, then let reading proceed.
  Future<void> prepareReadingMode() async {
    if (_shouldDetectLayout && !_sampledChapters.contains(eid)) {
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

  Future<void> detectLayout({bool force = false}) async {
    if (!mounted || images == null || _layoutProbe != null) return;
    if (!force && (!_shouldDetectLayout || _sampledChapters.contains(eid))) {
      return;
    }
    _sampledChapters.add(eid);
    final probe = createLayoutProbe();
    _layoutProbe = probe;
    update();
    final detection = await probe.detect(
      images: images!,
      sourceKey: type.comicSource?.key,
      comicId: cid,
      chapterId: eid,
    );
    if (!mounted || _layoutProbe != probe) return;
    _layoutProbe = null;
    appdata.settings.setComicLayout(cid, type.sourceKey, detection);
    unawaited(saveReadingSettings());
    update();
    if (detection.layout == ComicLayout.unknown || !_usesAutomaticReadingMode) {
      return;
    }
    final next = ReaderMode.fromKey(preferences.readerMode);
    if (next == mode) return;
    applyReadingMode(next);
    showToast(
      context: context,
      message: 'Switched to @mode'.tlParams({
        'mode': readerModeLabels[next.key] ?? next.key,
      }),
    );
  }

  void applyReadingMode(ReaderMode next) {
    if (!mounted || mode == next) return;
    resetPageAnimation();
    mode = next;
    // Convert the old display page to its source image before rebuilding.
    _checkImagesPerPageChange();
    imageViewController = null;
    update();
  }

  @override
  bool isLoading = false;

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
    _readingSession = ReadingSessionTracker(
      onDuration: (duration) =>
          HistoryManager().addReadDuration(widget.history, duration),
      onError: (error, stackTrace) {
        Log.error(
          "Reader",
          "Failed to save reading duration: $error",
          stackTrace,
        );
      },
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
    Future.delayed(const Duration(milliseconds: 200), () {
      LocalFavoritesManager().onRead(cid, type);
    });
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

  void setImageCacheSize() async {
    var availableRAM = await MemoryInfo.getFreePhysicalMemorySize();
    if (availableRAM == null) return;
    int maxImageCacheSize;
    if (availableRAM < 1 << 30) {
      maxImageCacheSize = 100 << 20;
    } else if (availableRAM < 2 << 30) {
      maxImageCacheSize = 200 << 20;
    } else if (availableRAM < 4 << 30) {
      maxImageCacheSize = 300 << 20;
    } else {
      maxImageCacheSize = 500 << 20;
    }
    Log.info(
      "Reader",
      "Detect available RAM: $availableRAM, set image cache size to $maxImageCacheSize",
    );
    PaintingBinding.instance.imageCache.maximumSizeBytes = maxImageCacheSize;
  }

  @override
  void dispose() {
    controller.dispose();
    _layoutProbe?.cancel();
    _layoutProbe = null;
    WidgetsBinding.instance.removeObserver(this);
    if (isFullscreen) {
      fullscreen();
    }
    autoReading.dispose();
    _flushPendingHistoryUpdate();
    unawaited(
      _readingSession.dispose().whenComplete(() {
        DataSync().onDataChanged();
      }),
    );
    focusNode.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    stopVolumeEvent();
    PaintingBinding.instance.imageCache.maximumSizeBytes = 100 << 20;
    disposeReaderWindow();
    super.dispose();
  }

  void onReaderContentLoading() {
    _readerContentReady = false;
    unawaited(_readingSession.pause());
  }

  void onReaderContentReady() {
    _readerContentReady = true;
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState == null || lifecycleState == AppLifecycleState.resumed) {
      _readingSession.start();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    autoReading.pause('lifecycle', state != AppLifecycleState.resumed);
    switch (state) {
      case AppLifecycleState.resumed:
        if (_readerContentReady) {
          _readingSession.start();
        }
        return;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        unawaited(_readingSession.pause());
    }
  }

  @override
  Widget build(BuildContext context) {
    _checkImagesPerPageChange();
    return KeyboardListener(
      focusNode: focusNode,
      autofocus: true,
      onKeyEvent: onKeyEvent,
      child: Overlay.wrap(
        child: ReaderScaffold(
          child: ReaderGestureDetector(
            child: ReaderImages(
              key: Key(mode.isWaterfall ? mode.key : chapter.toString()),
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

  @override
  int get maxChapter => widget.chapters?.length ?? 1;

  @override
  void onPageChanged() {
    updateHistory();
  }

  /// Prevent multiple history updates in a short time.
  /// `HistoryManager().addHistoryAsync` is a high-cost operation because it creates a new isolate.
  Timer? _updateHistoryTimer;

  void _flushPendingHistoryUpdate() {
    if (_updateHistoryTimer == null) {
      return;
    }
    _updateHistoryTimer!.cancel();
    _updateHistoryTimer = null;
    final item = history;
    if (item != null) {
      HistoryManager().addHistory(item);
    }
  }

  void updateHistory() {
    // Initial layout and orientation can update the viewport before images
    // arrive. Keep the saved image index intact until loading/migration ends.
    if (isLoading || images == null) return;
    if (history != null) {
      history!.page = pageLayout.historyImage(page, images!.length);
      history!.maxPage = images?.length ?? 1;
      if (widget.chapters?.isGrouped ?? false) {
        final position = widget.chapters!.positionAt(chapter);
        history!.readEpisode.add(position.historyKey);
        history!.ep = position.chapter;
        history!.group = position.group;
      } else {
        history!.readEpisode.add(chapter.toString());
        history!.ep = chapter;
      }
      history!.time = DateTime.now();
      _updateHistoryTimer?.cancel();
      _updateHistoryTimer = Timer(const Duration(seconds: 1), () {
        HistoryManager().addHistoryAsync(history!);
        _updateHistoryTimer = null;
      });
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

abstract mixin class ReaderVolumeListener {
  bool toNextPage();

  bool toPrevPage();

  bool toNextChapter();

  bool toPrevChapter({bool toLastPage = false});

  VolumeListener? volumeListener;

  void onDown() {
    if (!toNextPage()) {
      toNextChapter();
    }
  }

  void onUp() {
    if (!toPrevPage()) {
      toPrevChapter(toLastPage: true);
    }
  }

  void handleVolumeEvent() {
    if (!App.isAndroid) {
      // Currently only support Android
      return;
    }
    if (volumeListener != null) {
      volumeListener?.cancel();
    }
    volumeListener = VolumeListener(onDown: onDown, onUp: onUp)..listen();
  }

  void stopVolumeEvent() {
    if (volumeListener != null) {
      volumeListener?.cancel();
      volumeListener = null;
    }
  }
}

abstract mixin class ReaderLocation {
  late final controller = ReaderController(
    pageCount: () => totalPages,
    chapterCount: () => maxChapter,
    isLoading: () => isLoading,
    animationEnabled: () => enablePageAnimation(cid, type),
    viewport: () => imageViewController,
    onChanged: update,
    onPageChanged: onPageChanged,
    onError: (error, stack) =>
        Log.error('Reader', 'Page navigation failed: $error', stack),
  );

  int get page => controller.state.page;
  set page(int value) => controller.setPage(value);
  int get chapter => controller.state.chapter;
  bool get jumpToLastPageOnLoad => controller.state.jumpToLastPageOnLoad;
  int get maxPage;
  int get totalPages;
  int get maxChapter;
  bool get isLoading;
  String get cid;
  ComicType get type;
  void update();
  void onPageChanged();

  bool enablePageAnimation(String cid, ComicType type) =>
      appdata.settings.readerSettings(cid, type.sourceKey).enablePageAnimation;

  ReaderImageViewController? imageViewController;

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
}

mixin class ReaderWindow {
  bool isFullscreen = false;

  late WindowFrameController windowFrame;

  bool _isInit = false;

  void initReaderWindow() {
    if (!App.isDesktop || _isInit) return;
    windowFrame = WindowFrame.of(App.rootContext);
    windowFrame.addCloseListener(onWindowClose);
    _isInit = true;
  }

  void fullscreen() async {
    if (!App.isDesktop) return;
    await windowManager.hide();
    await windowManager.setFullScreen(!isFullscreen);
    await windowManager.show();
    isFullscreen = !isFullscreen;
    WindowFrame.of(App.rootContext).setWindowFrame(!isFullscreen);
  }

  bool onWindowClose() {
    if (Navigator.of(App.rootContext).canPop()) {
      Navigator.of(App.rootContext).pop();
      return false;
    } else {
      return true;
    }
  }

  void disposeReaderWindow() {
    if (!App.isDesktop) return;
    windowFrame.removeCloseListener(onWindowClose);
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

abstract interface class ReaderImageViewController
    implements ReaderNavigationViewport {
  void handleDoubleTap(Offset location);

  void handleLongPressDown(Offset location);

  void handleLongPressUp(Offset location);

  void handleKeyEvent(KeyEvent event);

  /// Returns true if the event is handled.
  bool handleOnTap(Offset location);

  Future<Uint8List?> getImageByOffset(Offset offset);

  String? getImageKeyByOffset(Offset offset);
}
