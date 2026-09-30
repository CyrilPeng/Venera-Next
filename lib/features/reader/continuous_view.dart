import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/features/reader/chapter_loader.dart';
import 'package:venera_next/features/reader/image_downloads.dart';
import 'package:venera_next/features/reader/image_position.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/features/reader/waterfall_flow.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';
import 'package:venera_next/features/reader/waterfall_controller.dart';

import 'image_view_support.dart';
import 'chapter_swipe_indicator.dart';

const Set<PointerDeviceKind> _kTouchLikeDeviceTypes = <PointerDeviceKind>{
  PointerDeviceKind.touch,
  PointerDeviceKind.mouse,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.unknown,
};

class ReaderContinuousView extends StatefulWidget {
  const ReaderContinuousView({super.key, this.crossChapter = false});

  final bool crossChapter;

  @override
  State<ReaderContinuousView> createState() => ContinuousModeState();
}

class ContinuousModeState extends State<ReaderContinuousView>
    implements ReaderImageViewController, AutoReadingViewport {
  final _imageDownloads = ReaderImageDownloads();

  @override
  (int, int)? get currentImageRange => (reader.page - 1, reader.page);

  late ReaderState reader;

  var itemScrollController = ItemScrollController();
  var itemPositionsListener = ItemPositionsListener.create();
  var photoViewController = PhotoViewController();
  ScrollController? _scrollController;

  ScrollController get scrollController => _scrollController!;

  var isCTRLPressed = false;
  static var _isMouseScrolling = false;
  var fingers = 0;
  bool disableScroll = false;

  late List<bool> cached;

  late final _waterfall = WaterfallController(
    maxChapter: reader.maxChapter,
    load: (chapter, scope) => loadReaderChapterImages(
      scope: scope,
      comicId: reader.cid,
      type: reader.type,
      chapter: chapter,
      chapters: reader.widget.chapters,
      onOnlineFallback: reader.onLocalChapterRecoveredOnline,
    ),
    chapterId: (chapter) =>
        reader.widget.chapters?.ids.elementAtOrNull(chapter - 1) ?? '0',
    onChanged: () {
      if (mounted) setState(() {});
    },
    onPreviousError: (error, stack) =>
        Log.error('Reader', 'Failed to load previous chapter: $error', stack),
  );
  WaterfallFlowView get _waterfallFlow => _waterfall.flow;

  bool _isRestoringPrependedSegmentPosition = false;

  bool _isNavigatingWaterfallLocation = false;

  int get preCacheCount =>
      appdata.settings.globalReaderSettings.preloadImageCount;

  /// Whether the user was scrolling the page.
  /// The gesture detector has a delay to detect tap event.
  /// To handle the tap event, we need to know if the user was scrolling before the delay.
  bool delayedIsScrolling = false;

  var imageStates = <State<ComicImage>>{};

  void delayedSetIsScrolling(bool value) {
    Future.delayed(
      const Duration(milliseconds: 300),
      () => delayedIsScrolling = value,
    );
  }

  bool prepareToPrevChapter = false;
  bool prepareToNextChapter = false;
  bool jumpToNextChapter = false;
  bool jumpToPrevChapter = false;

  bool isZoomedIn = false;
  bool isLongPressing = false;

  bool get crossChapter => widget.crossChapter;

  bool get _splitWideImages =>
      reader.mode.isTopToBottom && reader.preferences.splitDualPage == true;

  bool get _splitWideImagesInvert =>
      reader.preferences.splitDualPageInvert == true;

  int get _flowImageCount =>
      crossChapter ? _waterfallFlow.imageCount : reader.maxPage;

  int get _flowItemCount => _flowImageCount + 2;

  void _initSegments() {
    if (!crossChapter || !_waterfallFlow.isEmpty || reader.images == null) {
      return;
    }
    _waterfall.initialize(
      WaterfallChapterSegment(
        chapter: reader.chapter,
        eid: reader.eid,
        images: reader.images!,
      ),
    );
  }

  WaterfallChapterSegment? _segmentOfChapter(int chapter) {
    return _waterfallFlow.segmentOfChapter(chapter);
  }

  WaterfallImageRef? _imageRefAt(int index) {
    if (!crossChapter) {
      if (index <= 0 || index > reader.images!.length) return null;
      return WaterfallImageRef(
        position: ReaderImagePosition(
          chapter: reader.chapter,
          imageNumber: index,
          chapterId: reader.eid,
        ),
        imageKey: reader.images![index - 1],
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
    final revision = _waterfall.revision;
    final insertedCount = await _waterfall.ensureBefore(
      current: current,
      threshold: math.max(preCacheCount, 1),
    );
    if (!mounted || revision != _waterfall.revision || insertedCount == 0) {
      return;
    }
    _isRestoringPrependedSegmentPosition = true;
    setState(() {});
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _waterfall.revision) return;
      itemScrollController.jumpTo(index: current + insertedCount);
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && revision == _waterfall.revision) {
          _isRestoringPrependedSegmentPosition = false;
        }
      });
    });
  }

  void _setReaderLocation(WaterfallImageRef imageRef) {
    var segment = _segmentOfChapter(imageRef.position.chapter);
    var chapterChanged = reader.chapter != imageRef.position.chapter;
    if (segment != null && chapterChanged) {
      reader.controller.restoreChapter(imageRef.position.chapter);
      reader.controller.replaceChapterImages(segment.images);
      // Wait until the scroll/layout callback has finished before updating UI.
      Future.microtask(() {
        if (mounted) reader.detectLayout();
      });
    }
    if (chapterChanged || reader.page != imageRef.position.imageNumber) {
      reader.setPage(imageRef.position.imageNumber);
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

  Future<bool> _loadWaterfallNavigationChapter(int chapter) async {
    try {
      return await _waterfall.navigate(chapter);
    } catch (e) {
      if (!mounted) return false;
      Log.error("Reader", "Failed to load chapter $chapter", e);
      context.showMessage(message: e.toString());
      return false;
    }
  }

  Future<void> _navigateToWaterfallChapter(
    int chapter, {
    required bool toLastPage,
  }) async {
    final needsLoading = _segmentOfChapter(chapter) == null;
    if (needsLoading) reader.onReaderContentLoading();
    _isRestoringPrependedSegmentPosition = false;
    _isNavigatingWaterfallLocation = false;
    final loading = _loadWaterfallNavigationChapter(chapter);
    final revision = _waterfall.revision;
    try {
      if (!await loading || !mounted || revision != _waterfall.revision) {
        return;
      }
    } finally {
      if (mounted && revision == _waterfall.revision) {
        reader.onReaderContentReady();
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
      reader.controller.setJumpToLastPage(false);
    });
    context.readerScaffold.update();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _waterfall.revision) return;
      itemScrollController.jumpTo(index: index);
      _futurePosition = null;
      cacheImages(index);
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && revision == _waterfall.revision) {
          _isNavigatingWaterfallLocation = false;
        }
      });
    });
  }

  @override
  void initState() {
    reader = context.reader;
    reader.imageViewController = this;
    _initSegments();
    itemPositionsListener.itemPositions.addListener(onPositionChanged);
    cached = List.filled(reader.maxPage + 2, false);
    Future.delayed(
      const Duration(milliseconds: 100),
      () => cacheImages(reader.page),
    );
    super.initState();
  }

  @override
  void dispose() {
    _waterfall.dispose();
    unawaited(_imageDownloads.dispose());
    itemPositionsListener.itemPositions.removeListener(onPositionChanged);
    super.dispose();
  }

  void onPositionChanged() {
    if (itemPositionsListener.itemPositions.value.isEmpty) {
      return;
    }
    var page = resolveFlowCurrentImageIndex(
      visibleIndex: itemPositionsListener.itemPositions.value.first.index,
      imageCount: _flowImageCount,
      isTopToBottom: reader.mode.isTopToBottom,
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
      context.readerScaffold.update();
    } else if (page != reader.page) {
      reader.setPage(page);
      context.readerScaffold.update();
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
        ? _waterfallIndexOfChapterPage(reader.chapter, reader.maxPage)!
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
            _waterfallFlow.lastChapter! < reader.maxChapter) {
          if (_waterfall.afterError != null) return AutoReadingStep.finished;
          _ensureWaterfallImagesAfter(_flowImageCount);
          return AutoReadingStep.waiting;
        }
        if (!crossChapter &&
            acrossChapters &&
            reader.chapter < reader.maxChapter) {
          reader.toNextChapter();
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
    if (HardwareKeyboard.instance.isShiftPressed) {
      return;
    }
    var currentLocation = scrollController.position.pixels;
    var old = _futurePosition;
    _futurePosition ??= currentLocation;
    double k = (_futurePosition! - currentLocation).abs() / 1600 + 1;
    final customSpeed = context.reader.preferences.readerScrollSpeed;
    k *= customSpeed;
    _futurePosition = _futurePosition! + offset * k;
    var beforeOffset = (_futurePosition! - currentLocation).abs();
    _futurePosition = _futurePosition!.clamp(
      scrollController.position.minScrollExtent,
      scrollController.position.maxScrollExtent,
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
    scrollController
        .animateTo(_futurePosition!, duration: duration, curve: Curves.linear)
        .then((_) {
          var current = scrollController.position.pixels;
          if (current == target && current == _futurePosition) {
            _futurePosition = null;
          }
        });
  }

  void onPointerSignal(PointerSignalEvent event) {
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

  void cacheImages(int current) {
    if (!mounted) return;
    for (int i = current + 1; i <= current + preCacheCount; i++) {
      if (crossChapter) {
        var imageRef = _imageRefAt(i);
        if (imageRef == null) continue;
        var segment = _segmentOfChapter(imageRef.position.chapter);
        if (segment != null &&
            !segment.cached.contains(imageRef.position.imageNumber)) {
          predownloadReaderImageRef(imageRef, context, _imageDownloads);
          segment.cached.add(imageRef.position.imageNumber);
        }
      } else if (i <= reader.maxPage && !cached[i]) {
        predownloadReaderImage(i, context, _imageDownloads);
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
        : reader.chapter;
    if (lastChapter >= reader.maxChapter) {
      return SizedBox(
        height: 96,
        child: Center(child: Text('No more chapters'.tl)),
      );
    }
    return const SizedBox(height: 48);
  }

  String _chapterTitle(int chapter) {
    return reader.widget.chapters?.titles.elementAtOrNull(chapter - 1) ??
        '${'Chapter'.tl} $chapter';
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
    if (prepareToNextChapter || prepareToPrevChapter) {
      setState(() {
        prepareToPrevChapter = false;
        prepareToNextChapter = false;
      });
      context.readerScaffold.setFloatingButton(0);
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
      initialScrollIndex: reader.page,
      itemScrollController: itemScrollController,
      itemPositionsListener: itemPositionsListener,
      scrollControllerCallback: (scrollController) {
        if (_scrollController != null) {
          _scrollController!.removeListener(onScroll);
        }
        _scrollController = scrollController;
        _scrollController!.addListener(onScroll);
      },
      itemCount: _flowItemCount,
      addSemanticIndexes: false,
      scrollDirection: reader.mode.isTopToBottom
          ? Axis.vertical
          : Axis.horizontal,
      reverse: reader.mode == ReaderMode.continuousRightToLeft,
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
        if (reader.mode == ReaderMode.continuousLeftToRight ||
            reader.mode == ReaderMode.continuousRightToLeft) {
          height = double.infinity;
        } else {
          width = double.infinity;
        }

        ImageProvider image = createReaderImageProviderFromRef(
          imageRef,
          context,
        );

        var comicImage = ComicImage(
          filterQuality: FilterQuality.medium,
          image: image,
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
          child: reader.mode.isTopToBottom
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
            context.readerScaffold.setFloatingButton(0);
            reader.toPrevChapter(toLastPage: true);
          } else if (jumpToNextChapter) {
            context.readerScaffold.setFloatingButton(0);
            reader.toNextChapter();
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
          if (reader.mode.isTopToBottom) {
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
              !reader.isFirstChapterOfGroup &&
              !crossChapter) {
            if (!prepareToPrevChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              context.readerScaffold.setFloatingButton(-1);
              setState(() {
                prepareToPrevChapter = true;
              });
            }
          } else if (scrollController.position.pixels >=
                  scrollController.position.maxScrollExtent &&
              !reader.isLastChapterOfGroup &&
              !crossChapter) {
            if (!prepareToNextChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              context.readerScaffold.setFloatingButton(1);
              setState(() {
                prepareToNextChapter = true;
              });
            }
          } else {
            context.readerScaffold.setFloatingButton(0);
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
    var width = reader.size.width;
    var height = reader.size.height;
    if (reader.preferences.limitImageWidth == true &&
        width / height > 0.7 &&
        reader.mode.isTopToBottom) {
      width = height * 0.7;
    }
    if (reader.mode.isTopToBottom) {
      final margin = reader.preferences.readerSideMargin;
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
    var index = _waterfallIndexOfChapterPage(reader.chapter, page) ?? page;
    return itemScrollController.scrollTo(
      index: index,
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
  }

  @override
  void handleDoubleTap(Offset location) {
    if (appdata.settings.globalReaderSettings.quickCollectImage ==
        'DoubleTap') {
      context.readerScaffold.addImageFavorite();
      return;
    }
    double target;
    if (photoViewController.scale !=
        photoViewController.getInitialScale?.call()) {
      target = photoViewController.getInitialScale!.call()!;
    } else {
      target = photoViewController.getInitialScale!.call()! * 1.75;
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
    if (delayedIsScrolling) {
      return;
    }
    double target = photoViewController.getInitialScale!.call()! * 1.75;
    var size = reader.size;
    Offset zoomPosition;
    if (reader.preferences.longPressZoomPosition != 'center') {
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
    if (!isLongPressing) {
      return;
    }
    double target = photoViewController.getInitialScale!.call()!;
    photoViewController.animateScale?.call(target);
    onScaleUpdate(target);
    isLongPressing = false;
  }

  @override
  void toPage(int page) {
    var index = _waterfallIndexOfChapterPage(reader.chapter, page) ?? page;
    itemScrollController.jumpTo(index: index);
    _futurePosition = null;
  }

  @override
  bool toChapter(int chapter, {bool toLastPage = false}) {
    if (!crossChapter) return false;
    _navigateToWaterfallChapter(chapter, toLastPage: toLastPage);
    return true;
  }

  @override
  void handleKeyEvent(KeyEvent event) {
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
    if (reader.mode == ReaderMode.continuousLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = true;
    } else if (reader.mode.isTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      forward = true;
    } else if (reader.mode.isTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      forward = false;
    } else if (reader.mode == ReaderMode.continuousLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = false;
    } else if (reader.mode == ReaderMode.continuousRightToLeft &&
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
    var imageKey = getImageKeyByOffset(offset);
    if (imageKey == null) return null;
    if (imageKey.startsWith("file://")) {
      return await File(imageKey.substring(7)).readAsBytes();
    } else {
      return (await CacheManager().findCache(
        "$imageKey@${context.reader.type.sourceKey}@${context.reader.cid}@${context.reader.eid}",
      ))!.readAsBytes();
    }
  }

  @override
  String? getImageKeyByOffset(Offset offset) {
    String? imageKey;
    for (var imageState in imageStates) {
      if ((imageState as ComicImageState).containsPoint(offset)) {
        imageKey = (imageState.widget.image as ReaderImageProvider).imageKey;
      }
    }
    return imageKey;
  }
}
