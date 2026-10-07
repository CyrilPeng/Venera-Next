import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/features/reader/image_downloads.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/features/reader/image_position.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/waterfall_flow.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';
import 'package:venera_next/features/reader/waterfall_controller.dart';

import 'continuous_data.dart';
import 'display_image_provider.dart';
import 'reader_controller.dart';
import 'reader_viewport.dart';
import 'package:venera_next/network/request_scope.dart';
import 'chapter_swipe_indicator.dart';

const Set<PointerDeviceKind> _kTouchLikeDeviceTypes = <PointerDeviceKind>{
  PointerDeviceKind.touch,
  PointerDeviceKind.mouse,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.unknown,
};

class ReaderContinuousView extends StatefulWidget {
  const ReaderContinuousView({
    super.key,
    required this.data,
    required this.imageWork,
    required this.navigation,
    required this.loadChapter,
    required this.chapterId,
    required this.chapterTitle,
    required this.onViewportChanged,
    required this.onUpdate,
    required this.onFloatingButton,
    required this.onCollectImage,
    required this.onActiveChapterChanged,
    required this.onContentLoading,
    required this.onPreviousError,
    required this.onNavigationError,
    required this.readerSize,
    required this.readImage,
  });

  final ReaderContinuousData data;
  final ImageWork imageWork;
  final ReaderController navigation;
  final Future<List<String>> Function(int, RequestScope) loadChapter;
  final String Function(int) chapterId;
  final String Function(int) chapterTitle;
  final void Function(ReaderImageViewController, bool) onViewportChanged;
  final VoidCallback onUpdate;
  final void Function(int) onFloatingButton;
  final VoidCallback onCollectImage;
  final VoidCallback onActiveChapterChanged;
  final void Function(bool) onContentLoading;
  final void Function(Object, StackTrace) onPreviousError;
  final void Function(int, Object, StackTrace) onNavigationError;
  final Size Function() readerSize;
  final Future<Uint8List?> Function(ReaderImageAddress) readImage;

  @override
  State<ReaderContinuousView> createState() => ContinuousModeState();
}

