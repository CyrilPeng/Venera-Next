import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/features/reader/image_downloads.dart';
import 'package:venera_next/features/reader/image_precache.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';

import 'gallery_data.dart';
import 'reader_controller.dart';
import 'reader_viewport.dart';

class ReaderGalleryView extends StatefulWidget {
  const ReaderGalleryView({
    super.key,
    required this.data,
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
  final ReaderController navigation;
  final void Function(ReaderImageViewController viewport, bool attached)
  onViewportChanged;
  final VoidCallback onReady;
  final void Function(bool comments, bool refreshEInk) onPageReported;
  final VoidCallback onChapterChanged;
  final VoidCallback onCollectImage;
  final Size Function() readerSize;
  final Future<Uint8List?> Function(String imageKey) readImage;
  final WidgetBuilder? commentsBuilder;

  @override
  State<ReaderGalleryView> createState() => GalleryModeState();
}

class GalleryModeState extends State<ReaderGalleryView>
    implements ReaderImageViewController, AutoReadingViewport {
  final _imageDownloads = ReaderImageDownloads();
  final _imagePrecache = ReaderImagePrecache();

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

  var imageStates = <State<ComicImage>>{};

  bool isLongPressing = false;

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
    if (oldWidget.onViewportChanged != widget.onViewportChanged) {
      oldWidget.onViewportChanged(this, false);
      widget.onViewportChanged(this, true);
    }
  }

  @override
  void dispose() {
    widget.onViewportChanged(this, false);
    keyRepeatTimer?.cancel();
    _imagePrecache.dispose();
    unawaited(_imageDownloads.dispose());
    super.dispose();
  }

  @override
  bool get autoReadingReady {
    if (!controller.hasClients ||
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
    final visible = imageStates
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
          var controller = photoViewControllers[page]!;
          Offset value = event.delta;
          if (isLongPressing) {
            controller.updateMultiple(position: controller.position + value);
          }
        }
      },
      child: PhotoViewGallery.builder(
        backgroundDecoration: BoxDecoration(color: context.colorScheme.surface),
        reverse: data.reverse,
        scrollDirection: data.vertical ? Axis.vertical : Axis.horizontal,
        itemCount: totalPages + 2,
        builder: (BuildContext context, int index) {
          if (index == 0 || index == totalPages + 1) {
            return PhotoViewGalleryPageOptions.customChild(
              child: const SizedBox(),
            );
          } else if (isChapterCommentsPage(index)) {
            return PhotoViewGalleryPageOptions.customChild(
              child: widget.commentsBuilder?.call(context) ?? const SizedBox(),
            );
          } else {
            var (startIndex, endIndex) = getPageImagesRange(index);
            List<String> pageImages = data.images.sublist(startIndex, endIndex);

            cache(index);

            photoViewControllers[index] ??= PhotoViewController();

            if (data.layout.imagesPerPage == 1 || pageImages.length == 1) {
              return PhotoViewGalleryPageOptions(
                filterQuality: FilterQuality.medium,
                controller: photoViewControllers[index],
                imageProvider: _imageProvider(pageImages[0]),
                fit: BoxFit.contain,
                errorBuilder: (_, error, s, retry) {
                  return NetworkError(message: error.toString(), retry: retry);
                },
              );
            }

            final viewportSize = MediaQuery.of(context).size;
            return PhotoViewGalleryPageOptions.customChild(
              childSize: viewportSize,
              controller: photoViewControllers[index],
              minScale: PhotoViewComputedScale.contained * 1.0,
              maxScale: PhotoViewComputedScale.covered * 10.0,
              child: buildPageImages(pageImages),
            );
          }
        },
        pageController: controller,
        loadingBuilder: (context, event) {
          return PhotoView.customChild(
            childSize: MediaQuery.of(context).size,
            initialScale: PhotoViewComputedScale.contained,
            minScale: PhotoViewComputedScale.contained * 1.0,
            maxScale: PhotoViewComputedScale.covered * 10.0,
            backgroundDecoration: BoxDecoration(
              color: context.colorScheme.surface,
            ),
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
        },
        onPageChanged: (i) {
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
            widget.onPageReported(isChapterCommentsPage(i), shouldRefreshEInk);
          }
          if (shouldRefreshEInk && (i == 0 || i == totalPages + 1)) {
            widget.onChapterChanged();
          }
          // Remove other pages' controllers to reset their state.
          var keys = photoViewControllers.keys.toList();
          for (var key in keys) {
            if (key != i) {
              photoViewControllers.remove(key);
            }
          }
        },
      ),
    );
  }

  Widget buildPageImages(List<String> images) {
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
            image: _imageProvider(images[0]),
            fit: BoxFit.contain,
            alignment: axis == Axis.vertical
                ? Alignment.bottomCenter
                : Alignment.centerRight,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
          ),
        ),
        Expanded(
          child: ComicImage(
            width: double.infinity,
            height: double.infinity,
            image: _imageProvider(images[1]),
            fit: BoxFit.contain,
            alignment: axis == Axis.vertical
                ? Alignment.topCenter
                : Alignment.centerLeft,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
          ),
        ),
      ];
    } else {
      imageWidgets = images.map((imageKey) {
        ImageProvider imageProvider = _imageProvider(imageKey);
        return Expanded(
          child: ComicImage(
            image: imageProvider,
            fit: BoxFit.contain,
            onInit: (state) => imageStates.add(state),
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
    controller.jumpToPage(page);
  }

  @override
  bool toChapter(int chapter, {bool toLastPage = false}) {
    return false;
  }

  @override
  void handleDoubleTap(Offset location) {
    if (data.doubleTapCollect) {
      widget.onCollectImage();
      return;
    }
    var controller = photoViewControllers[page]!;
    controller.onDoubleClick?.call();
  }

  @override
  void handleLongPressDown(Offset location) {
    if (fingers != 1) {
      return;
    }
    var photoViewController = photoViewControllers[page]!;
    double target = photoViewController.getInitialScale!.call()! * 1.75;
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
    if (!isLongPressing) {
      return;
    }
    var photoViewController = photoViewControllers[page]!;
    double target = photoViewController.getInitialScale!.call()!;
    photoViewController.animateScale?.call(target);
    isLongPressing = false;
  }

  Timer? keyRepeatTimer;

  @override
  void handleKeyEvent(KeyEvent event) {
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
    if (event is KeyRepeatEvent && keyRepeatTimer == null) {
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
    var imageKey = getImageKeyByOffset(offset);
    if (imageKey == null) return null;
    return widget.readImage(imageKey);
  }

  @override
  String? getImageKeyByOffset(Offset offset) {
    var range = currentImageRange;
    if (range == null) return null;

    var (startIndex, endIndex) = range;
    int actualImageCount = endIndex - startIndex;

    if (actualImageCount == 1) {
      return data.images[startIndex];
    }

    for (var imageState in imageStates) {
      if ((imageState as ComicImageState).containsPoint(offset)) {
        var imageKey =
            (imageState.widget.image as ReaderImageProvider).imageKey;
        int index = data.images.indexOf(imageKey);
        if (index >= startIndex && index < endIndex) {
          return imageKey;
        }
      }
    }

    return data.images[startIndex];
  }
}
