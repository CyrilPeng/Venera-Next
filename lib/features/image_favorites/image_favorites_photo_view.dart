import 'package:venera_next/features/history/history_scope.dart';
import 'package:venera_next/components/file_save_task.dart';
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:venera_next/components/effects.dart';
import 'package:venera_next/components/image_save_binding.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/features/history/history_api.dart';
import 'package:venera_next/features/history/image_favorites.dart';
import 'package:venera_next/features/history/image_favorites_provider.dart';
import 'package:venera_next/features/reader/reader.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/image_save_work.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

class ImageFavoritesPhotoView extends StatefulWidget {
  const ImageFavoritesPhotoView({
    this.manager,
    super.key,
    required this.comic,
    required this.imageFavorite,
  });

  final ImageFavoritesComic comic;
  final ImageFavorite imageFavorite;

  final ImageFavoriteManager? manager;

  @override
  State<ImageFavoritesPhotoView> createState() =>
      _ImageFavoritesPhotoViewState();
}

class _ImageFavoritesPhotoViewState extends State<ImageFavoritesPhotoView>
    with ContextMenuOwner {
  late final ImageFavoriteManager _manager =
      widget.manager ?? HistoryScope.readImages(context);

  @override
  Object get contextMenuIdentity => (widget.comic, currentPage);
  late PageController controller;
  Map<ImageFavorite, bool> cancelImageFavorites = {};

  var images = <ImageFavorite>[];

  int currentPage = 0;

  bool isAppBarShow = false;

  late final _saves = ImageSaveWork(
    deliver: (bytes, filename, checkStop) => saveFileForWindow(
      context,
      data: bytes,
      filename: filename,
      checkStop: checkStop,
    ),
    onError: (error, stack) {
      Log.error('Image save', error, stack);
      if (mounted) context.showMessage(message: 'Error'.tl);
    },
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  void initState() {
    var current = 0;
    for (var ep in widget.comic.imageFavoritesEp) {
      for (var image in ep.imageFavorites) {
        images.add(image);
        if (image == widget.imageFavorite) {
          current = images.length - 1;
        }
      }
    }
    currentPage = current;
    controller = PageController(initialPage: current);
    super.initState();
  }

  bool _submittedRemovals = false;

  Future<void> onPop() async {
    if (_submittedRemovals) return;
    _submittedRemovals = true;
    final images = cancelImageFavorites.entries
        .where((entry) => entry.value)
        .map((entry) => entry.key)
        .toList();
    if (images.isEmpty) return;
    final messages = ScaffoldMessenger.of(context);
    final success = 'Delete @a images'.tlParams({'a': images.length});
    final failure = 'Error'.tl;
    try {
      await _manager.deleteImageFavorite(images);
      if (messages.mounted) {
        messages.showSnackBar(SnackBar(content: Text(success)));
      }
    } catch (error, stack) {
      Log.error('Image Favorites', error, stack);
      if (messages.mounted) {
        messages.showSnackBar(SnackBar(content: Text(failure)));
      }
    }
  }

  PhotoViewGalleryPageOptions _buildItem(BuildContext context, int index) {
    var image = images[index];
    return PhotoViewGalleryPageOptions(
      // 图片加载器 支持本地、网络
      imageProvider: ImageFavoritesProvider(image),
      // 初始化大小 全部展示
      minScale: PhotoViewComputedScale.contained * 1.0,
      maxScale: PhotoViewComputedScale.covered * 10.0,
      onTapUp: (context, details, controllerValue) {
        setState(() {
          isAppBarShow = !isAppBarShow;
        });
      },
      heroAttributes: PhotoViewHeroAttributes(
        tag: "${image.sourceKey}${image.ep}${image.page}",
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    contextMenus.revalidate();
    return ImageSaveBinding(
      work: _saves,
      child: PopScope(
        onPopInvokedWithResult: (bool didPop, Object? result) async {
          if (didPop) {
            await onPop();
          }
        },
        child: Listener(
          onPointerSignal: (event) {
            if (HardwareKeyboard.instance.isControlPressed) {
              return;
            }
            if (event is PointerScrollEvent) {
              if (event.scrollDelta.dy > 0) {
                if (controller.page! >= images.length - 1) {
                  return;
                }
                controller.nextPage(
                  duration: Duration(milliseconds: 180),
                  curve: Curves.ease,
                );
              } else {
                if (controller.page! <= 0) {
                  return;
                }
                controller.previousPage(
                  duration: Duration(milliseconds: 180),
                  curve: Curves.ease,
                );
              }
            }
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: PhotoViewGallery.builder(
                  backgroundDecoration: BoxDecoration(
                    color: context.colorScheme.surface,
                  ),
                  builder: _buildItem,
                  itemCount: images.length,
                  loadingBuilder: (context, event) => Center(
                    child: SizedBox(
                      width: 20.0,
                      height: 20.0,
                      child: CircularProgressIndicator(
                        backgroundColor:
                            context.colorScheme.surfaceContainerHigh,
                        value: event == null || event.expectedTotalBytes == null
                            ? null
                            : event.cumulativeBytesLoaded /
                                  event.expectedTotalBytes!,
                      ),
                    ),
                  ),
                  pageController: controller,
                  onPageChanged: (index) {
                    setState(() {
                      currentPage = index;
                    });
                  },
                ),
              ),
              buildPageInfo(),
              AnimatedPositioned(
                top: isAppBarShow ? 0 : -(context.padding.top + 52),
                left: 0,
                right: 0,
                duration: Duration(milliseconds: 180),
                child: buildAppBar(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildPageInfo() {
    var text = "${currentPage + 1}/${images.length}";
    return Positioned(
      height: 40,
      left: 0,
      right: 0,
      bottom: 0,
      child: Center(
        child: Stack(
          children: [
            Text(
              text,
              style: TextStyle(
                fontSize: 14,
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 1.4
                  ..color = context.colorScheme.onInverseSurface,
              ),
            ),
            Text(text),
          ],
        ),
      ),
    );
  }

  Widget buildAppBar() {
    return Material(
      color: context.colorScheme.surface.toOpacity(0.72),
      child: BlurEffect(
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: context.colorScheme.outlineVariant,
                width: 0.5,
              ),
            ),
          ),
          height: 52,
          child: Row(
            children: [
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(Icons.close),
                onPressed: () {
                  Navigator.of(context).maybePop();
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.comic.title, style: TextStyle(fontSize: 18)),
              ),
              IconButton(icon: Icon(Icons.more_vert), onPressed: showMenu),
              const SizedBox(width: 8),
            ],
          ),
        ).paddingTop(context.padding.top),
      ),
    );
  }

  void showMenu() {
    final originalPage = currentPage;
    if (originalPage < 0 || originalPage >= images.length) return;
    final originalImage = images[originalPage];
    final originalComic = widget.comic;
    contextMenus.show(
      context,
      Offset(context.width, context.padding.top),
      [
        MenuEntry(
          icon: Icons.image_outlined,
          text: "Save Image".tl,
          onClick: () {
            final page = originalPage;
            final image = originalImage.copyWith();
            final provider = ImageFavoritesProvider(image);
            unawaited(
              _saves.save(
                name: '${page + 1}',
                read: (scope) => provider.readBytes(
                  checkStop: scope.check,
                  cancelSignal: scope.whenCancelled,
                ),
              ),
            );
          },
        ),
        MenuEntry(
          icon: Icons.menu_book_outlined,
          text: "Read".tl,
          onClick: () async {
            var comic = originalComic;
            var ep = originalImage.ep;
            var page = originalImage.page;
            context.to(
              () => ReaderWithLoading(
                id: comic.id,
                sourceKey: comic.sourceKey,
                initialEp: ep,
                initialPage: page,
              ),
            );
          },
        ),
      ],
      isValid: () =>
          mounted &&
          currentPage == originalPage &&
          originalPage < images.length &&
          identical(images[currentPage], originalImage),
    );
  }
}