class ContinuousModeState extends State<ReaderContinuousView>
    implements ReaderImageViewController, AutoReadingViewport {
  late var _imageDownloads = ReaderImageDownloads(work: widget.imageWork);

  @override
  (int, int)? get currentImageRange => (currentPage - 1, currentPage);

  ReaderContinuousData get data => widget.data;
  ReaderController get navigation => widget.navigation;
  int get currentPage => navigation.state.page;
  int get currentChapter => navigation.state.chapter;
  List<String> get images => navigation.content.images ?? const [];
  int get maxPage => images.length;

  var itemScrollController = ItemScrollController();
  var itemPositionsListener = ItemPositionsListener.create();
  var photoViewController = PhotoViewController();
  ScrollController? _scrollController;
  bool _disposed = false;
  Timer? _initialCacheTimer;
  Timer? _scrollActivityTimer;
  ScrollPosition? _smoothPosition;
  int _smoothGeneration = 0;

  ScrollController get scrollController => _scrollController!;

  var isCTRLPressed = false;
  static var _isMouseScrolling = false;
  var fingers = 0;
  bool disableScroll = false;

  late List<bool> cached;

  late var _waterfall = _createWaterfall();

  WaterfallController _createWaterfall() => WaterfallController(
    imageWork: widget.imageWork,
    maxChapter: data.maxChapter,
    load: widget.loadChapter,
    chapterId: widget.chapterId,
    onChanged: () {
      if (mounted) setState(() {});
    },
    onPreviousError: widget.onPreviousError,
  );
  WaterfallFlowView get _waterfallFlow => _waterfall.flow;

  bool _isRestoringPrependedSegmentPosition = false;

  bool _isNavigatingWaterfallLocation = false;

  void Function({bool notify})? _releaseWaterfallLoading;

  VoidCallback _holdWaterfallLoading(bool needsLoading) {
    _releaseWaterfallLoading?.call();
    if (!needsLoading) return () {};
    final onLoading = widget.onContentLoading;
    var active = true;
    void release({bool notify = true}) {
      if (!active) return;
      active = false;
      if (identical(_releaseWaterfallLoading, release)) {
        _releaseWaterfallLoading = null;
      }
      if (notify) onLoading(false);
    }

    _releaseWaterfallLoading = release;
    onLoading(true);
    return () => release();
  }

  int get preCacheCount => data.preloadCount;

  /// Whether the user was scrolling the page.
  /// The gesture detector has a delay to detect tap event.
  /// To handle the tap event, we need to know if the user was scrolling before the delay.
  bool delayedIsScrolling = false;

  var imageStates = <State<ComicImage>>{};

  void delayedSetIsScrolling(bool value) {
    _scrollActivityTimer?.cancel();
    _scrollActivityTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted && !_disposed) delayedIsScrolling = value;
    });
  }

  bool prepareToPrevChapter = false;
  bool prepareToNextChapter = false;
  bool jumpToNextChapter = false;
  bool jumpToPrevChapter = false;

  bool isZoomedIn = false;
  bool isLongPressing = false;

  bool get crossChapter => data.crossChapter;

  bool get _splitWideImages => data.vertical && data.splitWideImages;

  bool get _splitWideImagesInvert => data.invertSplit;

  int get _flowImageCount => crossChapter ? _waterfallFlow.imageCount : maxPage;

  int get _flowItemCount => _flowImageCount + 2;

  void _initSegments() {
    if (!crossChapter ||
        !_waterfallFlow.isEmpty ||
        navigation.content.images == null) {
      return;
    }
    _waterfall.initialize(
      WaterfallChapterSegment(
        chapter: currentChapter,
        eid: widget.chapterId(currentChapter),
        images: images,
      ),
    );
  }

  WaterfallChapterSegment? _segmentOfChapter(int chapter) {
    return _waterfallFlow.segmentOfChapter(chapter);
  }

  WaterfallImageRef? _imageRefAt(int index) {
    if (!crossChapter) {
      if (index <= 0 || index > images.length) return null;
      return WaterfallImageRef(
        position: ReaderImagePosition(
          chapter: currentChapter,
          imageNumber: index,
          chapterId: widget.chapterId(currentChapter),
        ),
        imageKey: images[index - 1],
        isFirstInSegment: index == 1,
      );
    }
    return _waterfallFlow.imageRefAt(index);
  }

  Future<void> _ensureWaterfallImagesAfter(int current) async {
    if (!crossChapter || !mounted) return;
    await _waterfall.ensureAfter(
      current: current,
      threshold: math.max(preCacheCount, 1),
    );
  }

  Future<void> _ensureWaterfallImagesBefore(int current) async {
    if (!crossChapter || !mounted) return;
    final waterfall = _waterfall;
    final revision = waterfall.revision;
    bool isCurrent() =>
        mounted &&
        identical(_waterfall, waterfall) &&
        revision == waterfall.revision;
    final insertedCount = await waterfall.ensureBefore(
      current: current,
      threshold: math.max(preCacheCount, 1),
    );
    if (!isCurrent() || insertedCount == 0) {
      return;
    }
    _isRestoringPrependedSegmentPosition = true;
    setState(() {});
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!isCurrent()) return;
      itemScrollController.jumpTo(index: current + insertedCount);
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (isCurrent()) {
          _isRestoringPrependedSegmentPosition = false;
        }
      });
    });
  }

  void _setReaderLocation(WaterfallImageRef imageRef) {
    var segment = _segmentOfChapter(imageRef.position.chapter);
    var chapterChanged = currentChapter != imageRef.position.chapter;
    if (segment != null && chapterChanged) {
      navigation.restoreChapter(imageRef.position.chapter);
      navigation.replaceChapterImages(segment.images);
      // Wait until the scroll/layout callback has finished before updating UI.
      final waterfall = _waterfall;
      Future.microtask(() {
        if (mounted && identical(_waterfall, waterfall)) {
          widget.onActiveChapterChanged();
        }
      });
    }
    if (chapterChanged || currentPage != imageRef.position.imageNumber) {
      navigation.reportPage(imageRef.position.imageNumber);
    }
  }

  int? _waterfallIndexOfChapterPage(int chapter, int page) {
    if (!crossChapter) return page;
    final segment = _segmentOfChapter(chapter);
    if (segment == null) return null;
    return _waterfallFlow.imageIndexOf(
      ReaderImagePosition(
        chapter: chapter,
        chapterId: segment.eid,
        imageNumber: page,
      ),
    );
  }

  Future<bool> _loadWaterfallNavigationChapter(
    WaterfallController waterfall,
    int chapter,
  ) async {
    try {
      return await waterfall.navigate(chapter);
    } catch (e, stack) {
      if (!mounted || !identical(_waterfall, waterfall)) return false;
      widget.onNavigationError(chapter, e, stack);
      return false;
    }
  }

  Future<void> _navigateToWaterfallChapter(
    int chapter, {
    required bool toLastPage,
  }) async {
    final waterfall = _waterfall;
    final needsLoading = _segmentOfChapter(chapter) == null;
    final releaseLoading = _holdWaterfallLoading(needsLoading);
    _isRestoringPrependedSegmentPosition = false;
    _isNavigatingWaterfallLocation = false;
    final loading = _loadWaterfallNavigationChapter(waterfall, chapter);
    final revision = waterfall.revision;
    bool isCurrent() =>
        mounted &&
        identical(_waterfall, waterfall) &&
        revision == waterfall.revision;
    try {
      if (!await loading || !isCurrent()) {
        return;
      }
    } finally {
      if (isCurrent()) {
        releaseLoading();
      }
    }
    var segment = _segmentOfChapter(chapter);
    if (segment == null || segment.images.isEmpty) return;
    var page = toLastPage ? segment.images.length : 1;
    var index = _waterfallIndexOfChapterPage(chapter, page);
    if (index == null) return;
    var imageRef = _imageRefAt(index);
    if (imageRef == null) return;
    _isNavigatingWaterfallLocation = true;
    setState(() {
      _setReaderLocation(imageRef);
      navigation.setJumpToLastPage(false);
    });
    widget.onUpdate();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!isCurrent()) return;
      itemScrollController.jumpTo(index: index);
      _futurePosition = null;
      cacheImages(index);
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (isCurrent()) {
          _isNavigatingWaterfallLocation = false;
        }
      });
    });
  }

  @override
  void initState() {
    widget.onViewportChanged(this, true);
    _initSegments();
    itemPositionsListener.itemPositions.addListener(onPositionChanged);
    cached = List.filled(maxPage + 2, false);
    _initialCacheTimer = Timer(
      const Duration(milliseconds: 100),
      () => cacheImages(currentPage),
    );
    super.initState();
  }

  @override
  void didUpdateWidget(covariant ReaderContinuousView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.imageWork, widget.imageWork) ||
        !identical(oldWidget.navigation, widget.navigation) ||
        oldWidget.data.comicId != data.comicId ||
        oldWidget.data.sourceKey != data.sourceKey ||
        oldWidget.data.maxChapter != data.maxChapter ||
        oldWidget.data.crossChapter != data.crossChapter) {
      unawaited(_imageDownloads.dispose());
      _imageDownloads = ReaderImageDownloads(work: widget.imageWork);
      unawaited(_waterfall.dispose());
      _waterfall = _createWaterfall();
      _isRestoringPrependedSegmentPosition = false;
      _isNavigatingWaterfallLocation = false;
      _releaseWaterfallLoading?.call();
      _initSegments();
    }
    if (oldWidget.onViewportChanged != widget.onViewportChanged) {
      oldWidget.onViewportChanged(this, false);
      widget.onViewportChanged(this, true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _smoothGeneration++;
    _smoothPosition = null;
    _initialCacheTimer?.cancel();
    _scrollActivityTimer?.cancel();
    _scrollController?.removeListener(onScroll);
    _scrollController = null;
    widget.onViewportChanged(this, false);
    // A parent content reload may already have marked its replacement loading.
    // Retire this view's notification without publishing readiness on disposal.
    _releaseWaterfallLoading?.call(notify: false);
    unawaited(_waterfall.dispose());
    unawaited(_imageDownloads.dispose());
    itemPositionsListener.itemPositions.removeListener(onPositionChanged);
    photoViewController.dispose();
    super.dispose();
  }

  void onPositionChanged() {
    if (_disposed ||
        !mounted ||
        itemPositionsListener.itemPositions.value.isEmpty) {
      return;
    }
    var page = resolveFlowCurrentImageIndex(
      visibleIndex: itemPositionsListener.itemPositions.value.first.index,
      imageCount: _flowImageCount,
      isTopToBottom: data.vertical,
      isAtScrollEnd: _isAtScrollEnd,
    );
    var imageRef = _imageRefAt(page);
    if (imageRef == null) return;
    if (crossChapter) {
      if (_isRestoringPrependedSegmentPosition ||
          _isNavigatingWaterfallLocation) {
        return;
      }
      _setReaderLocation(imageRef);
      widget.onUpdate();
    } else if (page != currentPage) {
      navigation.reportPage(page);
      widget.onUpdate();
    }
    cacheImages(page);
    if (crossChapter) {
      _ensureWaterfallImagesBefore(page);
      _ensureWaterfallImagesAfter(page);
    }
  }

  bool get _isAtScrollEnd {
    final controller = _scrollController;
    if (controller == null || !controller.hasClients) {
      return false;
    }
    final position = controller.position;
    return position.pixels >= position.maxScrollExtent - 1;
  }

  @override
  bool get autoReadingReady {
    final controller = _scrollController;
    if (controller == null ||
        !controller.hasClients ||
        isZoomedIn ||
        fingers > 0 ||
        _isRestoringPrependedSegmentPosition ||
        _isNavigatingWaterfallLocation ||
        controller.position.isScrollingNotifier.value) {
      return false;
    }
    final visible = imageStates
        .whereType<ComicImageState>()
        .where((image) => image.visibleInReader)
        .toList();
    return visible.isNotEmpty &&
        visible.every((image) => image.readyForAutoReading);
  }

  @override
  AutoReadingStep autoScroll(double distance, {required bool acrossChapters}) {
    if (!autoReadingReady) return AutoReadingStep.waiting;
    final position = scrollController.position;
    final lastIndex = crossChapter && !acrossChapters
        ? _waterfallIndexOfChapterPage(currentChapter, maxPage)!
        : _flowImageCount;
    final last = itemPositionsListener.itemPositions.value
        .where((item) => item.index == lastIndex)
        .firstOrNull;
    var available = position.maxScrollExtent - position.pixels;
    if (last != null) {
      available = math.min(
        available,
        math.max(0.0, (last.itemTrailingEdge - 1) * position.viewportDimension),
      );
      if (last.itemTrailingEdge <= 1.001) {
        if (crossChapter &&
            acrossChapters &&
            _waterfallFlow.lastChapter! < data.maxChapter) {
          if (_waterfall.afterError != null) return AutoReadingStep.finished;
          _ensureWaterfallImagesAfter(_flowImageCount);
          return AutoReadingStep.waiting;
        }
        if (!crossChapter &&
            acrossChapters &&
            currentChapter < data.maxChapter) {
          navigation.toChapter(currentChapter + 1);
          return AutoReadingStep.waiting;
        }
        return AutoReadingStep.finished;
      }
    }
    if (available <= 0) return AutoReadingStep.waiting;
    _futurePosition = null;
    scrollController.jumpTo(position.pixels + math.min(distance, available));
    return AutoReadingStep.advanced;
  }

  double? _futurePosition;

  void smoothTo(double offset) {
    final original = _scrollController;
    if (_disposed ||
        !mounted ||
        original == null ||
        original.positions.length != 1 ||
        HardwareKeyboard.instance.isShiftPressed) {
      return;
    }
    final position = original.position;
    if (!position.hasPixels || !position.hasContentDimensions) return;
    if (!identical(_smoothPosition, position)) {
      _smoothPosition = position;
      _futurePosition = null;
    }
    var currentLocation = position.pixels;
    var old = _futurePosition;
    _futurePosition ??= currentLocation;
    double k = (_futurePosition! - currentLocation).abs() / 1600 + 1;
    final customSpeed = data.scrollSpeed;
    k *= customSpeed;
    _futurePosition = _futurePosition! + offset * k;
    var beforeOffset = (_futurePosition! - currentLocation).abs();
    _futurePosition = _futurePosition!.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    var afterOffset = (_futurePosition! - currentLocation).abs();
    if (_futurePosition == old) return;
    var target = _futurePosition!;
    var duration = const Duration(milliseconds: 160);
    if (afterOffset < beforeOffset) {
      duration = duration * (afterOffset / beforeOffset);
      if (duration < Duration(milliseconds: 10)) {
        duration = Duration(milliseconds: 10);
      }
    }
    final generation = ++_smoothGeneration;
    original
        .animateTo(_futurePosition!, duration: duration, curve: Curves.linear)
        .then((_) {
          if (_disposed ||
              !mounted ||
              generation != _smoothGeneration ||
              !identical(_scrollController, original) ||
              original.positions.length != 1 ||
              !identical(original.position, position)) {
            return;
          }
          var current = position.pixels;
          if (current == target && current == _futurePosition) {
            _futurePosition = null;
          }
        });
  }

  void onPointerSignal(PointerSignalEvent event) {
    if (_disposed || !mounted) return;
    if (event is PointerScrollEvent) {
      if (!_isMouseScrolling) {
        setState(() {
          _isMouseScrolling = true;
        });
      }
      if (isCTRLPressed) {
        return;
      }
      smoothTo(event.scrollDelta.dy);
    }
  }

  void _predownload(WaterfallImageRef image) {
    if (image.imageKey.startsWith('file://')) return;
    _imageDownloads.preload(
      image.imageKey,
      data.sourceKey,
      data.comicId,
      image.position.chapterId,
    );
  }

  void cacheImages(int current) {
    if (!mounted) return;
    for (int i = current + 1; i <= current + preCacheCount; i++) {
      if (crossChapter) {
        var imageRef = _imageRefAt(i);
        if (imageRef == null) continue;
        var segment = _segmentOfChapter(imageRef.position.chapter);
        if (segment != null &&
            !segment.cached.contains(imageRef.position.imageNumber)) {
          _predownload(imageRef);
          segment.cached.add(imageRef.position.imageNumber);
        }
      } else if (i <= maxPage && !cached[i]) {
        _predownload(_imageRefAt(i)!);
        cached[i] = true;
      }
    }
  }

  Widget _buildFlowEnd(BuildContext context) {
    if (!crossChapter) return const SizedBox();
    if (_waterfall.loadingAfter) {
      return SizedBox(
        height: 96,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text('Loading next chapter'.tl),
            ],
          ),
        ),
      );
    }
    if (_waterfall.afterError != null) {
      return ClickInkWell(
        onTap: () {
          _waterfall.retryAfter();
          _ensureWaterfallImagesAfter(_flowImageCount);
        },
        child: SizedBox(
          height: 120,
          child: Center(
            child: Text(
              '${'Failed to load next chapter'.tl}\n${'Tap to retry'.tl}',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    var lastChapter = !_waterfallFlow.isEmpty
        ? _waterfallFlow.lastChapter!
        : currentChapter;
    if (lastChapter >= data.maxChapter) {
      return SizedBox(
        height: 96,
        child: Center(child: Text('No more chapters'.tl)),
      );
    }
    return const SizedBox(height: 48);
  }

  String _chapterTitle(int chapter) {
    return widget.chapterTitle(chapter);
  }

  Widget _buildChapterDivider(
    BuildContext context,
    WaterfallImageRef imageRef,
  ) {
    if (!crossChapter || !imageRef.isFirstInSegment) {
      return const SizedBox();
    }
    var isInitialChapter =
        imageRef.position.chapter == _waterfallFlow.firstChapter;
    if (isInitialChapter) return const SizedBox();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.colorScheme.surfaceContainerHighest.toOpacity(0.72),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: context.colorScheme.outlineVariant.toOpacity(0.7),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Text(
              'Continue to @chapter'.tlParams({
                'chapter': _chapterTitle(imageRef.position.chapter),
              }),
              style: TextStyle(
                color: context.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void onScroll() {
    if (_disposed || !mounted || _scrollController?.hasClients != true) return;
    if (prepareToPrevChapter) {
      jumpToNextChapter = false;
      jumpToPrevChapter =
          scrollController.offset <
          scrollController.position.minScrollExtent - chapterSwipeThreshold;
    } else if (prepareToNextChapter) {
      jumpToNextChapter =
          scrollController.offset >
          scrollController.position.maxScrollExtent + chapterSwipeThreshold;
      jumpToPrevChapter = false;
    }
  }

  bool onScaleUpdate([double? scale]) {
    if (_disposed || !mounted) return true;
    if (prepareToNextChapter || prepareToPrevChapter) {
      setState(() {
        prepareToPrevChapter = false;
        prepareToNextChapter = false;
      });
      widget.onFloatingButton(0);
    }
    var isZoomedIn = (scale ?? photoViewController.scale) != 1.0;
    if (isZoomedIn != this.isZoomedIn) {
      setState(() {
        this.isZoomedIn = isZoomedIn;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    Widget widget = ScrollablePositionedList.builder(
      initialScrollIndex: currentPage,
      itemScrollController: itemScrollController,
      itemPositionsListener: itemPositionsListener,
      scrollControllerCallback: (scrollController) {
        if (_disposed || !mounted) return;
        if (identical(_scrollController, scrollController)) return;
        if (_scrollController != null) {
          _scrollController!.removeListener(onScroll);
        }
        _scrollController = scrollController;
        _smoothPosition = null;
        _smoothGeneration++;
        _futurePosition = null;
        _scrollController!.addListener(onScroll);
      },
      itemCount: _flowItemCount,
      addSemanticIndexes: false,
      scrollDirection: data.vertical ? Axis.vertical : Axis.horizontal,
      reverse: data.reverse,
      physics: isCTRLPressed || _isMouseScrolling || disableScroll
          ? const NeverScrollableScrollPhysics()
          : isZoomedIn
          ? const ClampingScrollPhysics()
          : const BouncingScrollPhysics(),
      itemBuilder: (context, index) {
        if (index == 0) {
          return const SizedBox();
        }
        if (index == _flowImageCount + 1) {
          return _buildFlowEnd(context);
        }
        var imageRef = _imageRefAt(index);
        if (imageRef == null) {
          return const SizedBox();
        }
        double? width, height;
        if (!data.vertical) {
          height = double.infinity;
        } else {
          width = double.infinity;
        }

        final image = ReaderImageProvider(
          imageRef.imageKey,
          data.sourceKey,
          data.comicId,
          imageRef.position.chapterId,
          imageRef.position.imageNumber,
          enableResize: true,
        );

        var comicImage = ComicImage(
          filterQuality: FilterQuality.medium,
          image: ReaderDisplayImageProvider(image, this.widget.imageWork),
          width: width,
          height: height,
          fit: BoxFit.contain,
          splitWideImage: _splitWideImages,
          splitWideImageInvert: _splitWideImagesInvert,
          onInit: (state) => imageStates.add(state),
          onDispose: (state) => imageStates.remove(state),
        );

        return ColoredBox(
          color: context.colorScheme.surface,
          child: data.vertical
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildChapterDivider(context, imageRef),
                    comicImage,
                  ],
                )
              : comicImage,
        );
      },
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        scrollbars: false,
        dragDevices: _kTouchLikeDeviceTypes,
      ),
    );

    widget = Stack(
      children: [
        Positioned.fill(child: buildBackground(context)),
        Positioned.fill(child: widget),
      ],
    );

    widget = Listener(
      onPointerDown: (event) {
        fingers++;
        if (fingers > 1 && !disableScroll) {
          setState(() {
            disableScroll = true;
          });
        }
        _futurePosition = null;
        if (_isMouseScrolling) {
          setState(() {
            _isMouseScrolling = false;
          });
        }
      },
      onPointerUp: (event) {
        fingers--;
        if (fingers <= 1 && disableScroll) {
          setState(() {
            disableScroll = false;
          });
        }
        if (fingers == 0) {
          if (jumpToPrevChapter) {
            this.widget.onFloatingButton(0);
            navigation.toChapter(currentChapter - 1, toLastPage: true);
          } else if (jumpToNextChapter) {
            this.widget.onFloatingButton(0);
            navigation.toChapter(currentChapter + 1);
          }
        }
      },
      onPointerCancel: (event) {
        fingers--;
        if (fingers <= 1 && disableScroll) {
          setState(() {
            disableScroll = false;
          });
        }
      },
      onPointerPanZoomUpdate: (event) {
        if (event.scale == 1.0) {
          smoothTo(0 - event.panDelta.dy);
        }
      },
      onPointerMove: (event) {
        Offset value = event.delta;
        if (photoViewController.scale == 1 || fingers != 1) {
          return;
        }
        Offset offset;
        var sp = scrollController.position;
        if (sp.pixels <= sp.minScrollExtent ||
            sp.pixels >= sp.maxScrollExtent) {
          offset = Offset(value.dx, value.dy);
        } else {
          if (data.vertical) {
            offset = Offset(value.dx, 0);
          } else {
            offset = Offset(0, value.dy);
          }
        }
        if (isLongPressing) {
          offset += value;
        }
        photoViewController.updateMultiple(
          position: photoViewController.position + offset,
        );
      },
      onPointerSignal: onPointerSignal,
      child: widget,
    );

    widget = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification) {
          delayedSetIsScrolling(true);
        } else if (notification is ScrollEndNotification) {
          delayedSetIsScrolling(false);
        }

        var scale = photoViewController.scale ?? 1.0;

        if (notification is ScrollUpdateNotification &&
            (scale - 1).abs() < 0.05) {
          if (!scrollController.hasClients) return false;
          if (scrollController.position.pixels <=
                  scrollController.position.minScrollExtent &&
              !data.firstChapter &&
              !crossChapter) {
            if (!prepareToPrevChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              this.widget.onFloatingButton(-1);
              setState(() {
                prepareToPrevChapter = true;
              });
            }
          } else if (scrollController.position.pixels >=
                  scrollController.position.maxScrollExtent &&
              !data.lastChapter &&
              !crossChapter) {
            if (!prepareToNextChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              this.widget.onFloatingButton(1);
              setState(() {
                prepareToNextChapter = true;
              });
            }
          } else {
            this.widget.onFloatingButton(0);
            if (prepareToPrevChapter || prepareToNextChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              setState(() {
                prepareToPrevChapter = false;
                prepareToNextChapter = false;
              });
            }
          }
        }

        return true;
      },
      child: widget,
    );
    var width = this.widget.readerSize().width;
    var height = this.widget.readerSize().height;
    if (data.limitImageWidth && width / height > 0.7 && data.vertical) {
      width = height * 0.7;
    }
    if (data.vertical) {
      final margin = data.sideMargin;
      final percent = margin;
      // Resize the flow itself so images retain their aspect ratio and scroll
      // extents match the visible content, including waterfall and auto-reading.
      width *= 1 - percent * 2 / 100;
    }

    return PhotoView.customChild(
      backgroundDecoration: BoxDecoration(color: context.colorScheme.surface),
      childSize: Size(width, height),
      minScale: 1.0,
      maxScale: 2.5,
      strictScale: true,
      controller: photoViewController,
      onScaleUpdate: onScaleUpdate,
      child: SizedBox(width: width, height: height, child: widget),
    );
  }

  Widget buildBackground(BuildContext context) {
    return Column(
      children: [
        SizedBox(height: context.padding.top + 16),
        if (prepareToPrevChapter)
          ChapterSwipeIndicator(controller: scrollController, isPrev: true),
        const Spacer(),
        if (prepareToNextChapter)
          ChapterSwipeIndicator(controller: scrollController, isPrev: false),
        SizedBox(height: 36),
      ],
    );
  }

  @override
  Future<void> animateToPage(int page) {
    if (_disposed || !mounted) return Future.value();
    var index = _waterfallIndexOfChapterPage(currentChapter, page) ?? page;
    return itemScrollController.scrollTo(
      index: index,
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
  }

  @override
  void handleDoubleTap(Offset location) {
    if (_disposed || !mounted) return;
    if (data.doubleTapCollect) {
      widget.onCollectImage();
      return;
    }
    final initial = photoViewController.getInitialScale?.call();
    if (initial == null) return;
    double target;
    if (photoViewController.scale != initial) {
      target = initial;
    } else {
      target = initial * 1.75;
    }
    var size = MediaQuery.of(context).size;
    photoViewController.animateScale?.call(
      target,
      Offset(size.width / 2 - location.dx, size.height / 2 - location.dy),
    );
    onScaleUpdate(target);
  }

  @override
  void handleLongPressDown(Offset location) {
    if (_disposed || !mounted) return;
    if (delayedIsScrolling) {
      return;
    }
    final initial = photoViewController.getInitialScale?.call();
    if (initial == null) return;
    final target = initial * 1.75;
    var size = widget.readerSize();
    Offset zoomPosition;
    if (!data.centerLongPressZoom) {
      zoomPosition = Offset(
        size.width / 2 - location.dx,
        size.height / 2 - location.dy,
      );
    } else {
      zoomPosition = Offset(0, 0);
    }
    photoViewController.animateScale?.call(target, zoomPosition);
    onScaleUpdate(target);
    isLongPressing = true;
  }

  @override
  void handleLongPressUp(Offset location) {
    if (_disposed || !mounted) return;
    if (!isLongPressing) {
      return;
    }
    final target = photoViewController.getInitialScale?.call();
    isLongPressing = false;
    if (target == null) return;
    photoViewController.animateScale?.call(target);
    onScaleUpdate(target);
  }

  @override
  void toPage(int page) {
    if (_disposed || !mounted) return;
    var index = _waterfallIndexOfChapterPage(currentChapter, page) ?? page;
    itemScrollController.jumpTo(index: index);
    _futurePosition = null;
  }

  @override
  bool toChapter(int chapter, {bool toLastPage = false}) {
    if (_disposed || !mounted) return false;
    if (!crossChapter) return false;
    _navigateToWaterfallChapter(chapter, toLastPage: toLastPage);
    return true;
  }

  @override
  void cancelKeyboardInput() {
    if (!_disposed && mounted && isCTRLPressed) {
      setState(() => isCTRLPressed = false);
    }
  }

  @override
  void handleKeyEvent(KeyEvent event) {
    if (_disposed || !mounted) return;
    if (event.logicalKey == LogicalKeyboardKey.controlLeft ||
        event.logicalKey == LogicalKeyboardKey.controlRight) {
      setState(() {
        if (event is KeyDownEvent) {
          isCTRLPressed = true;
        } else if (event is KeyUpEvent) {
          isCTRLPressed = false;
        }
      });
    }
    if (event is KeyUpEvent) {
      return;
    }
    bool? forward;
    if ((!data.vertical && !data.reverse) &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = true;
    } else if (data.reverse &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = true;
    } else if (data.vertical &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      forward = true;
    } else if (data.vertical &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      forward = false;
    } else if ((!data.vertical && !data.reverse) &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = false;
    } else if (data.reverse &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = false;
    }
    if (forward == true) {
      scrollController.animateTo(
        scrollController.offset + context.height * 0.25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    } else if (forward == false) {
      scrollController.animateTo(
        scrollController.offset - context.height * 0.25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    }
  }

  @override
  bool handleOnTap(Offset location) {
    if (delayedIsScrolling) {
      return true;
    }
    return false;
  }

  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async {
    final image = _imageAt(offset);
    if (image == null) return null;
    return widget.readImage(
      ReaderImageAddress(
        imageKey: image.imageKey,
        sourceKey: image.sourceKey,
        comicId: image.cid,
        chapterId: image.eid,
      ),
    );
  }

  @override
  int? getImageIndexByOffset(Offset offset) {
    final image = _imageAt(offset);
    if (image == null || image.eid != widget.chapterId(currentChapter)) {
      return null;
    }
    final index = image.page - 1;
    return index >= 0 &&
            index < images.length &&
            images[index] == image.imageKey
        ? index
        : null;
  }

  ReaderImageProvider? _imageAt(Offset offset) {
    if (_disposed || !mounted) return null;
    for (var imageState in imageStates) {
      if ((imageState as ComicImageState).containsPoint(offset)) {
        final image =
            (imageState.widget.image as ReaderDisplayImageProvider).image;
        if (image.cid == data.comicId && image.sourceKey == data.sourceKey) {
          return image;
        }
      }
    }
    return null;
  }
}
