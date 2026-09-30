import 'package:venera_next/foundation/reader_preferences.dart';
import 'package:venera_next/foundation/reader_preference_store.dart';
import 'dart:async';

import 'package:venera_next/features/reader/status_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/features/reader/progress_bar.dart';
import 'package:venera_next/features/reader/top_bar.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/side_bar.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/reader/brightness.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/chapter_comments.dart';
import 'package:venera_next/features/reader/chapters.dart';
import 'package:venera_next/features/reader/eink_refresh.dart';
import 'package:venera_next/features/reader/gesture.dart';
import 'package:venera_next/features/reader/orientation.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/consts.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/features/reader/image_export.dart';
import 'package:venera_next/features/reader/image_selection.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';
import 'package:venera_next/routing/settings.dart';

class ReaderScaffold extends StatefulWidget {
  const ReaderScaffold({super.key, required this.child});

  final Widget child;

  @override
  State<ReaderScaffold> createState() => ReaderScaffoldState();
}

class ReaderScaffoldState extends State<ReaderScaffold>
    with ReaderOrientationState {
  ReaderPreferenceStore get _settingsStore => ReaderPreferenceStore(
    settings: appdata.settings,
    comicId: context.reader.cid,
    sourceKey: context.reader.type.sourceKey,
  );

  bool _isOpen = false;

  bool _brightnessPanelOpen = false;

  final EInkRefreshController _eInkRefreshController = EInkRefreshController();

  static const kTopBarHeight = 56.0;

  bool get isOpen => _isOpen;

  bool get isReversed =>
      context.reader.mode == ReaderMode.galleryRightToLeft ||
      context.reader.mode == ReaderMode.continuousRightToLeft;

  int showFloatingButtonValue = 0;

  var lastValue = 0;

  ReaderGestureDetectorState? gestureDetectorState;

  void setFloatingButton(int value) {
    lastValue = showFloatingButtonValue;
    if (value == 0) {
      if (showFloatingButtonValue != 0) {
        showFloatingButtonValue = 0;
        update();
      }
    }
    if (value == 1 && showFloatingButtonValue == 0) {
      showFloatingButtonValue = 1;
      update();
    } else if (value == -1 && showFloatingButtonValue == 0) {
      showFloatingButtonValue = -1;
      update();
    }
  }

  ReaderDragListener? _imageFavoriteDragListener;

  void addDragListener() async {
    if (!mounted) return;

    // 横向阅读的时候, 如果纵向滑就触发收藏, 纵向阅读的时候, 如果横向滑动就触发收藏
    if (appdata.settings.globalReaderSettings.quickCollectImage == 'Swipe') {
      if (_imageFavoriteDragListener == null) {
        double distance = 0;
        _imageFavoriteDragListener = ReaderDragListener(
          onMove: (offset) {
            switch (context.reader.mode) {
              case ReaderMode.continuousTopToBottom:
              case ReaderMode.waterfallTopToBottom:
              case ReaderMode.galleryTopToBottom:
                distance += offset.dx;
              case ReaderMode.continuousLeftToRight:
              case ReaderMode.galleryLeftToRight:
              case ReaderMode.galleryRightToLeft:
              case ReaderMode.continuousRightToLeft:
                distance += offset.dy;
            }
          },
          onEnd: () {
            if (distance.abs() > 150) {
              addImageFavorite();
            }
            distance = 0;
          },
        );
      }
      gestureDetectorState!.addDragListener(_imageFavoriteDragListener!);
    } else if (_imageFavoriteDragListener != null) {
      gestureDetectorState!.removeDragListener(_imageFavoriteDragListener!);
    }
  }

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 200), addDragListener);
  }

  @override
  void dispose() {
    _imageExporter.dispose();
    _selectionOverlay.dispose();
    _eInkRefreshController.dispose();
    super.dispose();
  }

  void _applySystemUiMode() {
    if (_isOpen || context.reader.preferences.showSystemStatusBar == true) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    }
  }

  void openOrClose() {
    setState(() {
      _isOpen = !_isOpen;
      if (!_isOpen) {
        _brightnessPanelOpen = false;
      }
    });
    _applySystemUiMode();
  }

  void update() {
    setState(() {});
  }

  void requestEInkRefresh() {
    if (!mounted || !context.reader.mode.isGallery) {
      return;
    }

    final settings = context.reader.preferences;
    if (!settings.eInkRefreshEnabled) {
      _eInkRefreshController.reset();
      return;
    }
    _eInkRefreshController.onPageChanged(
      interval: settings.eInkRefreshInterval,
      durationMilliseconds: settings.eInkRefreshDuration,
      style: EInkRefreshStyle.fromKey(settings.eInkRefreshStyle),
    );
  }

  void resetEInkRefreshCounter() {
    _eInkRefreshController.reset();
  }

  @override
  Widget build(BuildContext context) {
    final isOnChapterCommentsPage = context.reader.isOnChapterCommentsPage;
    final brightnessPanelVisible = _isOpen && _brightnessPanelOpen;
    return Stack(
      children: [
        Positioned.fill(
          child: AbsorbPointer(
            absorbing: context.reader.isPageAnimating,
            child: widget.child,
          ),
        ),
        if (!isOnChapterCommentsPage)
          Positioned.fill(
            child: ReaderBrightnessOverlay(
              enabled:
                  context.reader.preferences.readerBrightnessEnabled == true,
              brightness: context.reader.preferences.readerBrightness,
            ),
          ),
        if (context.reader.preferences.showPageNumberInReader == true &&
            !isOnChapterCommentsPage)
          buildPageInfoText(),
        if (!isOnChapterCommentsPage) buildStatusInfo(),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 180),
          right: 16,
          bottom: showFloatingButtonValue == 0 ? -58 : 36,
          child: buildEpChangeButton(),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 180),
          top: _isOpen ? 0 : -(kTopBarHeight + context.padding.top),
          left: 0,
          right: 0,
          height: kTopBarHeight + context.padding.top,
          child: buildTop(),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 180),
          bottom: _isOpen
              ? 0
              : -(ReaderBottomBar.height +
                    MediaQuery.of(context).padding.bottom),
          left: 0,
          right: 0,
          child: buildBottom(),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          right: 16 + context.padding.right,
          bottom: brightnessPanelVisible
              ? ReaderBottomBar.height + context.padding.bottom + 12
              : -220,
          child: ExcludeFocus(
            excluding: !brightnessPanelVisible,
            child: ExcludeSemantics(
              excluding: !brightnessPanelVisible,
              child: IgnorePointer(
                ignoring: !brightnessPanelVisible,
                child: buildBrightnessPanel(),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: EInkRefreshOverlay(controller: _eInkRefreshController),
        ),
      ],
    );
  }

  Widget buildTop() => ReaderTopBar(
    title: context.reader.widget.name,
    chapterTitle: context.reader.widget.chapters?.titles.elementAtOrNull(
      context.reader.chapter - 1,
    ),
    onBack: () => Navigator.of(context).maybePop(),
    actions: [
      if (shouldShowChapterComments())
        Tooltip(
          message: "Chapter Comments".tl,
          child: IconButton(
            icon: const Icon(Icons.comment),
            onPressed: openChapterComments,
          ),
        ),
      Tooltip(
        message: "Settings".tl,
        child: IconButton(
          icon: const Icon(Icons.settings),
          onPressed: openSetting,
        ),
      ),
    ],
  );

  bool isLiked() {
    return _findImageFavorite(context.reader.page) != null;
  }

  ImageFavorite? _findImageFavorite(int page) {
    final comic = ImageFavoriteManager().find(
      context.reader.cid,
      context.reader.type.sourceKey,
    );
    final ep = comic?.imageFavoritesEp
        .where((e) => e.eid == context.reader.eid)
        .firstOrNull;
    return ep?.imageFavorites.where((image) => image.page == page).firstOrNull;
  }

  void addImageFavorite() async {
    try {
      if (context.reader.images![0].contains('file://')) {
        showToast(
          message: "Local comic collection is not supported at present".tl,
          context: context,
        );
        return;
      }
      String id = context.reader.cid;
      int ep = context.reader.chapter;
      String eid = context.reader.eid;
      String title = context.reader.history!.title;
      String subTitle = context.reader.history!.subtitle;
      int maxPage = context.reader.images!.length;
      int? page = await selectImage();
      if (!mounted || page == null) return;
      page += 1;
      String sourceKey = context.reader.type.sourceKey;
      String imageKey = context.reader.images![page - 1];
      List<String> tags = context.reader.widget.tags;
      String author = context.reader.widget.author;

      var epName =
          context.reader.widget.chapters?.titles.elementAtOrNull(
            context.reader.chapter - 1,
          ) ??
          "E${context.reader.chapter}";
      var translatedTags = tags.map((e) => e.translateTagsToCN).toList();

      final likedImage = _findImageFavorite(page);
      if (likedImage != null) {
        if (page == firstPage) {
          if (!canUncollectImageFavorite(likedImage)) {
            showToast(
              message: "The cover cannot be uncollected here".tl,
              context: context,
            );
            return;
          }
        }
        ImageFavoriteManager().deleteImageFavorite([likedImage]);
        showToast(
          message: "Uncollected the image".tl,
          context: context,
          seconds: 1,
        );
      } else {
        var imageFavoritesComic =
            ImageFavoriteManager().find(id, sourceKey) ??
            ImageFavoritesComic(
              id,
              [],
              title,
              sourceKey,
              tags,
              translatedTags,
              DateTime.now(),
              author,
              {},
              subTitle,
              maxPage,
            );
        ImageFavorite imageFavorite = ImageFavorite(
          page,
          imageKey,
          null,
          eid,
          id,
          ep,
          sourceKey,
          epName,
        );
        ImageFavoritesEp? imageFavoritesEp = imageFavoritesComic
            .imageFavoritesEp
            .firstWhereOrNull((e) {
              return e.ep == ep;
            });
        if (imageFavoritesEp == null) {
          if (page != firstPage) {
            var copy = imageFavorite.copyWith(
              page: firstPage,
              isAutoFavorite: true,
              imageKey: context.reader.images![0],
            );
            // 不是第一页的话, 自动塞一个封面进去
            imageFavoritesEp = ImageFavoritesEp(
              eid,
              ep,
              [copy, imageFavorite],
              epName,
              maxPage,
            );
          } else {
            imageFavoritesEp = ImageFavoritesEp(
              eid,
              ep,
              [imageFavorite],
              epName,
              maxPage,
            );
          }
          imageFavoritesComic.imageFavoritesEp.add(imageFavoritesEp);
        } else {
          if (imageFavoritesEp.eid != eid) {
            // 空字符串说明是从pica导入的, 那我们就手动刷一遍保证一致
            if (imageFavoritesEp.eid == "") {
              imageFavoritesEp.eid == eid;
            } else {
              // 避免多章节漫画源的章节顺序发生变化, 如果情况比较多, 做一个以eid为准更新ep的功能
              showToast(
                message:
                    "The chapter order of the comic may have changed, temporarily not supported for collection"
                        .tl,
                context: context,
              );
              return;
            }
          }
          imageFavoritesEp.imageFavorites.add(imageFavorite);
        }

        ImageFavoriteManager().addOrUpdateOrDelete(imageFavoritesComic);
        showToast(
          message: "Successfully collected".tl,
          context: context,
          seconds: 1,
        );
      }
      update();
    } catch (e, stackTrace) {
      Log.error("Image Favorite", e, stackTrace);
      showToast(message: e.toString(), context: context, seconds: 1);
    }
  }

  Widget buildBottom() {
    // Use maxPage for display (excluding chapter comments page)
    final displayPage = context.reader.page.clamp(1, context.reader.maxPage);
    var text = "E${context.reader.chapter} : P$displayPage";
    if (context.reader.widget.chapters == null) {
      text = "P$displayPage";
    }

    final buttons = [
      Tooltip(
        message: "Collect the image".tl,
        child: IconButton(
          icon: Icon(isLiked() ? Icons.favorite : Icons.favorite_border),
          onPressed: addImageFavorite,
        ),
      ),
      if (App.isDesktop)
        Tooltip(
          message: "${"Full Screen".tl}(F12)",
          child: IconButton(
            icon: const Icon(Icons.fullscreen),
            onPressed: () {
              context.reader.fullscreen();
            },
          ),
        ),
      if (App.isAndroid)
        Tooltip(
          message: "Screen Rotation".tl,
          child: IconButton(
            icon: Icon(switch (readerOrientation) {
              ReaderOrientation.system => Icons.screen_rotation,
              ReaderOrientation.portrait => Icons.screen_lock_portrait,
              ReaderOrientation.landscape => Icons.screen_lock_landscape,
            }),
            onPressed: cycleReaderOrientation,
          ),
        ),
      Tooltip(
        message: 'Reader brightness'.tl,
        child: IconButton(
          icon: Icon(
            context.reader.preferences.readerBrightnessEnabled == true
                ? Icons.brightness_4
                : Icons.brightness_6,
          ),
          color: context.reader.preferences.readerBrightnessEnabled == true
              ? context.colorScheme.primary
              : null,
          onPressed: () {
            setState(() {
              _brightnessPanelOpen = !_brightnessPanelOpen;
            });
          },
        ),
      ),
      Tooltip(
        message: switch (context.reader.autoReading.status) {
          AutoReadingStatus.waiting =>
            'Automatic reading is waiting for content'.tl,
          AutoReadingStatus.paused => 'Automatic reading is paused'.tl,
          _ => 'Start or stop automatic reading'.tl,
        },
        child: IconButton(
          icon: context.reader.autoReading.isActive
              ? const Icon(Icons.pause_circle_outline)
              : const Icon(Icons.play_circle_outline),
          color: context.reader.autoReading.isActive
              ? context.colorScheme.primary
              : null,
          onPressed: () {
            context.reader.autoReading.toggle();
            if (context.reader.autoReading.isActive && isOpen) openOrClose();
            update();
          },
        ),
      ),
      if (context.reader.widget.chapters != null)
        Tooltip(
          message: "Chapters".tl,
          child: IconButton(
            icon: const Icon(Icons.library_books),
            onPressed: openChapterDrawer,
          ),
        ),
      Tooltip(
        message: "Save Image".tl,
        child: IconButton(
          icon: const Icon(Icons.download),
          onPressed: saveCurrentImage,
        ),
      ),
      Tooltip(
        message: "Share".tl,
        child: IconButton(icon: const Icon(Icons.share), onPressed: share),
      ),
    ];

    return ReaderBottomBar(
      label: text,
      actions: buttons,
      page: context.reader.page,
      maxPage: context.reader.maxPage,
      reversed: isReversed,
      isOpen: isOpen,
      onPageChanged: (page) => context.reader.toPage(page, animated: false),
      onPrevious: () => !isReversed
          ? context.reader.chapter > 1
                ? context.reader.toPrevChapter()
                : context.reader.toPage(1)
          : context.reader.chapter < context.reader.maxChapter
          ? context.reader.toNextChapter()
          : context.reader.toPage(context.reader.maxPage),
      onNext: () => !isReversed
          ? context.reader.chapter < context.reader.maxChapter
                ? context.reader.toNextChapter()
                : context.reader.toPage(context.reader.maxPage)
          : context.reader.chapter > 1
          ? context.reader.toPrevChapter()
          : context.reader.toPage(1),
    );
  }

  Widget buildBrightnessPanel() => ReaderBrightnessPanel(
    enabled: context.reader.preferences.readerBrightnessEnabled == true,
    brightness: context.reader.preferences.readerBrightness,
    onEnabledChanged: (enabled) {
      _settingsStore.write(ReaderPreferences.readerBrightnessEnabled, enabled);
      setState(() {});
      appdata.saveData();
    },
    onBrightnessChanged: (brightness) {
      _settingsStore.write(ReaderPreferences.readerBrightness, brightness);
      setState(() {});
    },
    onBrightnessChangeEnd: (_) => appdata.saveData(),
  );

  Widget buildPageInfoText() {
    var epName =
        context.reader.widget.chapters?.titles.elementAtOrNull(
          context.reader.chapter - 1,
        ) ??
        "E${context.reader.chapter}";
    if (epName.length > 8) {
      epName = "${epName.substring(0, 8)}...";
    }
    var pageText = "${context.reader.page}/${context.reader.maxPage}";
    var text = context.reader.widget.chapters != null
        ? "$epName : $pageText"
        : pageText;

    return Positioned(bottom: 13, left: 25, child: ReaderPageInfo(text: text));
  }

  Widget buildStatusInfo() {
    if (context.reader.preferences.enableClockAndBatteryInfoInReader == true) {
      return Positioned(bottom: 13, right: 25, child: const ReaderStatusInfo());
    } else {
      return const SizedBox.shrink();
    }
  }

  void openChapterDrawer() {
    _openSideBar(
      context.reader.widget.chapters!.isGrouped
          ? ReaderGroupedChaptersView(context.reader)
          : ReaderChaptersView(context.reader),
      width: 400,
    );
  }

  late final _imageExporter = ReaderImageExporter(
    select: _selectImageForExport,
    read: (selection) async {
      if (selection.imageKey.startsWith('file://')) {
        return File(selection.imageKey.substring(7)).readAsBytes();
      }
      final file = await CacheManager().findCache(selection.cacheKey);
      if (file == null) throw StateError('Selected image is no longer cached');
      return file.readAsBytes();
    },
    save: (image) async {
      await saveFile(data: image.bytes, filename: image.filename);
    },
    share: (image) => Share.shareFile(
      data: image.bytes,
      filename: image.filename,
      mime: image.type.mime,
    ),
    onError: (error, stack) {
      Log.error('Reader', 'Failed to export image: $error', stack);
      if (mounted) context.showMessage(message: error.toString());
    },
  );

  void saveCurrentImage() => unawaited(_imageExporter.export(sharing: false));
  void share() => unawaited(_imageExporter.export(sharing: true));

  Future<ReaderImageSelection?> _selectImageForExport() async {
    final reader = context.reader;
    final images = reader.images;
    final chapter = reader.chapter;
    final chapterId = reader.eid;
    final title = reader.widget.name;
    final comicId = reader.cid;
    final sourceKey = reader.type.sourceKey;
    final index = await selectImage();
    if (!mounted ||
        index == null ||
        images == null ||
        !identical(images, reader.images) ||
        chapter != reader.chapter ||
        index < 0 ||
        index >= images.length) {
      return null;
    }
    return ReaderImageSelection(
      imageKey: images[index],
      sourceKey: sourceKey,
      comicId: comicId,
      chapterId: chapterId,
      title: title,
      chapter: chapter,
      imageNumber: index + 1,
    );
  }

  void openSetting() {
    setState(() {
      _brightnessPanelOpen = false;
    });
    _openSideBar(
      ReaderSettings(
        comicId: context.reader.cid,
        comicSource: context.reader.type.sourceKey,
        currentReaderMode: () => context.reader.mode.key,
        isDetectingLayout: () => context.reader.isDetectingLayout,
        onDetectLayout: () => context.reader.detectLayout(force: true),
        onChanged: (key) {
          if (key == "readerMode") {
            context.reader.applyReadingMode(
              ReaderMode.fromKey(context.reader.preferences.readerMode),
            );
            addDragListener();
            context.reader.detectLayout();
          }
          if (key == "enableTurnPageByVolumeKey") {
            if (context.reader.preferences.enableTurnPageByVolumeKey) {
              context.reader.handleVolumeEvent();
            } else {
              context.reader.stopVolumeEvent();
            }
          }
          if (key == "quickCollectImage") {
            addDragListener();
          }
          if (key.startsWith('eInkRefresh')) {
            resetEInkRefreshCounter();
          }
          if (key.startsWith('readerBrightness')) {
            update();
          }
          if (key == "showChapterComments" ||
              key == "showChapterCommentsAtEnd") {
            update();
          }
          if (key == "showSystemStatusBar") {
            _applySystemUiMode();
            update();
          }
          if (key == "showPageNumberInReader" ||
              key == "enableClockAndBatteryInfoInReader") {
            update();
          }
          context.reader.update();
        },
      ),
      width: 400,
    );
  }

  void _openSideBar(Widget widget, {double width = 400}) {
    context.reader.autoReading.pause('sidebar', true);
    gestureDetectorState?.ignoreNextTap();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showSideBar(
        context,
        widget,
        width: width,
        dismissible: true,
      ).whenComplete(() {
        if (!mounted) return;
        context.reader.autoReading.pause('sidebar', false);
        gestureDetectorState?.clearIgnoreNextTap();
      });
    });
  }

  bool shouldShowChapterComments() {
    // Check if chapters exist
    if (context.reader.widget.chapters == null) return false;

    // Check if setting is enabled
    var showChapterComments = context.reader.preferences.showChapterComments;
    if (showChapterComments != true) return false;

    // Check if comic source supports chapter comments
    var source = ComicSource.find(context.reader.type.sourceKey);
    if (source == null || source.chapterCommentsLoader == null) return false;

    return true;
  }

  void openChapterComments() {
    var source = ComicSource.find(context.reader.type.sourceKey);
    if (source == null) return;

    var chapters = context.reader.widget.chapters;
    if (chapters == null) return;

    var chapterIndex = context.reader.chapter - 1;
    var epId = chapters.ids.elementAt(chapterIndex);
    var chapterTitle = chapters.titles.elementAt(chapterIndex);

    showSideBar(
      context,
      ChapterCommentsPage(
        comicId: context.reader.cid,
        epId: epId,
        source: source,
        comicTitle: context.reader.widget.name,
        chapterTitle: chapterTitle,
      ),
    );
  }

  Widget buildEpChangeButton() {
    final extraWidth = context.padding.left + context.padding.right;
    if (context.reader.widget.chapters == null) return const SizedBox();
    switch (showFloatingButtonValue) {
      case 0:
        return Container(
          width: 58 + extraWidth,
          height: 58,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(
            lastValue == 1
                ? Icons.arrow_forward_ios
                : Icons.arrow_back_ios_outlined,
            size: 24,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        );
      case -1:
      case 1:
        return SizedBox(
          width: 58 + extraWidth,
          height: 58,
          child: Material(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
            elevation: 2,
            child: ClickInkWell(
              onTap: () {
                if (showFloatingButtonValue == 1) {
                  context.reader.toNextChapter();
                } else if (showFloatingButtonValue == -1) {
                  context.reader.toPrevChapter();
                }
                setFloatingButton(0);
              },
              borderRadius: BorderRadius.circular(16),
              child: Center(
                child: Icon(
                  _getArrowIcon(isReversed, showFloatingButtonValue),
                  size: 24,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
        );
    }
    return const SizedBox();
  }

  IconData _getArrowIcon(bool reversed, int value) {
    if (reversed) {
      return value == 1
          ? Icons.arrow_back_ios_outlined
          : Icons.arrow_forward_ios;
    } else {
      return value == 1
          ? Icons.arrow_forward_ios
          : Icons.arrow_back_ios_outlined;
    }
  }

  /// If there is only one image on screen, return it.
  ///
  /// If there are multiple images on screen,
  /// show an overlay to let the user select an image.
  ///
  /// The return value is the index of the selected image.
  Future<int?> selectImage() async {
    var reader = context.reader;
    var imageViewController = reader.imageViewController;
    final images = reader.images;
    final chapter = reader.chapter;

    if (imageViewController == null || images == null) return null;
    final range = imageViewController.currentImageRange;
    if (range != null && range.$2 - range.$1 == 1) {
      return range.$1 >= 0 && range.$2 <= images.length ? range.$1 : null;
    } else {
      var location = await _showSelectImageOverlay();
      if (!mounted ||
          location == null ||
          !identical(imageViewController, reader.imageViewController) ||
          !identical(images, reader.images) ||
          chapter != reader.chapter) {
        return null;
      }
      var imageKey = imageViewController.getImageKeyByOffset(location);
      if (imageKey == null) {
        return null;
      }
      final index = images.indexOf(imageKey);
      return index < 0 ? null : index;
    }
  }

  final _selectionOverlay = ReaderImageSelectionOverlay();

  Future<Offset?> _showSelectImageOverlay() {
    if (_isOpen) openOrClose();
    return _selectionOverlay.show(context);
  }
}
