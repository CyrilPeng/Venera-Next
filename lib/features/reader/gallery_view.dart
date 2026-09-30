import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/reader/chapter_comments.dart';
import 'package:venera_next/features/reader/image_downloads.dart';
import 'package:venera_next/features/reader/image_precache.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';

import 'image_view_support.dart';

class ReaderGalleryView extends StatefulWidget {
  const ReaderGalleryView({super.key});

  @override
  State<ReaderGalleryView> createState() => GalleryModeState();
}

class GalleryModeState extends State<ReaderGalleryView>
    implements ReaderImageViewController, AutoReadingViewport {
  final _imageDownloads = ReaderImageDownloads();
  final _imagePrecache = ReaderImagePrecache();

  late PageController controller;

  int get preCacheCount =>
      appdata.settings.globalReaderSettings.preloadImageCount;

  var photoViewControllers = <int, PhotoViewController>{};

  late ReaderState reader;

  bool get showChapterCommentsAtEnd {
    if (reader.mode != ReaderMode.galleryLeftToRight &&
        reader.mode != ReaderMode.galleryRightToLeft) {
      return false;
    }
    if (reader.widget.chapters == null) return false;
    var source = ComicSource.find(reader.type.sourceKey);
    if (source?.chapterCommentsLoader == null) return false;
    return reader.preferences.showChapterComments == true &&
        reader.preferences.showChapterCommentsAtEnd == true;
  }

  int get totalImagePages => reader.maxPage;

  int get totalPages => reader.totalPages;

  bool isChapterCommentsPage(int pageIndex) {
    return showChapterCommentsAtEnd && pageIndex == totalImagePages + 1;
  }

  var imageStates = <State<ComicImage>>{};

  bool isLongPressing = false;

  int fingers = 0;

  @override
  void initState() {
    reader = context.reader;
    controller = PageController(initialPage: reader.page);
    reader.imageViewController = this;
    Future.microtask(() {
      context.readerScaffold.setFloatingButton(0);
    });
    super.initState();
  }

  @override
  void dispose() {
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
    if (reader.isOnChapterCommentsPage) return true;
    final photo = photoViewControllers[reader.page];
    final initialScale = photo?.getInitialScale?.call();
    // PhotoView installs this callback only after its image is decoded.
    if (initialScale == null ||
        ((photo?.scale ?? initialScale) - initialScale).abs() > 0.01) {
      return false;
    }
    final (start, end) = getPageImagesRange(reader.page);
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
      reader.pageLayout.imageRange(page, reader.images!.length);

  /// Get the image indices for current page. Returns null if no images.
  /// Returns a single index if only one image, or a range if multiple images.
  @override
  (int, int)? get currentImageRange {
    if (reader.images == null || reader.images!.isEmpty) {
      return null;
    }
    var (startIndex, endIndex) = getPageImagesRange(reader.page);
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
      shouldPreCache
          ? precacheReaderImage(i + 1, context, _imagePrecache)
          : predownloadReaderImage(i + 1, context, _imageDownloads);
    }
  }

  Widget _buildChapterCommentsPage() {
    var source = ComicSource.find(reader.type.sourceKey);
    var chapters = reader.widget.chapters;
    if (source == null || chapters == null) return const SizedBox();
    var chapterIndex = reader.chapter - 1;
    return EmbeddedChapterCommentsPage(
      comicId: reader.cid,
      epId: chapters.ids.elementAt(chapterIndex),
      source: source,
      comicTitle: reader.widget.name,
      chapterTitle: chapters.titles.elementAt(chapterIndex),
    );
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
          var controller = photoViewControllers[reader.page]!;
          Offset value = event.delta;
          if (isLongPressing) {
            controller.updateMultiple(position: controller.position + value);
          }
        }
      },
      child: PhotoViewGallery.builder(
        backgroundDecoration: BoxDecoration(color: context.colorScheme.surface),
        reverse: reader.mode == ReaderMode.galleryRightToLeft,
        scrollDirection: reader.mode == ReaderMode.galleryTopToBottom
            ? Axis.vertical
            : Axis.horizontal,
        itemCount: totalPages + 2,
        builder: (BuildContext context, int index) {
          if (index == 0 || index == totalPages + 1) {
            return PhotoViewGalleryPageOptions.customChild(
              child: const SizedBox(),
            );
          } else if (isChapterCommentsPage(index)) {
            return PhotoViewGalleryPageOptions.customChild(
              child: _buildChapterCommentsPage(),
            );
          } else {
            var (startIndex, endIndex) = getPageImagesRange(index);
            List<String> pageImages = reader.images!.sublist(
              startIndex,
              endIndex,
            );

            cache(index);

            photoViewControllers[index] ??= PhotoViewController();

            if (reader.imagesPerPage == 1 || pageImages.length == 1) {
              return PhotoViewGalleryPageOptions(
                filterQuality: FilterQuality.medium,
                controller: photoViewControllers[index],
                imageProvider: createReaderImageProviderFromKey(
                  pageImages[0],
                  context,
                  startIndex + 1,
                ),
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
              child: buildPageImages(pageImages, startIndex),
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
            if (reader.isFirstChapterOfGroup ||
                !reader.toPrevChapter(toLastPage: true)) {
              controller.jumpToPage(1);
            } else {
              shouldRefreshEInk = true;
            }
          } else if (i == totalPages + 1) {
            if (reader.isLastChapterOfGroup || !reader.toNextChapter()) {
              controller.jumpToPage(totalPages);
            } else {
              shouldRefreshEInk = true;
            }
          } else {
            final previousPage = reader.page;
            reader.setPage(i);
            context.readerScaffold.update();
            shouldRefreshEInk =
                reader.page != previousPage && !isChapterCommentsPage(i);
            // Auto close toolbar when entering chapter comments page
            if (isChapterCommentsPage(i) && context.readerScaffold.isOpen) {
              context.readerScaffold.openOrClose();
            }
          }
          if (shouldRefreshEInk) {
            context.readerScaffold.requestEInkRefresh();
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

  Widget buildPageImages(List<String> images, int startIndex) {
    Axis axis = (reader.mode == ReaderMode.galleryTopToBottom)
        ? Axis.vertical
        : Axis.horizontal;

    bool reverse = reader.mode == ReaderMode.galleryRightToLeft;
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
            image: createReaderImageProviderFromKey(
              images[0],
              context,
              startIndex + 1,
            ),
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
            image: createReaderImageProviderFromKey(
              images[1],
              context,
              startIndex + 2,
            ),
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
        startIndex++;
        ImageProvider imageProvider = createReaderImageProviderFromKey(
          imageKey,
          context,
          startIndex,
        );
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
    if (appdata.settings.globalReaderSettings.quickCollectImage ==
        'DoubleTap') {
      context.readerScaffold.addImageFavorite();
      return;
    }
    var controller = photoViewControllers[reader.page]!;
    controller.onDoubleClick?.call();
  }

  @override
  void handleLongPressDown(Offset location) {
    if (fingers != 1) {
      return;
    }
    var photoViewController = photoViewControllers[reader.page]!;
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
    isLongPressing = true;
  }

  @override
  void handleLongPressUp(Offset location) {
    if (!isLongPressing) {
      return;
    }
    var photoViewController = photoViewControllers[reader.page]!;
    double target = photoViewController.getInitialScale!.call()!;
    photoViewController.animateScale?.call(target);
    isLongPressing = false;
  }

  Timer? keyRepeatTimer;

  @override
  void handleKeyEvent(KeyEvent event) {
    bool? forward;
    if (reader.mode == ReaderMode.galleryLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      forward = false;
    } else if (reader.mode == ReaderMode.galleryLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = false;
    } else if (reader.mode == ReaderMode.galleryRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = false;
    }
    if (event is KeyDownEvent) {
      if (keyRepeatTimer != null) {
        keyRepeatTimer!.cancel();
        keyRepeatTimer = null;
      }
      if (forward == true) {
        reader.toPage(reader.page + 1);
      } else if (forward == false) {
        reader.toPage(reader.page - 1);
      }
    }
    if (event is KeyRepeatEvent && keyRepeatTimer == null) {
      keyRepeatTimer = Timer.periodic(
        reader.enablePageAnimation(reader.cid, reader.type)
            ? const Duration(milliseconds: 200)
            : const Duration(milliseconds: 50),
        (timer) {
          if (!mounted) {
            timer.cancel();
            return;
          } else if (forward == true) {
            reader.toPage(reader.page + 1);
          } else if (forward == false) {
            reader.toPage(reader.page - 1);
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
    var range = currentImageRange;
    if (range == null) return null;

    var (startIndex, endIndex) = range;
    int actualImageCount = endIndex - startIndex;

    if (actualImageCount == 1) {
      return reader.images![startIndex];
    }

    for (var imageState in imageStates) {
      if ((imageState as ComicImageState).containsPoint(offset)) {
        var imageKey =
            (imageState.widget.image as ReaderImageProvider).imageKey;
        int index = reader.images!.indexOf(imageKey);
        if (index >= startIndex && index < endIndex) {
          return imageKey;
        }
      }
    }

    return reader.images![startIndex];
  }
}
