import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/features/reader/image_downloads.dart';
import 'package:venera_next/features/reader/image_precache.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';

import 'gallery_data.dart';
import 'display_image_provider.dart';
import 'image_position.dart';
import 'reader_controller.dart';
import 'reader_viewport.dart';

class ReaderGalleryView extends StatefulWidget {
  const ReaderGalleryView({
    super.key,
    required this.data,
    required this.imageWork,
    required this.navigation,
    required this.onViewportChanged,
    required this.onReady,
    required this.onPageReported,
    required this.onChapterChanged,
    required this.onCollectImage,
    required this.readerSize,
    required this.readImage,
    this.commentsBuilder,
  });

  final ReaderGalleryData data;
  final ImageWork imageWork;
  final ReaderController navigation;
  final void Function(ReaderImageViewController viewport, bool attached)
  onViewportChanged;
  final VoidCallback onReady;
  final void Function(bool comments, bool refreshEInk) onPageReported;
  final VoidCallback onChapterChanged;
  final VoidCallback onCollectImage;
  final Size Function() readerSize;
  final Future<Uint8List?> Function(ReaderImageAddress image) readImage;
  final WidgetBuilder? commentsBuilder;

  @override
  State<ReaderGalleryView> createState() => GalleryModeState();
}

class GalleryModeState extends State<ReaderGalleryView>
    implements ReaderImageViewController, AutoReadingViewport {
  late var _imageDownloads = ReaderImageDownloads(work: widget.imageWork);
  late var _imagePrecache = ReaderImagePrecache(work: widget.imageWork);

  late PageController controller;

  ReaderGalleryData get data => widget.data;
  ReaderController get navigation => widget.navigation;
  int get page => navigation.state.page;
  int get preCacheCount => data.preloadCount;
  final photoViewControllers = <int, PhotoViewController>{};
  int get totalPages => data.totalPages;
  bool isChapterCommentsPage(int pageIndex) => data.isCommentsPage(pageIndex);

  // Preserve the legacy gallery contract: image processing receives the current
  // display page, including for prefetch, rather than the source image index.
  ReaderImageProvider _imageProvider(String key) => ReaderImageProvider(
    key,
    data.sourceKey,
    data.comicId,
    data.chapterId,
    page,
  );

  ReaderDisplayImageProvider _displayImage(String key) =>
      ReaderDisplayImageProvider(_imageProvider(key), widget.imageWork);

  final imageStates = <State<ComicImage>, int>{};

  bool isLongPressing = false;
  bool _disposed = false;
  PhotoViewController? _longPressController;

  int fingers = 0;

  @override
  void initState() {
    controller = PageController(initialPage: page);
    widget.onViewportChanged(this, true);
    Future.microtask(() {
      if (mounted) widget.onReady();
    });
    super.initState();
  }

  @override
  void didUpdateWidget(covariant ReaderGalleryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.imageWork, widget.imageWork)) {
      unawaited(_imageDownloads.dispose());
      unawaited(_imagePrecache.dispose());
      _imageDownloads = ReaderImageDownloads(work: widget.imageWork);
      _imagePrecache = ReaderImagePrecache(work: widget.imageWork);
    }
    if (oldWidget.onViewportChanged != widget.onViewportChanged) {
      oldWidget.onViewportChanged(this, false);
      widget.onViewportChanged(this, true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _longPressController = null;
    widget.onViewportChanged(this, false);
    keyRepeatTimer?.cancel();
    controller.dispose();
    unawaited(_imagePrecache.dispose());
    unawaited(_imageDownloads.dispose());
    super.dispose();
  }

  @override
  bool get autoReadingReady {
    if (_disposed ||
        !mounted ||
        !controller.hasClients ||
        fingers > 0 ||
        isLongPressing ||
        controller.position.isScrollingNotifier.value) {
      return false;
    }
    if (data.isCommentsPage(page)) return true;
    final photo = photoViewControllers[page];
    final initialScale = photo?.getInitialScale?.call();
    // PhotoView installs this callback only after its image is decoded.
    if (initialScale == null ||
        ((photo?.scale ?? initialScale) - initialScale).abs() > 0.01) {
      return false;
    }
    final (start, end) = getPageImagesRange(page);
    if (end - start == 1) return true;
    final visible = imageStates.keys
        .whereType<ComicImageState>()
        .where((image) => image.visibleInReader)
        .toList();
    return visible.isNotEmpty &&
        visible.every((image) => image.readyForAutoReading);
  }

  @override
  AutoReadingStep autoScroll(double distance, {required bool acrossChapters}) =>
      AutoReadingStep.finished;

  /// Get the range of images for the given page. [page] is 1-based.
  (int start, int end) getPageImagesRange(int page) =>
      data.layout.imageRange(page, data.images.length);

  /// Get the image indices for current page. Returns null if no images.
  /// Returns a single index if only one image, or a range if multiple images.
  @override
  (int, int)? get currentImageRange {
    if (data.images.isEmpty) {
      return null;
    }
    var (startIndex, endIndex) = getPageImagesRange(page);
    return (startIndex, endIndex);
  }

  void cache(int startPage) {
    for (int i = startPage - 1; i <= startPage + preCacheCount; i++) {
      if (i == startPage ||
          i <= 0 ||
          i > totalPages ||
          isChapterCommentsPage(i)) {
        continue;
      }
      _cachePage(i, i == startPage + 1 || i == startPage - 1);
    }
  }

  void _cachePage(int page, bool shouldPreCache) {
    if (isChapterCommentsPage(page)) return;
    var (startIndex, endIndex) = getPageImagesRange(page);
    for (int i = startIndex; i < endIndex; i++) {
      final key = data.images[i];
      if (shouldPreCache) {
        _imagePrecache.preload(
          _imageProvider(key),
          createLocalImageConfiguration(context),
        );
      } else if (!key.startsWith('file://')) {
        _imageDownloads.preload(
          key,
          data.sourceKey,
          data.comicId,
          data.chapterId,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final originalContent = data.content;
    final originalNavigation = navigation;
    return Listener(
      onPointerDown: (event) {
        fingers++;
      },
      onPointerUp: (event) {
        fingers--;
      },
      onPointerCancel: (event) {
        fingers--;
      },
      onPointerMove: (event) {
        if (isLongPressing) {
          final controller = _longPressController;
          if (controller == null ||
              !identical(photoViewControllers[page], controller)) {
            return;
          }
          Offset value = event.delta;
          if (isLongPressing) {
            controller.updateMultiple(position: controller.position + value);
          }
        }
      },
      child: PhotoViewGestureDetectorScope(
        axis: data.vertical ? Axis.vertical : Axis.horizontal,
        child: PageView.builder(
          reverse: data.reverse,
          scrollDirection: data.vertical ? Axis.vertical : Axis.horizontal,
          itemCount: totalPages + 2,
          controller: controller,
          itemBuilder: (context, index) => _buildPhotoPage(context, index),
          onPageChanged: (i) {
            if (_disposed ||
                !mounted ||
                !identical(data.content, originalContent) ||
                !identical(navigation, originalNavigation)) {
              return;
            }
            var shouldRefreshEInk = false;
            if (i == 0) {
              if (data.firstChapter ||
                  !navigation.toChapter(
                    navigation.state.chapter - 1,
                    toLastPage: true,
                  )) {
                controller.jumpToPage(1);
              } else {
                shouldRefreshEInk = true;
              }
            } else if (i == totalPages + 1) {
              if (data.lastChapter ||
                  !navigation.toChapter(navigation.state.chapter + 1)) {
                controller.jumpToPage(totalPages);
              } else {
                shouldRefreshEInk = true;
              }
            } else {
              final previousPage = page;
              navigation.reportPage(i);
              shouldRefreshEInk =
                  page != previousPage && !isChapterCommentsPage(i);
              widget.onPageReported(
                isChapterCommentsPage(i),
                shouldRefreshEInk,
              );
            }
            if (shouldRefreshEInk && (i == 0 || i == totalPages + 1)) {
              widget.onChapterChanged();
            }
            // Kept-alive neighbours reset when entered again, after their old
            // PhotoView subtree has actually unmounted.
            _longPressController = null;
            isLongPressing = false;
            if (mounted && !_disposed) setState(() {});
          },
        ),
      ),
    );
  }

  Widget _buildPhotoPage(BuildContext context, int index) {
    final decoration = BoxDecoration(color: context.colorScheme.surface);
    if (index == 0 || index == totalPages + 1) {
      return ClipRect(
        child: PhotoView.customChild(
          backgroundDecoration: decoration,
          child: const SizedBox(),
        ),
      );
    }
    if (isChapterCommentsPage(index)) {
      return ClipRect(
        child: PhotoView.customChild(
          backgroundDecoration: decoration,
          child: widget.commentsBuilder?.call(context) ?? const SizedBox(),
        ),
      );
    }
    final (start, end) = getPageImagesRange(index);
    final images = List.generate(end - start, (i) => start + i);
    cache(index);
    return _GalleryPhotoPage(
      key: ValueKey((
        data.content,
        widget.imageWork,
        data.sourceKey,
        data.comicId,
        data.chapterId,
        data.layout.imagesPerPage,
        data.layout.singleImageOnFirstPage,
        data.vertical,
        data.reverse,
        index,
      )),
      active: page == index,
      onController: (controller, attached) {
        if (attached) {
          photoViewControllers[index] = controller;
        } else if (identical(photoViewControllers[index], controller)) {
          photoViewControllers.remove(index);
        }
      },
      builder: (context, controller) {
        if (data.layout.imagesPerPage == 1 || images.length == 1) {
          return PhotoView(
            backgroundDecoration: decoration,
            filterQuality: FilterQuality.medium,
            controller: controller,
            imageProvider: _displayImage(data.images[images[0]]),
            fit: BoxFit.contain,
            loadingBuilder: _buildLoading,
            errorBuilder: (_, error, stack, retry) =>
                NetworkError(message: error.toString(), retry: retry),
          );
        }
        return PhotoView.customChild(
          backgroundDecoration: decoration,
          childSize: MediaQuery.sizeOf(context),
          controller: controller,
          minScale: PhotoViewComputedScale.contained * 1.0,
          maxScale: PhotoViewComputedScale.covered * 10.0,
          child: buildPageImages(images),
        );
      },
    );
  }

  Widget _buildLoading(BuildContext context, ImageChunkEvent? event) {
    return PhotoView.customChild(
      childSize: MediaQuery.of(context).size,
      initialScale: PhotoViewComputedScale.contained,
      minScale: PhotoViewComputedScale.contained * 1.0,
      maxScale: PhotoViewComputedScale.covered * 10.0,
      backgroundDecoration: BoxDecoration(color: context.colorScheme.surface),
      child: Center(
        child: SizedBox(
          width: 20.0,
          height: 20.0,
          child: CircularProgressIndicator(
            backgroundColor: context.colorScheme.surfaceContainerHigh,
            value: event == null || event.expectedTotalBytes == null
                ? null
                : event.cumulativeBytesLoaded / event.expectedTotalBytes!,
          ),
        ),
      ),
    );
  }

  Widget buildPageImages(List<int> images) {
    Axis axis = (data.vertical) ? Axis.vertical : Axis.horizontal;

    bool reverse = data.reverse;
    if (reverse) {
      images = images.reversed.toList();
    }

    List<Widget> imageWidgets;

    if (images.length == 2) {
      imageWidgets = [
        Expanded(
          child: ComicImage(
            width: double.infinity,
            height: double.infinity,
            image: _displayImage(data.images[images[0]]),
            fit: BoxFit.contain,
            alignment: axis == Axis.vertical
                ? Alignment.bottomCenter
                : Alignment.centerRight,
            onInit: (state) => imageStates[state] = images[0],
            onDispose: (state) => imageStates.remove(state),
          ),
        ),
        Expanded(
          child: ComicImage(
            width: double.infinity,
            height: double.infinity,
            image: _displayImage(data.images[images[1]]),
            fit: BoxFit.contain,
            alignment: axis == Axis.vertical
                ? Alignment.topCenter
                : Alignment.centerLeft,
            onInit: (state) => imageStates[state] = images[1],
            onDispose: (state) => imageStates.remove(state),
          ),
        ),
      ];
    } else {
      imageWidgets = images.map((imageIndex) {
        ImageProvider imageProvider = _displayImage(data.images[imageIndex]);
        return Expanded(
          child: ComicImage(
            image: imageProvider,
            fit: BoxFit.contain,
            onInit: (state) => imageStates[state] = imageIndex,
            onDispose: (state) => imageStates.remove(state),
          ),
        );
      }).toList();
    }

    return axis == Axis.vertical
        ? Column(children: imageWidgets)
        : Row(children: imageWidgets);
  }

  @override
  Future<void> animateToPage(int page) {
    if (_disposed || !mounted || !controller.hasClients) return Future.value();
    if ((page - controller.page!.round()).abs() > 1) {
      controller.jumpToPage(page > controller.page! ? page - 1 : page + 1);
    }
    return controller.animateToPage(
      page,
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
  }

  @override
  void toPage(int page) {
    if (_disposed || !mounted || !controller.hasClients) return;
    controller.jumpToPage(page);
  }

  @override
  bool toChapter(int chapter, {bool toLastPage = false}) {
    return false;
  }

  @override
  void handleDoubleTap(Offset location) {
    if (_disposed || !mounted) return;
    if (data.doubleTapCollect) {
      widget.onCollectImage();
      return;
    }
    photoViewControllers[page]?.onDoubleClick?.call();
  }

  @override
  void handleLongPressDown(Offset location) {
    if (_disposed || !mounted || fingers != 1) {
      return;
    }
    final photoViewController = photoViewControllers[page];
    final initial = photoViewController?.getInitialScale?.call();
    if (photoViewController == null || initial == null) return;
    _longPressController = photoViewController;
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
    isLongPressing = true;
  }

  @override
  void handleLongPressUp(Offset location) {
    if (_disposed || !mounted || !isLongPressing) {
      return;
    }
    final original = _longPressController;
    _longPressController = null;
    isLongPressing = false;
    if (original == null || !identical(photoViewControllers[page], original)) {
      return;
    }
    final target = original.getInitialScale?.call();
    if (target != null) original.animateScale?.call(target);
  }

  Timer? keyRepeatTimer;

  @override
  void cancelKeyboardInput() {
    keyRepeatTimer?.cancel();
    keyRepeatTimer = null;
  }

  @override
  void handleKeyEvent(KeyEvent event) {
    if (_disposed || !mounted) return;
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
    if (event is KeyDownEvent) {
      if (keyRepeatTimer != null) {
        keyRepeatTimer!.cancel();
        keyRepeatTimer = null;
      }
      if (forward == true) {
        navigation.toPage(page + 1);
      } else if (forward == false) {
        navigation.toPage(page - 1);
      }
    }
    if (event is KeyRepeatEvent && forward != null && keyRepeatTimer == null) {
      keyRepeatTimer = Timer.periodic(
        data.pageAnimation
            ? const Duration(milliseconds: 200)
            : const Duration(milliseconds: 50),
        (timer) {
          if (!mounted) {
            timer.cancel();
            return;
          } else if (forward == true) {
            navigation.toPage(page + 1);
          } else if (forward == false) {
            navigation.toPage(page - 1);
          }
        },
      );
    }
    if (event is KeyUpEvent && keyRepeatTimer != null) {
      keyRepeatTimer!.cancel();
      keyRepeatTimer = null;
    }
  }

  @override
  bool handleOnTap(Offset location) {
    return false;
  }

  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async {
    final index = getImageIndexByOffset(offset);
    if (index == null) return null;
    return widget.readImage(
      ReaderImageAddress(
        imageKey: data.images[index],
        sourceKey: data.sourceKey,
        comicId: data.comicId,
        chapterId: data.chapterId,
      ),
    );
  }

  @override
  int? getImageIndexByOffset(Offset offset) {
    if (_disposed || !mounted) return null;
    var range = currentImageRange;
    if (range == null) return null;

    var (startIndex, endIndex) = range;
    int actualImageCount = endIndex - startIndex;

    if (actualImageCount == 1) {
      return startIndex;
    }

    for (final entry in imageStates.entries) {
      if ((entry.key as ComicImageState).containsPoint(offset)) {
        final index = entry.value;
        if (index >= startIndex && index < endIndex) {
          return index;
        }
      }
    }

    return startIndex < endIndex ? startIndex : null;
  }
}

/// One page can remain mounted while a neighbouring page is selected. On
/// re-entry a new zoom session replaces the old subtree and releases it in
/// actual unmount order, without a time-based disposal heuristic.
class _GalleryPhotoPage extends StatefulWidget {
  const _GalleryPhotoPage({
    super.key,
    required this.active,
    required this.onController,
    required this.builder,
  });
  final bool active;
  final void Function(PhotoViewController, bool) onController;
  final Widget Function(BuildContext, PhotoViewController) builder;
  @override
  State<_GalleryPhotoPage> createState() => _GalleryPhotoPageState();
}

class _GalleryPhotoPageState extends State<_GalleryPhotoPage> {
  int _visit = 0;
  @override
  void didUpdateWidget(covariant _GalleryPhotoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active) _visit++;
  }

  @override
  Widget build(BuildContext context) => _GalleryPhotoOwner(
    key: ValueKey(_visit),
    onController: widget.onController,
    builder: widget.builder,
  );
}

class _GalleryPhotoOwner extends StatefulWidget {
  const _GalleryPhotoOwner({
    super.key,
    required this.onController,
    required this.builder,
  });
  final void Function(PhotoViewController, bool) onController;
  final Widget Function(BuildContext, PhotoViewController) builder;
  @override
  State<_GalleryPhotoOwner> createState() => _GalleryPhotoOwnerState();
}

class _GalleryPhotoOwnerState extends State<_GalleryPhotoOwner> {
  final controller = PhotoViewController();
  @override
  void initState() {
    super.initState();
    widget.onController(controller, true);
  }

  @override
  Widget build(BuildContext context) =>
      ClipRect(child: widget.builder(context, controller));
  @override
  void dispose() {
    widget.onController(controller, false);
    controller.dispose();
    super.dispose();
  }
}
