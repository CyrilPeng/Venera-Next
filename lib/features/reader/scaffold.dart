import 'dart:async';
import 'package:venera_next/components/settings_save_state.dart';

import 'package:venera_next/features/reader/status_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/features/reader/progress_bar.dart';
import 'package:venera_next/features/reader/bottom_actions.dart';
import 'package:venera_next/features/reader/top_bar.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/features/reader/sidebar_binding.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/history/image_favorite_actions.dart';
import 'package:venera_next/features/reader/brightness.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/chapter_comments.dart';
import 'package:venera_next/features/reader/chapters.dart';
import 'package:venera_next/features/reader/eink_refresh.dart';
import 'package:venera_next/features/reader/gesture_port.dart';
import 'package:venera_next/features/reader/image_favorite_swipe.dart';
import 'package:venera_next/features/reader/orientation.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/features/reader/image_export.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/features/reader/settings_effects.dart';
import 'package:venera_next/features/reader/image_selection.dart';
import 'package:venera_next/features/reader/image_picker.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/routing/settings.dart';

class ReaderScaffold extends StatefulWidget {
  const ReaderScaffold({
    super.key,
    required this.imageWork,
    required this.child,
  });

  final ImageWork imageWork;
  final Widget child;

  @override
  State<ReaderScaffold> createState() => ReaderScaffoldState();
}

