part of 'image_favorites_page.dart';

class ImageFavoritesGalleryPage extends StatefulWidget {
  const ImageFavoritesGalleryPage({super.key, required this.comic});

  final ImageFavoritesComic comic;

  @override
  State<ImageFavoritesGalleryPage> createState() =>
      _ImageFavoritesGalleryPageState();
}

class _ImageFavoritesGalleryPageState extends State<ImageFavoritesGalleryPage> {
  late ImageFavoritesComic comic;

  List<ImageFavorite> get images => comic.images.toList();

  @override
  void initState() {
    super.initState();
    comic = widget.comic;
    ImageFavoriteManager().addListener(_onDataChanged);
  }

  void _onDataChanged() {
    if (!mounted) return;
    final updated = ImageFavoriteManager().find(comic.id, comic.sourceKey);
    if (updated == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      comic = updated;
      selectedImages.clear();
      multiSelectMode = false;
    });
  }

  bool multiSelectMode = false;
  Map<ImageFavorite, bool> selectedImages = {};
  var scrollController = ScrollController();

  void toggleSelect(ImageFavorite image) {
    setState(() {
      if (selectedImages[image] != null) {
        selectedImages.remove(image);
      } else {
        selectedImages[image] = true;
      }
      multiSelectMode = selectedImages.isNotEmpty;
    });
  }

  void selectAll() {
    setState(() {
      for (var img in images) {
        selectedImages[img] = true;
      }
      multiSelectMode = true;
    });
  }

  void deselectAll() {
    setState(() {
      selectedImages.clear();
      multiSelectMode = false;
    });
  }

  void deleteSelected() {
    if (selectedImages.isEmpty) return;
    ImageFavoriteManager().deleteImageFavorite(selectedImages.keys);
  }

  void goPhotoView(ImageFavorite image) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            ImageFavoritesPhotoView(comic: comic, imageFavorite: image),
      ),
    );
  }

  void goReaderPage(ImageFavorite image) {
    App.rootContext.to(
      () => ReaderWithLoading(
        id: image.id,
        sourceKey: image.sourceKey,
        initialEp: image.ep,
        initialPage: image.page,
      ),
    );
  }

  @override
  void dispose() {
    ImageFavoriteManager().removeListener(_onDataChanged);
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final imgList = images;

    Widget buildSliverAppBar() {
      if (multiSelectMode) {
        return SliverAppbar(
          leading: Tooltip(
            message: "Cancel".tl,
            child: IconButton(
              icon: const Icon(Icons.close),
              onPressed: deselectAll,
            ),
          ),
          title: Text(selectedImages.length.toString()),
          actions: [
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: "Select All".tl,
              onPressed: selectAll,
            ),
            IconButton(
              icon: const Icon(Icons.deselect),
              tooltip: "Deselect".tl,
              onPressed: deselectAll,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: "Delete".tl,
              onPressed: deleteSelected,
            ),
          ],
        );
      }

      return SliverAppbar(
        title: Text(comic.title),
        actions: [
          Tooltip(
            message: "Multi-Select".tl,
            child: IconButton(
              icon: const Icon(Icons.checklist),
              onPressed: () {
                setState(() {
                  multiSelectMode = true;
                });
              },
            ),
          ),
        ],
      );
    }

    Widget buildGridItem(int index) {
      var image = imgList[index];
      bool isSelected = selectedImages[image] ?? false;
      int curPage = image.page;
      String pageText = curPage == firstPage
          ? '@a Cover'.tlParams({"a": image.epName})
          : '@a - @b'.tlParams({"a": image.epName, "b": curPage.toString()});

      return ClickInkWell(
        onTap: () {
          if (multiSelectMode) {
            toggleSelect(image);
          } else {
            goReaderPage(image);
          }
        },
        onLongPress: () {
          if (multiSelectMode) {
            toggleSelect(image);
          } else {
            goPhotoView(image);
          }
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: isSelected
                ? Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  )
                : null,
            color: isSelected
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Theme.of(context).colorScheme.secondaryContainer,
                ),
                clipBehavior: Clip.antiAlias,
                child: Hero(
                  tag: "${image.id}_${image.ep}_${image.page}",
                  child: AnimatedImage(
                    image: ImageFavoritesProvider(image),
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
              if (multiSelectMode)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surface.toOpacity(0.7),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isSelected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 22,
                    ),
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(8),
                      bottomRight: Radius.circular(8),
                    ),
                    color: Theme.of(context).colorScheme.surface.toOpacity(0.7),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Text(
                    pageText,
                    style: const TextStyle(fontSize: 10),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    var scrollWidget = SmoothCustomScrollView(
      controller: scrollController,
      slivers: [
        buildSliverAppBar(),
        SliverLayoutBuilder(
          builder: (context, constraints) {
            const spacing = 6.0;
            const itemWidth = 120.0;
            final crossCount = (() {
              var calculated =
                  (constraints.crossAxisExtent + spacing) ~/
                  (itemWidth + spacing);
              return calculated < 1 ? 1 : calculated;
            })();
            return SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              sliver: SliverGrid(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => buildGridItem(index),
                  childCount: imgList.length,
                ),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossCount,
                  childAspectRatio: 3 / 4,
                  crossAxisSpacing: spacing,
                  mainAxisSpacing: spacing,
                ),
              ),
            );
          },
        ),
        SliverPadding(padding: EdgeInsets.only(top: context.padding.bottom)),
      ],
    );

    return PopScope(
      canPop: !multiSelectMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (multiSelectMode) {
          deselectAll();
        }
      },
      child: Scrollbar(
        controller: scrollController,
        thickness: App.isDesktop ? 8 : 12,
        radius: const Radius.circular(8),
        interactive: true,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: scrollWidget,
        ),
      ),
    );
  }
}