class ReaderScaffoldState extends State<ReaderScaffold>
    with ReaderOrientationState {
  var _brightnessPreview = ReaderBrightnessPreview();
  (String, String)? _brightnessTarget;

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

  ReaderGesturePort? _gesturePort;
  ReaderGesturePort? get gestureDetectorState => _gesturePort;
  set gestureDetectorState(ReaderGesturePort? port) {
    _gesturePort = port;
    _imageFavoriteSwipe.attach(port);
    if (port != null && mounted) addDragListener();
  }

  late final _imageFavoriteSwipe = ImageFavoriteSwipeBinding(
    isVertical: () => context.reader.mode.isTopToBottom,
    collect: addImageFavorite,
  );

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

  void addDragListener() {
    if (!mounted) return;
    _imageFavoriteSwipe.setEnabled(
      appdata.settings.globalReaderSettings.quickCollectImage == 'Swipe',
    );
  }

  @override
  void initState() {
    super.initState();
    _brightnessPreview.addListener(update);
    ImageFavoriteManager().addListener(_imageFavoritesChanged);
  }

  @override
  void dispose() {
    _brightnessPreview.dispose();
    ImageFavoriteManager().removeListener(_imageFavoritesChanged);
    _collectTask?.cancel();
    _sidebarBinding.dispose();
    _imageFavoriteSwipe.dispose();
    _gesturePort = null;
    unawaited(_exporter?.dispose());
    _imagePicker.dispose();
    _selectionOverlay.dispose();
    _eInkRefreshController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ReaderScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.imageWork, widget.imageWork)) {
      _replaceBrightnessPreview();
      _collectTask?.cancel();
      unawaited(_exporter?.dispose());
      _exporter = null;
    }
  }

  void _replaceBrightnessPreview() {
    _sidebarBinding.close();
    _brightnessPreview.dispose();
    _brightnessPreview = ReaderBrightnessPreview()..addListener(update);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final target = (context.reader.cid, context.reader.type.sourceKey);
    if (_brightnessTarget != null && _brightnessTarget != target) {
      _replaceBrightnessPreview();
    }
    _brightnessTarget = target;
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
                  _brightnessPreview.enabled ??
                  context.reader.preferences.readerBrightnessEnabled,
              brightness:
                  _brightnessPreview.brightness ??
                  context.reader.preferences.readerBrightness,
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
              : -context.height,
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
    onBack: () => unawaited(context.reader.requestExit()),
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

  ImageWorkTask? _collectTask;
  int _favoriteRevision = 0;
  (String, String, String, int, int)? _favoriteQuery;
  Future<bool>? _favoriteStatus;

  void _imageFavoritesChanged() {
    _favoriteRevision++;
    if (mounted) update();
  }

  void addImageFavorite() async {
    if (_collectTask != null) return;
    final task = widget.imageWork.start(
      cancelSelection: _selectionOverlay.cancel,
    );
    if (task == null) return;
    _collectTask = task;
    update();
    try {
      if (context.reader.images![0].contains('file://')) {
        showToast(
          message: "Local comic collection is not supported at present".tl,
          context: context,
        );
        return;
      }
      final id = context.reader.cid;
      final ep = context.reader.chapter;
      final eid = context.reader.eid;
      final title = context.reader.history!.title;
      final subtitle = context.reader.history!.subtitle;
      final maxPage = context.reader.images!.length;
      final selection = await task.select(_imagePicker.pick);
      if (!mounted ||
          selection == null ||
          !selection.isCurrent(_imagePickContext())) {
        return;
      }
      final index = selection.index;
      final reader = context.reader;
      final result = await ImageFavoriteManager().toggle(
        ImageFavoriteInput(
          id: id,
          sourceKey: reader.type.sourceKey,
          eid: eid,
          ep: ep,
          epName:
              reader.widget.chapters?.titles.elementAtOrNull(
                reader.chapter - 1,
              ) ??
              "E${reader.chapter}",
          title: title,
          subtitle: subtitle,
          author: reader.widget.author,
          tags: List.of(reader.widget.tags),
          translatedTags: reader.widget.tags
              .map((e) => e.translateTagsToCN)
              .toList(),
          maxPage: maxPage,
          page: index + 1,
          imageKey: reader.images![index],
          coverKey: reader.images![0],
        ),
        checkActive: () {
          task.check();
          if (!mounted || !selection.isCurrent(_imagePickContext())) {
            throw const ImageWorkTaskCancelled();
          }
        },
      );
      if (!mounted ||
          task.isCancelled ||
          !selection.isCurrent(_imagePickContext())) {
        return;
      }
      switch (result) {
        case ImageFavoriteResult.protectedCover:
          showToast(
            message: "The cover cannot be uncollected here".tl,
            context: context,
          );
          return;
        case ImageFavoriteResult.chapterOrderChanged:
          showToast(
            message:
                "The chapter order of the comic may have changed, temporarily not supported for collection"
                    .tl,
            context: context,
          );
          return;
        case ImageFavoriteResult.collected:
          showToast(
            message: "Successfully collected".tl,
            context: context,
            seconds: 1,
          );
        case ImageFavoriteResult.uncollected:
          showToast(
            message: "Uncollected the image".tl,
            context: context,
            seconds: 1,
          );
      }
      update();
    } catch (e, stackTrace) {
      if (e is! ImageWorkTaskCancelled) {
        Log.error("Image Favorite", e, stackTrace);
        if (!mounted || task.isCancelled) {
          task.recordFailure(e, stackTrace);
        } else {
          showToast(message: e.toString(), context: context, seconds: 1);
        }
      }
    } finally {
      task.finish();
      if (identical(_collectTask, task)) _collectTask = null;
      if (mounted) update();
    }
  }

  Widget buildBottom() {
    final reader = context.reader;
    final query = (
      reader.cid,
      reader.type.sourceKey,
      reader.eid,
      reader.page,
      _favoriteRevision,
    );
    if (_favoriteQuery != query) {
      _favoriteQuery = query;
      _favoriteStatus = ImageFavoriteManager().isCollected(
        query.$1,
        query.$2,
        query.$3,
        query.$4,
      );
    }
    return FutureBuilder<bool>(
      key: ValueKey(query),
      future: _favoriteStatus,
      builder: (context, snapshot) => _buildBottom(
        snapshot.data ?? false,
        loading: snapshot.connectionState != ConnectionState.done,
      ),
    );
  }

  Widget _buildBottom(bool collected, {required bool loading}) {
    // Use maxPage for display (excluding chapter comments page)
    final displayPage = context.reader.page.clamp(1, context.reader.maxPage);
    var text = "E${context.reader.chapter} : P$displayPage";
    if (context.reader.widget.chapters == null) {
      text = "P$displayPage";
    }

    final buttons = buildReaderBottomActions(
      context,
      imageCollected: collected,
      imageCollecting: _collectTask != null,
      onCollect: loading || _collectTask != null ? null : addImageFavorite,
      onFullscreen: App.isDesktop ? () => context.reader.fullscreen() : null,
      orientation: readerOrientation,
      onRotate: App.isAndroid ? cycleReaderOrientation : null,
      brightnessEnabled:
          _brightnessPreview.enabled ??
          context.reader.preferences.readerBrightnessEnabled,
      onBrightness: () =>
          setState(() => _brightnessPanelOpen = !_brightnessPanelOpen),
      automaticReading: ReaderAutomaticReadingAction(
        tooltip: switch (context.reader.autoReading.status) {
          AutoReadingStatus.waiting =>
            'Automatic reading is waiting for content'.tl,
          AutoReadingStatus.paused => 'Automatic reading is paused'.tl,
          _ => 'Start or stop automatic reading'.tl,
        },
        active: context.reader.autoReading.isActive,
        playing: context.reader.autoReading.isActive,
        onPressed: () {
          context.reader.autoReading.toggle();
          if (context.reader.autoReading.isActive && isOpen) openOrClose();
          update();
        },
      ),
      onChapters: context.reader.widget.chapters != null
          ? openChapterDrawer
          : null,
      onSave: saveCurrentImage,
      onShare: share,
    );

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

  Widget buildBrightnessPanel() => SettingsSaveScope(
    work: widget.imageWork,
    child: ReaderBrightnessSetting(
      comicId: context.reader.cid,
      sourceKey: context.reader.type.sourceKey,
      preview: _brightnessPreview,
      panel: true,
      onChanged: _onSettingChanged,
    ),
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

  ReaderImageExporter? _exporter;
  ReaderImageExporter get _imageExporter => _exporter ??= ReaderImageExporter(
    work: widget.imageWork,
    cancelSelection: _selectionOverlay.cancel,
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
      await saveFile(
        data: image.bytes,
        filename: image.filename,
        checkStop: image.checkStop,
      );
    },
    share: (image) => Share.shareFile(
      data: image.bytes,
      filename: image.filename,
      mime: image.type.mime,
      resolveOrigin: () => context.sharePositionOrigin,
      checkStop: image.checkStop,
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
    final chapter = reader.chapter;
    final chapterId = reader.eid;
    final title = reader.widget.name;
    final comicId = reader.cid;
    final sourceKey = reader.type.sourceKey;
    final selection = await _imagePicker.pick();
    if (selection == null || !selection.isCurrent(_imagePickContext())) {
      return null;
    }
    final index = selection.index;
    return ReaderImageSelection(
      imageKey: selection.context.images[index],
      sourceKey: sourceKey,
      comicId: comicId,
      chapterId: chapterId,
      title: title,
      chapter: chapter,
      imageNumber: index + 1,
    );
  }

  void openSetting() {
    final reader = context.reader;
    final work = widget.imageWork;
    final comic = reader.cid, source = reader.type.sourceKey;
    bool isCurrent() =>
        mounted &&
        identical(widget.imageWork, work) &&
        identical(context.reader, reader) &&
        reader.cid == comic &&
        reader.type.sourceKey == source;
    setState(() {
      _brightnessPanelOpen = false;
    });
    _openSideBar(
      SettingsSaveScope(
        work: work,
        child: ReaderSettings(
          comicId: comic,
          comicSource: source,
          currentReaderMode: () => reader.mode.key,
          isDetectingLayout: () => isCurrent() && reader.isDetectingLayout,
          onDetectLayout: () =>
              isCurrent() ? reader.detectLayout(force: true) : Future.value(),
          onChanged: (key) {
            if (isCurrent()) _onSettingChanged(key);
          },
          brightnessPreview: _brightnessPreview,
        ),
      ),
      width: 400,
    );
  }

  void _onSettingChanged(String key) {
    for (final effect in readerSettingEffects(key)) {
      if (!mounted) return;
      switch (effect) {
        case ReaderSettingEffect.applyMode:
          context.reader.applyReadingMode(
            ReaderMode.fromKey(context.reader.preferences.readerMode),
          );
        case ReaderSettingEffect.rebindImageGesture:
          addDragListener();
        case ReaderSettingEffect.detectLayout:
          context.reader.detectLayout();
        case ReaderSettingEffect.updateVolumeListener:
          if (context.reader.preferences.enableTurnPageByVolumeKey) {
            context.reader.handleVolumeEvent();
          } else {
            context.reader.stopVolumeEvent();
          }
        case ReaderSettingEffect.resetEInk:
          resetEInkRefreshCounter();
        case ReaderSettingEffect.updateSystemUi:
          _applySystemUiMode();
        case ReaderSettingEffect.rebuildShell:
          update();
        case ReaderSettingEffect.rebuildReader:
          context.reader.update();
      }
    }
  }

  final _sidebarPauseReason = Object();
  late final _sidebarBinding = ReaderSidebarBinding(
    canOpen: () => mounted,
    acquireInteraction: () {
      final reader = context.reader;
      final gesture = gestureDetectorState;
      reader.autoReading.pause(_sidebarPauseReason, true);
      gesture?.ignoreNextTap();
      return () {
        try {
          if (reader.mounted) {
            reader.autoReading.pause(_sidebarPauseReason, false);
          }
        } finally {
          gesture?.clearIgnoreNextTap();
        }
      };
    },
    onError: (error, stack) {
      Log.error('Reader', 'Failed to open sidebar: $error', stack);
      if (mounted) context.showMessage(message: error.toString());
    },
  );

  void _openSideBar(Widget widget, {double width = 400}) =>
      _sidebarBinding.show(context, widget, width: width);

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

    _openSideBar(
      ChapterCommentsPage(
        comicId: context.reader.cid,
        epId: epId,
        source: source,
        comicTitle: context.reader.widget.name,
        chapterTitle: chapterTitle,
      ),
      width: 500,
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

  ReaderImagePickContext? _imagePickContext() {
    if (!mounted) return null;
    final reader = context.reader;
    final viewport = reader.imageViewController;
    final images = reader.images;
    if (viewport == null || images == null) return null;
    return ReaderImagePickContext(
      viewport: viewport,
      images: images,
      chapter: reader.chapter,
    );
  }

  late final _imagePicker = ReaderImagePicker(
    current: _imagePickContext,
    selectPosition: _showSelectImageOverlay,
  );

  final _selectionOverlay = ReaderImageSelectionOverlay();

  Future<Offset?> _showSelectImageOverlay() {
    if (_isOpen) openOrClose();
    return _selectionOverlay.show(context);
  }
}
