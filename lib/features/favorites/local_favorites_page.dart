import 'package:venera_next/features/history/history_scope.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/keyword_filter.dart';
import 'package:venera_next/components/file_save_task.dart';
import 'favorite_models.dart';
import 'favorite_folder.dart';
import 'favorite_folder_path.dart';
import 'folder_move_dialog.dart';
import 'folder_order_dialog.dart';
import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals, mapEquals;
import 'package:flutter/services.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/flyout.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_details/comic_details.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/features/favorites/favorite_actions.dart';
import 'package:venera_next/features/favorites/favorites_display.dart';
import 'package:venera_next/features/favorites/favorites_constants.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/favorites/comic_reorder_page.dart';
import 'package:venera_next/features/favorites/folder_rename_dialog.dart';
import 'package:venera_next/features/favorites/favorite_confirmation_dialog.dart';
import 'package:venera_next/features/favorites/favorite_transfer_dialog.dart';
import 'package:venera_next/features/favorites/favorite_metadata_dialog.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/reader/reader.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/app_locale.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/consts.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/opencc.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

/// If the number of comics in a folder exceeds this limit, it will be
/// fetched asynchronously.
const _asyncDataFetchLimit = 500;

class LocalFavoritesPage extends StatefulWidget {
  const LocalFavoritesPage({
    required this.folder,
    required this.showFolders,
    required this.onFolderSelected,
    required this.updateFolderList,
    this.importFolder = importNetworkFolder,
    super.key,
  });

  final String folder;
  final VoidCallback showFolders;
  final void Function(bool isNetwork, String? folder) onFolderSelected;
  final VoidCallback updateFolderList;
  final Future<void> Function(
    BuildContext context,
    String source,
    int pages,
    String folder,
    String remoteFolder,
  )
  importFolder;

  @override
  State<LocalFavoritesPage> createState() => _LocalFavoritesPageState();
}

class _LocalFavoritesPageState extends State<LocalFavoritesPage> {
  late List<FavoriteItem> comics;

  String? networkSource;
  String? networkFolder;

  Map<Comic, bool> selectedComics = {};

  String keyword = "";
  bool searchHasUpper = false;
  final _searchController = TextEditingController();

  bool searchMode = false;

  bool multiSelectMode = false;

  int? lastSelectedIndex;

  bool get isAllFolder => widget.folder == localAllFolderLabel;

  LocalFavoritesManager get manager => _store.manager;

  late final FavoriteStoreBinding _store;

  late final LocalFavoritesManager _observedManager;
  late final int _observedGeneration;
  late final String _observedDataPath;
  WindowSelectionTask? _queryOwner;
  final _metadataTasks = <WindowSelectionTask>{};

  bool get _canReadObservedFolder =>
      mounted &&
      _queryOwner?.active == true &&
      _store.isCurrent &&
      _observedManager.connectionGeneration == _observedGeneration &&
      App.dataPath == _observedDataPath;

  bool isLoading = false;
  int _queryGeneration = 0;
  int _filterRequest = 0;
  ModalRoute<dynamic>? _updateFlyoutRoute;
  Object? _loadError;
  bool _comicsDirty = true;
  List<FavoriteItem>? _pendingComics;
  bool _tickerEnabled = true;
  final _parentRoutes = <ModalRoute<dynamic>>[];
  bool _parentWasCovered = false;
  FocusScopeNode? _routeFocus;
  bool _routeHadFocus = false;

  late String readFilterSelect;

  HistoryManager? _history;
  Set<(String, int)>? _completed;
  List<FavoriteItem>? _completionInput;
  int _readingGeneration = 0;
  bool _readingLoading = false;
  Object? _readingError;
  List<FavoriteItem>? _displayedCache;
  List<FavoriteItem>? _visibleCache;
  List<FavoriteItem>? _visibleInput;
  List<FavoriteItem>? _gridInput;
  List<FavoriteItem>? _gridVisibleInput;
  Map<Comic, bool>? _gridSelection;
  String? _gridFolder;
  Widget? _comicGrid;
  late var _keywordFilter = KeywordFilter.fromSettings(appdata.settings);
  late var _blockDisplayMode = appdata.settings['comicDisplayMode'];
  final _blockedCache = Map<FavoriteItem, bool>.identity();

  bool get _canRefresh =>
      _tickerEnabled &&
      _queryOwner?.canPresent == true &&
      _parentRoutes.every((route) => route.isCurrent);

  bool get _hasReadingFilter =>
      readFilterSelect == 'UnCompleted' || readFilterSelect == 'Completed';

  bool get _usesReadingFilter => !searchMode && _hasReadingFilter;

  bool get _isFiltering => _usesReadingFilter && _readingLoading;

  bool get _hasListError =>
      _loadError != null || (_usesReadingFilter && _readingError != null);

  void _invalidateDisplay() {
    _displayedCache = null;
    _visibleCache = null;
    _visibleInput = null;
  }

  List<FavoriteItem> get _displayedComics => searchMode
      ? searchResults
      : _hasReadingFilter
      ? _displayedCache ?? const []
      : comics;

  var searchResults = <FavoriteItem>[];

  void updateSearchResult() {
    setState(_refreshSearchResults);
  }

  void _refreshSearchResults() {
    if (keyword.trim().isEmpty) {
      searchResults = comics;
    } else {
      final variants =
          <String>{
                keyword,
                if (OpenCC.hasChineseSimplified(keyword))
                  OpenCC.simplifiedToTraditional(keyword),
                if (OpenCC.hasChineseTraditional(keyword))
                  OpenCC.traditionalToSimplified(keyword),
              }
              .map(
                (value) =>
                    value.split(' ').where((word) => word.isNotEmpty).toList(),
              )
              .toList();
      searchResults = [];
      for (var comic in comics) {
        if (variants.any((words) => _matchSearchWords(words, comic))) {
          searchResults.add(comic);
        }
      }
    }
  }

  void _replaceComics(List<FavoriteItem> value) {
    comics = value;
    _blockedCache.clear();
    _invalidateCompletion();
    _invalidateDisplay();
    if (searchMode) _refreshSearchResults();
    _refreshReadingFilter();
    _reconcileSelection();
  }

  List<FavoriteItem> get _visibleComics {
    final displayed = _displayedComics;
    if (identical(_visibleInput, displayed) && _visibleCache != null) {
      return _visibleCache!;
    }
    _visibleInput = displayed;
    if (_keywordFilter.rules.isEmpty) return _visibleCache = displayed;
    final visible = displayed
        .where(
          (comic) => !_blockedCache.putIfAbsent(
            comic,
            () => isBlocked(comic, filter: _keywordFilter) != null,
          ),
        )
        .toList();
    return _visibleCache = visible.length == displayed.length
        ? displayed
        : visible;
  }

  void _prepareComicGrid(List<FavoriteItem> input, List<FavoriteItem> visible) {
    if (!identical(input, _gridInput) ||
        !identical(visible, _gridVisibleInput) ||
        _gridFolder != widget.folder ||
        !mapEquals(selectedComics, _gridSelection)) {
      _gridInput = input;
      _gridVisibleInput = visible;
      _gridFolder = widget.folder;
      _gridSelection = Map<Comic, bool>.unmodifiable(selectedComics);
      _comicGrid = null;
    }
  }

  void _reconcileSelection() {
    if (!_canRefresh || _isFiltering) return;
    lastSelectedIndex = null;
    if (selectedComics.isEmpty) return;
    selectedComics = {
      for (final comic in _visibleComics)
        if (selectedComics[comic] == true) comic: true,
    };
    if (selectedComics.isEmpty) multiSelectMode = false;
  }

  void _onSettingsChanged() {
    final filter = KeywordFilter.fromSettings(appdata.settings);
    final displayMode = appdata.settings['comicDisplayMode'];
    if (_canReadObservedFolder &&
        (!listEquals(filter.rules, _keywordFilter.rules) ||
            displayMode != _blockDisplayMode)) {
      _keywordFilter = filter;
      _blockDisplayMode = displayMode;
      _blockedCache.clear();
      _visibleCache = null;
      _visibleInput = null;
      if (_canRefresh) setState(_reconcileSelection);
    }
  }

  void _onHistoryChanged() {
    if (!_canReadObservedFolder) return;
    _invalidateCompletion();
    if (_usesReadingFilter && _canRefresh) {
      setState(_refreshReadingFilter);
    }
  }

  void updateComics({bool force = false}) {
    if (!_canReadObservedFolder) return;
    _comicsDirty = true;
    _pendingComics = null;
    ++_queryGeneration;
    if (!_canRefresh && !force) return;
    _loadComics();
  }

  void _loadComics() {
    _comicsDirty = false;
    final manager = _observedManager;
    final generation = ++_queryGeneration;
    final folder = widget.folder;
    _loadError = null;
    isLoading = false;
    try {
      final count = isAllFolder
          ? manager.totalComics
          : manager.folderComics(folder);
      if (!isAllFolder && !manager.existsFolder(folder)) {
        _replaceComics([]);
      } else if (count < _asyncDataFetchLimit) {
        _replaceComics(
          isAllFolder
              ? manager.getAllComics()
              : manager.getFolderComics(folder),
        );
      } else {
        isLoading = true;
        final reading = isAllFolder
            ? manager.getAllComicsAsync()
            : manager.getFolderComicsAsync(folder);
        unawaited(
          reading.then<void>(
            (value) {
              if (!_canReadObservedFolder ||
                  generation != _queryGeneration ||
                  widget.folder != folder) {
                return;
              }
              isLoading = false;
              if (_canRefresh) {
                setState(() => _replaceComics(value));
              } else {
                _pendingComics = value;
              }
            },
            onError: (Object error, StackTrace stack) {
              Log.error('Favorites query', error, stack);
              if (!_canReadObservedFolder ||
                  generation != _queryGeneration ||
                  widget.folder != folder) {
                return;
              }
              isLoading = false;
              _loadError = error;
              if (_canRefresh) setState(() {});
            },
          ),
        );
      }
    } catch (error, stack) {
      Log.error('Favorites query', error, stack);
      _loadError = error;
    }
    setState(() {});
  }

  void _invalidateCompletion() {
    ++_readingGeneration;
    _completed = null;
    _completionInput = null;
    _readingLoading = false;
    _readingError = null;
  }

  void _applyReadingFilter() {
    final completed = _completed!;
    final showCompleted = readFilterSelect == 'Completed';
    _displayedCache = comics
        .where(
          (comic) =>
              completed.contains((comic.id, comic.type.value)) == showCompleted,
        )
        .toList();
    _visibleCache = null;
    _visibleInput = null;
  }

  void _refreshReadingFilter() {
    if (!_canReadObservedFolder ||
        !_canRefresh ||
        !_usesReadingFilter ||
        _comicsDirty ||
        isLoading) {
      return;
    }
    if (identical(_completionInput, comics) && _completed != null) {
      if (_displayedCache == null) _applyReadingFilter();
      return;
    }
    if (_readingLoading || _readingError != null) return;
    final input = comics;
    final history = _history;
    if (input.isEmpty || history?.isInitialized != true) {
      _completionInput = input;
      _completed = const {};
      _applyReadingFilter();
      return;
    }
    final request = ++_readingGeneration;
    final historyGeneration = history!.connectionGeneration;
    _readingLoading = true;
    bool isCurrent() =>
        _canReadObservedFolder &&
        request == _readingGeneration &&
        identical(input, comics) &&
        identical(history, _history) &&
        history.connectionGeneration == historyGeneration;
    unawaited(
      history
          .completedAmongAsync(
            input.map((comic) => (comic.id, comic.type.value)),
          )
          .then<void>(
            (completed) {
              if (!isCurrent()) return;
              _readingLoading = false;
              _completionInput = input;
              _completed = completed;
              if (_canRefresh && _usesReadingFilter) {
                setState(() {
                  _applyReadingFilter();
                  _reconcileSelection();
                });
              } else {
                _displayedCache = null;
              }
            },
            onError: (Object error, StackTrace stack) {
              if (!isCurrent()) return;
              Log.error('Favorite reading filter', error, stack);
              _readingLoading = false;
              _readingError = error;
              if (_canRefresh && _usesReadingFilter) setState(() {});
            },
          ),
    );
  }

  void _resumeVisibleWork() {
    if (!_canReadObservedFolder || !_canRefresh) return;
    _parentWasCovered = false;
    if (_comicsDirty) {
      _loadComics();
      return;
    }
    final pending = _pendingComics;
    if (pending != null) {
      _pendingComics = null;
      _replaceComics(pending);
    }
    _refreshReadingFilter();
    _reconcileSelection();
  }

  bool _matchSearchWords(Iterable<String> words, FavoriteItem comic) {
    for (var k in words) {
      if (k.isEmpty) continue;
      if (checkKeyWordMatch(k, comic.title, false)) {
        continue;
      } else if (comic.subtitle != null &&
          checkKeyWordMatch(k, comic.subtitle!, false)) {
        continue;
      } else if (comic.tags.any((tag) {
        if (checkKeyWordMatch(k, tag, true)) {
          return true;
        } else if (tag.contains(':') &&
            checkKeyWordMatch(k, tag.split(':')[1], true)) {
          return true;
        } else if (appLocale.languageCode != 'en' &&
            checkKeyWordMatch(k, tag.translateTagsToCN, true)) {
          return true;
        }
        return false;
      })) {
        continue;
      } else if (checkKeyWordMatch(k, comic.author, true)) {
        continue;
      }
      return false;
    }
    return true;
  }

  bool checkKeyWordMatch(String keyword, String compare, bool needEqual) {
    String temp = compare;
    // 没有大写的话, 就转成小写比较, 避免搜索需要注意大小写
    if (!searchHasUpper) {
      temp = temp.toLowerCase();
    }
    if (needEqual) {
      return keyword == temp;
    }
    return temp.contains(keyword);
  }

  @override
  void initState() {
    super.initState();
    _store = FavoritesScope.capture(context);
    _observedManager = _store.manager;
    _observedGeneration = _observedManager.connectionGeneration;
    _observedDataPath = App.dataPath;
    readFilterSelect =
        appdata.implicitData["local_favorites_read_filter"] ??
        readFilterList[0];
    if (!isAllFolder) {
      var (a, b) = _observedManager.findLinked(widget.folder);
      networkSource = a;
      networkFolder = b;
    } else {
      networkSource = null;
      networkFolder = null;
    }
    comics = [];
    _keywordFilter = KeywordFilter.fromSettings(appdata.settings);
    _observedManager.addListener(updateComics);
    appdata.settings.addListener(_onSettingsChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    final routeFocus = FocusScope.of(context, createDependency: false);
    if (!identical(routeFocus, _routeFocus)) {
      _routeFocus?.removeListener(_onRouteFocusChanged);
      _routeFocus = routeFocus;
      _routeHadFocus = routeFocus.hasFocus;
      routeFocus.addListener(_onRouteFocusChanged);
    }
    final parents = <ModalRoute<dynamic>>[];
    var route = ModalRoute.of(context);
    while (route != null && !parents.contains(route)) {
      parents.add(route);
      final navigatorContext = route.navigator?.context;
      route = navigatorContext == null ? null : ModalRoute.of(navigatorContext);
    }
    if (!listEquals(parents, _parentRoutes)) {
      for (final parent in _parentRoutes.skip(1)) {
        parent.secondaryAnimation?.removeStatusListener(_onParentTransition);
      }
      _parentRoutes
        ..clear()
        ..addAll(parents);
      _parentWasCovered = _parentRoutes
          .skip(1)
          .any((parent) => !parent.isCurrent);
      for (final parent in _parentRoutes.skip(1)) {
        parent.secondaryAnimation?.addStatusListener(_onParentTransition);
      }
    }
    final history =
        context.dependOnInheritedWidgetOfExactType<HistoryScope>()?.manager ??
        HistoryScope.read(context);
    if (!identical(history, _history)) {
      _history?.removeListener(_onHistoryChanged);
      _history = history..addListener(_onHistoryChanged);
      _invalidateCompletion();
      _invalidateDisplay();
    }
    if (_queryOwner != null) {
      _resumeVisibleWork();
      return;
    }
    _queryOwner = WindowSelectionTask(context);
    updateComics();
  }

  void _onParentTransition(AnimationStatus status) {
    _resumeAfterCover();
  }

  void _onRouteFocusChanged() {
    final hasFocus = _routeFocus?.hasFocus == true;
    if (hasFocus == _routeHadFocus) return;
    _routeHadFocus = hasFocus;
    // Root popups need not drive the parent route's secondary animation.
    _resumeAfterCover();
  }

  void _resumeAfterCover() {
    if (_parentRoutes.any((parent) => !parent.isCurrent)) {
      _parentWasCovered = true;
      return;
    }
    if (!_parentWasCovered) return;
    _parentWasCovered = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_canReadObservedFolder) return;
      if (!_canRefresh) {
        _parentWasCovered = true;
        return;
      }
      setState(() {
        _comicGrid = null;
        _resumeVisibleWork();
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _retireUpdateFlyout() {
    final route = _updateFlyoutRoute;
    _updateFlyoutRoute = null;
    scheduleMicrotask(() {
      final navigator = route?.navigator;
      if (navigator?.mounted == true && route!.isActive) {
        navigator!.removeRoute(route);
      }
    });
  }

  @override
  void didUpdateWidget(LocalFavoritesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.folder != widget.folder) {
      _cancelMetadataUpdates();
      _filterRequest++;
      selectedComics.clear();
      lastSelectedIndex = null;
      multiSelectMode = false;
      searchMode = false;
      keyword = '';
      _searchController.clear();
      final linked = isAllFolder || !_canReadObservedFolder
          ? (null, null)
          : _observedManager.findLinked(widget.folder);
      networkSource = linked.$1;
      networkFolder = linked.$2;
      // A replacement folder is an explicit widget input, not a background
      // notification. Never retain the previous folder under its new label.
      updateComics(force: true);
    }
    if (oldWidget.folder != widget.folder ||
        oldWidget.importFolder != widget.importFolder) {
      _retireUpdateFlyout();
    }
  }

  @override
  void dispose() {
    _cancelMetadataUpdates();
    _retireUpdateFlyout();
    _observedManager.removeListener(updateComics);
    _history?.removeListener(_onHistoryChanged);
    appdata.settings.removeListener(_onSettingsChanged);
    _routeFocus?.removeListener(_onRouteFocusChanged);
    for (final parent in _parentRoutes.skip(1)) {
      parent.secondaryAnimation?.removeStatusListener(_onParentTransition);
    }
    _searchController.dispose();
    scrollController.dispose();
    super.dispose();
  }

  void selectAll() {
    if (!_canReadObservedFolder || isLoading || _isFiltering || _hasListError) {
      return;
    }
    setState(() {
      selectedComics = {for (final comic in _visibleComics) comic: true};
      lastSelectedIndex = null;
    });
  }

  void invertSelection() {
    if (!_canReadObservedFolder || isLoading || _isFiltering || _hasListError) {
      return;
    }
    setState(() {
      selectedComics = {
        for (final comic in _visibleComics)
          if (selectedComics[comic] != true) comic: true,
      };
      lastSelectedIndex = null;
    });
  }

  bool _dismissLocalMode() {
    if (!_canReadObservedFolder || _queryOwner?.canPresent != true) {
      return false;
    }
    if (multiSelectMode) {
      _cancel();
      return true;
    }
    if (searchMode) {
      _exitSearch();
      return true;
    }
    return false;
  }

  void _exitSearch() {
    setState(() {
      searchMode = false;
      keyword = '';
      searchHasUpper = false;
      _searchController.clear();
      _refreshReadingFilter();
      _reconcileSelection();
    });
  }

  bool downloadComic(FavoriteItem c) {
    final library = LocalManager();
    var source = c.type.comicSource;
    if (source != null) {
      bool isDownloaded = library.isDownloaded(c.id, (c).type);
      if (isDownloaded) {
        return false;
      }
      library.addTask(
        ImagesDownloadTask(
          storage: library,
          source: source,
          comicId: c.id,
          comicTitle: c.title,
        ),
      );
      return true;
    }
    return false;
  }

  void downloadSelected() {
    int count = 0;
    for (var c in selectedComics.keys) {
      if (downloadComic(c as FavoriteItem)) {
        count++;
      }
    }
    if (count > 0) {
      context.showMessage(
        message: "Added @c comics to download queue.".tlParams({"c": count}),
      );
    }
  }

  var scrollController = ScrollController();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _build(context, constraints.maxWidth),
  );

  Widget _build(BuildContext context, double availableWidth) {
    final target = widget;
    final selection = selectedComics.keys.cast<FavoriteItem>().toList();
    // Snapshot metadata only when an action opens, before any queued writes.
    late final selectedItems = selection
        .map((comic) => comic.detached())
        .toList();
    bool isCurrentSelection() =>
        _canReadObservedFolder &&
        !isLoading &&
        !_isFiltering &&
        !_hasListError &&
        widget.folder == target.folder &&
        multiSelectMode &&
        selection.isNotEmpty &&
        listEquals(selectedComics.keys.toList(), selection);
    var title = widget.folder;
    if (title == localAllFolderLabel) {
      title = "All".tl;
    }
    final folderTree = _canReadObservedFolder
        ? _observedManager.folderTree
        : FavoriteFolderTree.flat(const []);
    final currentFolder = folderTree.named(widget.folder);
    final childFolders = currentFolder == null
        ? const <FavoriteFolder>[]
        : folderTree.childrenOf(currentFolder.id);
    final parentFolder = currentFolder?.parentId == null
        ? null
        : folderTree.identified(currentFolder!.parentId!);
    void goToParent() {
      if (!_canReadObservedFolder ||
          _queryOwner?.canPresent != true ||
          widget.folder != target.folder ||
          currentFolder == null ||
          parentFolder == null) {
        return;
      }
      final latest = _observedManager.folderTree;
      final child = latest.named(target.folder);
      final parent = latest.identified(parentFolder.id);
      if (child?.id != currentFolder.id ||
          child?.parentId != parent?.id ||
          parent == null) {
        return;
      }
      target.onFolderSelected(false, parent.name);
    }

    final displayedComics = _displayedComics;
    final visibleComics = _visibleComics;
    _prepareComicGrid(displayedComics, visibleComics);
    final compactActions = context.width < changePoint && !isAllFolder;
    final canSelect =
        _canReadObservedFolder &&
        !isLoading &&
        !_isFiltering &&
        !_hasListError &&
        visibleComics.isNotEmpty;
    final inlineSelectionActions =
        availableWidth >= 440 + MediaQuery.textScalerOf(context).scale(20) * 4;
    void enterSelection() {
      if (!_canReadObservedFolder ||
          _queryOwner?.canPresent != true ||
          widget.folder != target.folder ||
          isLoading ||
          _isFiltering ||
          _hasListError ||
          _visibleComics.isEmpty) {
        return;
      }
      setState(() {
        selectedComics.clear();
        lastSelectedIndex = null;
        multiSelectMode = true;
      });
    }

    bool isCurrentFolder() =>
        _canReadObservedFolder &&
        widget.folder == target.folder &&
        currentFolder != null &&
        _observedManager.folderTree.named(target.folder)?.id ==
            currentFolder.id;

    Widget body = SmoothCustomScrollView(
      controller: scrollController,
      slivers: [
        if (!searchMode && !multiSelectMode)
          SliverAppbar(
            style: context.width < changePoint
                ? AppbarStyle.shadow
                : AppbarStyle.blur,
            leading: Tooltip(
              message: "Folders".tl,
              child: context.width <= favoritesTwoPanelChangeWidth
                  ? IconButton(
                      icon: const Icon(Icons.menu),
                      color: context.colorScheme.primary,
                      onPressed: widget.showFolders,
                    )
                  : const SizedBox(),
            ),
            title: FavoriteFolderPath(
              currentName: title,
              parentName: parentFolder?.name,
              onParentSelected: parentFolder == null ? null : goToParent,
              onCurrentSelected: context.width < favoritesTwoPanelChangeWidth
                  ? () {
                      if (_queryOwner?.canPresent == true &&
                          widget.folder == target.folder) {
                        target.showFolders();
                      }
                    }
                  : null,
            ),
            actions: [
              if (networkSource != null && !isAllFolder)
                Tooltip(
                  message: "Sync".tl,
                  child: Flyout(
                    flyoutBuilder: (context) {
                      final source = networkSource;
                      final remoteFolder = networkFolder;
                      if (source == null || remoteFolder == null) {
                        return const SizedBox.shrink();
                      }
                      final folder = widget.folder;
                      final importFolder = widget.importFolder;
                      final generation = _observedManager.connectionGeneration;
                      final route = ModalRoute.of(context);
                      if (!identical(_updateFlyoutRoute, route)) {
                        _updateFlyoutRoute = route;
                        route?.completed.then((_) {
                          if (identical(_updateFlyoutRoute, route)) {
                            _updateFlyoutRoute = null;
                          }
                        });
                      }
                      bool isCurrent() =>
                          _canReadObservedFolder &&
                          widget.folder == folder &&
                          widget.importFolder == importFolder &&
                          _observedManager.connectionGeneration == generation &&
                          _observedManager.findLinked(folder) ==
                              (source, remoteFolder) &&
                          NavigationAdmission.allows(this.context);
                      return _FavoriteFolderSyncPanel(
                        networkSource: source,
                        networkFolder: remoteFolder,
                        onUpdate: (pages) async {
                          if (!isCurrent()) return;
                          await importFolder(
                            this.context,
                            source,
                            pages,
                            folder,
                            remoteFolder,
                          );
                          if (isCurrent()) updateComics();
                        },
                      );
                    },
                    child: Builder(
                      builder: (context) {
                        return IconButton(
                          icon: const Icon(Icons.sync),
                          onPressed: () {
                            if (_updateFlyoutRoute == null &&
                                NavigationAdmission.allows(context)) {
                              Flyout.of(context).show();
                            }
                          },
                        );
                      },
                    ),
                  ),
                ),
              const FavoriteDisplayButton(),
              Tooltip(
                message: "Filter".tl,
                child: IconButton(
                  icon: const Icon(Icons.sort_rounded),
                  color: readFilterSelect != readFilterList[0]
                      ? context.colorScheme.primaryContainer
                      : null,
                  onPressed: () {
                    final folder = widget.folder;
                    final request = ++_filterRequest;
                    showDialog(
                      context: context,
                      builder: (context) {
                        return _LocalFavoritesFilterDialog(
                          initReadFilterSelect: readFilterSelect,
                          updateConfig: (readFilter) {
                            if (!mounted ||
                                widget.folder != folder ||
                                request != _filterRequest) {
                              return;
                            }
                            setState(() {
                              readFilterSelect = readFilter;
                              _invalidateDisplay();
                              _refreshReadingFilter();
                              _reconcileSelection();
                            });
                          },
                        );
                      },
                    );
                  },
                ),
              ),
              Tooltip(
                message: "Search".tl,
                child: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () {
                    setState(() {
                      keyword = "";
                      searchHasUpper = false;
                      _searchController.clear();
                      searchMode = true;
                      _refreshSearchResults();
                    });
                  },
                ),
              ),
              if (!compactActions)
                IconButton(
                  tooltip: 'Select comics'.tl,
                  icon: const Icon(Icons.checklist_rounded),
                  onPressed: canSelect ? enterSelection : null,
                ),
              if (!isAllFolder)
                MenuButton(
                  menuIdentity: (
                    _observedManager,
                    _observedGeneration,
                    target.folder,
                    currentFolder?.id,
                    currentFolder?.parentId,
                    childFolders.length,
                    compactActions,
                    canSelect,
                  ),
                  entries: [
                    if (compactActions && canSelect)
                      MenuEntry(
                        icon: Icons.checklist_rounded,
                        text: 'Select comics'.tl,
                        onClick: enterSelection,
                      ),
                    if (currentFolder?.parentId == null)
                      MenuEntry(
                        icon: Icons.create_new_folder_outlined,
                        text: 'Create subfolder'.tl,
                        onClick: () {
                          if (!_canReadObservedFolder ||
                              currentFolder == null ||
                              _queryOwner?.canPresent != true) {
                            return;
                          }
                          newFolder(
                            context,
                            parentId: currentFolder.id,
                            onChanged: (_) => target.updateFolderList(),
                          );
                        },
                      ),
                    MenuEntry(
                      icon: Icons.drive_file_move_outline,
                      text: 'Move folder'.tl,
                      onClick: () {
                        if (!_canReadObservedFolder ||
                            _queryOwner?.canPresent != true) {
                          return;
                        }
                        moveFavoriteFolder(
                          context,
                          folder: target.folder,
                          isCurrent: () =>
                              _canReadObservedFolder &&
                              widget.folder == target.folder,
                          onCommitted: target.updateFolderList,
                        );
                      },
                    ),
                    MenuEntry(
                      icon: Icons.edit_outlined,
                      text: "Rename".tl,
                      onClick: () {
                        renameFavoriteFolder(
                          context,
                          manager: _observedManager,
                          folder: target.folder,
                          isCurrent: () =>
                              _canReadObservedFolder &&
                              widget.folder == target.folder,
                          onRenamed: (name) {
                            target.updateFolderList();
                            if (_canReadObservedFolder &&
                                _queryOwner?.canPresent == true &&
                                widget.folder == target.folder) {
                              target.onFolderSelected(false, name);
                            }
                          },
                        );
                      },
                    ),
                    if (childFolders.isNotEmpty)
                      MenuEntry(
                        icon: Icons.folder_copy_outlined,
                        text: 'Sort subfolders'.tl,
                        onClick: () {
                          if (!isCurrentFolder() ||
                              _queryOwner?.canPresent != true) {
                            return;
                          }
                          sortFolders(
                            context,
                            initialParentId: currentFolder!.id,
                            isCurrent: isCurrentFolder,
                          ).then<void>(
                            (_) {
                              if (isCurrentFolder() &&
                                  _queryOwner?.canPresent == true) {
                                target.updateFolderList();
                              }
                            },
                            onError: (Object error, StackTrace stack) {
                              Log.error(
                                'Favorite subfolder order',
                                error,
                                stack,
                              );
                            },
                          );
                        },
                      ),
                    MenuEntry(
                      icon: Icons.reorder,
                      text: 'Reorder comics'.tl,
                      onClick: () {
                        if (_queryOwner?.canPresent != true) return;
                        reorderFavoriteComics(
                          context,
                          manager: _observedManager,
                          folder: target.folder,
                          isCurrent: () =>
                              _canReadObservedFolder &&
                              widget.folder == target.folder,
                        );
                      },
                    ),
                    MenuEntry(
                      icon: Icons.upload_file,
                      text:
                          (childFolders.isEmpty
                                  ? 'Export'
                                  : 'Export this folder only (no subfolders)')
                              .tl,
                      onClick: () {
                        if (!_canReadObservedFolder ||
                            _queryOwner?.canPresent != true ||
                            widget.folder != target.folder) {
                          return;
                        }
                        final json = _observedManager.folderToJson(
                          target.folder,
                        );
                        saveFileForWindow(
                          context,
                          data: utf8.encode(json),
                          filename: "${target.folder}.json",
                        );
                      },
                    ),
                    MenuEntry(
                      icon: Icons.update,
                      text: "Update Comics Info".tl,
                      onClick: () {
                        if (_queryOwner?.canPresent != true ||
                            !_canReadObservedFolder ||
                            widget.folder != target.folder) {
                          return;
                        }
                        _refreshMetadata(context, target.folder);
                      },
                    ),
                    MenuEntry(
                      icon: Icons.delete_outline,
                      text: "Delete Folder".tl,
                      color: context.colorScheme.error,
                      onClick: () {
                        if (_queryOwner?.canPresent != true) return;
                        if (childFolders.isNotEmpty) {
                          context.showMessage(
                            message:
                                'Move subfolders before deleting this folder'
                                    .tl,
                          );
                          return;
                        }
                        confirmFavoriteMutation(
                          context: context,
                          manager: _observedManager,
                          folder: target.folder,
                          title: "Delete".tl,
                          content:
                              '${"Delete folder '@f' ?".tlParams({"f": target.folder})}\n${'Only favorite records in this folder are removed; comic files are kept.'.tl}',
                          btnColor: context.colorScheme.error,
                          isCurrent: () =>
                              _canReadObservedFolder &&
                              widget.folder == target.folder,
                          mutate: () =>
                              _observedManager.deleteFolder(target.folder),
                          onCommitted: () {
                            target.updateFolderList();
                            if (_canReadObservedFolder &&
                                _queryOwner?.canPresent == true &&
                                widget.folder == target.folder) {
                              target.onFolderSelected(false, null);
                            }
                          },
                        );
                      },
                    ),
                  ],
                ),
            ],
          )
        else if (multiSelectMode)
          SliverAppbar(
            style: context.width < changePoint
                ? AppbarStyle.shadow
                : AppbarStyle.blur,
            leading: Tooltip(
              message: "Cancel".tl,
              child: IconButton(
                icon: const Icon(Icons.close),
                onPressed: _cancel,
              ),
            ),
            title: Text(
              "Selected @c comics".tlParams({"c": selectedComics.length}),
            ),
            actions: [
              if (inlineSelectionActions) ...[
                IconButton(
                  key: const ValueKey('favorites-select-all'),
                  tooltip: 'Select All'.tl,
                  icon: const Icon(Icons.select_all),
                  onPressed: canSelect ? selectAll : null,
                ),
                IconButton(
                  key: const ValueKey('favorites-invert-selection'),
                  tooltip: 'Invert Selection'.tl,
                  icon: const Icon(Icons.flip),
                  onPressed: canSelect ? invertSelection : null,
                ),
                IconButton(
                  key: const ValueKey('favorites-deselect'),
                  tooltip: 'Deselect'.tl,
                  icon: const Icon(Icons.deselect),
                  onPressed: _cancel,
                ),
              ],
              MenuButton(
                menuIdentity: (
                  _observedManager,
                  _observedGeneration,
                  target.folder,
                  Object.hashAll(selection),
                ),
                entries: [
                  if (!isAllFolder && selection.isNotEmpty)
                    MenuEntry(
                      icon: Icons.drive_file_move,
                      text: "Move to folder".tl,
                      onClick: () {
                        if (_queryOwner?.canPresent != true ||
                            !isCurrentSelection()) {
                          return;
                        }
                        showFavoriteTransferDialog(
                          context: context,
                          manager: _observedManager,
                          source: target.folder,
                          comics: selectedItems,
                          move: true,
                          isCurrent: isCurrentSelection,
                          onCommitted: _cancel,
                        );
                      },
                    ),
                  if (!isAllFolder && selection.isNotEmpty)
                    MenuEntry(
                      icon: Icons.copy,
                      text: "Copy to folder".tl,
                      onClick: () {
                        if (_queryOwner?.canPresent != true ||
                            !isCurrentSelection()) {
                          return;
                        }
                        showFavoriteTransferDialog(
                          context: context,
                          manager: _observedManager,
                          source: target.folder,
                          comics: selectedItems,
                          move: false,
                          isCurrent: isCurrentSelection,
                          onCommitted: _cancel,
                        );
                      },
                    ),
                  if (!inlineSelectionActions) ...[
                    MenuEntry(
                      icon: Icons.select_all,
                      text: "Select All".tl,
                      onClick: selectAll,
                    ),
                    MenuEntry(
                      icon: Icons.deselect,
                      text: "Deselect".tl,
                      onClick: _cancel,
                    ),
                    MenuEntry(
                      icon: Icons.flip,
                      text: "Invert Selection".tl,
                      onClick: invertSelection,
                    ),
                  ],
                  if (!isAllFolder && selection.isNotEmpty)
                    MenuEntry(
                      icon: Icons.delete_outline,
                      text: "Delete Comic".tl,
                      color: context.colorScheme.error,
                      onClick: () {
                        if (_queryOwner?.canPresent != true ||
                            !isCurrentSelection()) {
                          return;
                        }
                        confirmFavoriteMutation(
                          context: context,
                          manager: _observedManager,
                          folder: target.folder,
                          title: "Delete".tl,
                          content: "Delete @c comics?".tlParams({
                            "c": selectedItems.length,
                          }),
                          btnColor: context.colorScheme.error,
                          isCurrent: isCurrentSelection,
                          mutate: () => _observedManager.batchDeleteComics(
                            target.folder,
                            selectedItems,
                          ),
                          onCommitted: _cancel,
                        );
                      },
                    ),
                  if (selection.isNotEmpty)
                    MenuEntry(
                      icon: Icons.download,
                      text: "Download".tl,
                      onClick: downloadSelected,
                    ),
                  if (selectedComics.length == 1)
                    MenuEntry(
                      icon: Icons.copy,
                      text: "Copy Title".tl,
                      onClick: () {
                        Clipboard.setData(
                          ClipboardData(text: selectedComics.keys.first.title),
                        );
                        context.showMessage(message: "Copied".tl);
                      },
                    ),
                  if (selectedComics.length == 1)
                    MenuEntry(
                      icon: Icons.chrome_reader_mode_outlined,
                      text: "Read".tl,
                      onClick: () {
                        final c = selectedComics.keys.first as FavoriteItem;
                        appNavigation.rootContext.to(
                          () => ReaderWithLoading(
                            id: c.id,
                            sourceKey: c.sourceKey,
                          ),
                        );
                      },
                    ),
                  if (selectedComics.length == 1)
                    MenuEntry(
                      icon: Icons.arrow_forward_ios,
                      text: "Jump to Detail".tl,
                      onClick: () {
                        final c = selectedComics.keys.first as FavoriteItem;
                        appNavigation.mainNavigatorKey?.currentContext?.to(
                          () => ComicPage(id: c.id, sourceKey: c.sourceKey),
                        );
                      },
                    ),
                ],
              ),
            ],
          )
        else if (searchMode)
          SliverAppbar(
            style: context.width < changePoint
                ? AppbarStyle.shadow
                : AppbarStyle.blur,
            leading: Tooltip(
              message: "Cancel".tl,
              child: IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSearch,
              ),
            ),
            title: TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: "Search".tl,
                border: UnderlineInputBorder(),
              ),
              onChanged: (v) {
                keyword = v;
                searchHasUpper = keyword.contains(RegExp(r'[A-Z]'));
                updateSearchResult();
              },
            ).paddingBottom(8).paddingRight(8),
          ),
        if (!searchMode && !multiSelectMode && childFolders.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Subfolders are separate. Comics below belong directly to this folder.'
                    .tl,
              ),
            ),
          ),
          SliverList.builder(
            itemCount: childFolders.length,
            itemBuilder: (context, index) {
              final folder = childFolders[index];
              return ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(folder.name),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  if (_canReadObservedFolder &&
                      _queryOwner?.canPresent == true) {
                    target.onFolderSelected(false, folder.name);
                  }
                },
              );
            },
          ),
        ],
        if (_hasListError)
          SliverToBoxAdapter(
            child: Column(
              children: [
                Text((_loadError ?? _readingError).toString()),
                TextButton(
                  onPressed: () {
                    if (_loadError != null) {
                      updateComics();
                    } else {
                      setState(() {
                        _invalidateCompletion();
                        _refreshReadingFilter();
                      });
                    }
                  },
                  child: Text('Retry'.tl),
                ),
              ],
            ),
          )
        else if (isLoading || (_isFiltering && _displayedCache == null))
          SliverToBoxAdapter(
            child: SizedBox(
              height: 200,
              child: const Center(child: CircularProgressIndicator()),
            ),
          )
        else ...[
          if (_isFiltering)
            const SliverToBoxAdapter(child: LinearProgressIndicator()),
          if (!searchMode && displayedComics.length < comics.length)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  'Hidden by reading-status filter: @a comics'.tlParams({
                    'a': comics.length - displayedComics.length,
                  }),
                ),
              ),
            ),
          _comicGrid ??= SliverGridComics(
            comics: displayedComics,
            visibleComics: visibleComics,
            showHiddenCount: true,
            selections: _gridSelection,
            useFavoriteDisplaySettings: true,
            menuBuilder: (c) {
              return [
                if (!isAllFolder)
                  MenuEntry(
                    icon: Icons.delete,
                    text: "Delete".tl,
                    onClick: () async {
                      if (!_canReadObservedFolder ||
                          _queryOwner?.canPresent != true ||
                          widget.folder != target.folder) {
                        return;
                      }
                      final item = (c as FavoriteItem).detached();
                      final owner = WindowSelectionTask(context);
                      try {
                        await owner.run<void>((operation) async {
                          operation.checkActive();
                          await AppDataOperations.instance.access(() async {
                            // An accepted deletion may outlive its page, but
                            // cannot enter a replacement database after queuing.
                            if (!_store.isCurrent ||
                                _observedManager.connectionGeneration !=
                                    _observedGeneration ||
                                App.dataPath != _observedDataPath ||
                                !_observedManager.existsFolder(target.folder)) {
                              throw const SelectionCancelled();
                            }
                            await _observedManager.deleteComicWithId(
                              target.folder,
                              item.id,
                              item.type,
                            );
                          });
                        }, reportFailureOnClose: true);
                      } on SelectionCancelled {
                        // The original caller or database retired before admission.
                      } catch (error, stack) {
                        Log.error('Delete favorite', error, stack);
                        if (context.mounted &&
                            owner.canPresent &&
                            _canReadObservedFolder &&
                            widget.folder == target.folder) {
                          context.showMessage(message: error.toString());
                        }
                      }
                    },
                  ),
                MenuEntry(
                  icon: Icons.check,
                  text: "Select".tl,
                  onClick: () {
                    setState(() {
                      if (!multiSelectMode) {
                        multiSelectMode = true;
                      }
                      if (selectedComics.containsKey(c as FavoriteItem)) {
                        selectedComics.remove(c);
                        _checkExitSelectMode();
                      } else {
                        selectedComics[c] = true;
                      }
                      lastSelectedIndex = _visibleComics.indexOf(c);
                    });
                  },
                ),
                MenuEntry(
                  icon: Icons.download,
                  text: "Download".tl,
                  onClick: () {
                    downloadComic(c as FavoriteItem);
                    context.showMessage(message: "Download started".tl);
                  },
                ),
                if (GlobalPreferenceStore(
                      appdata.settings,
                    ).read(FavoritePreferences.onClickFavorite) ==
                    "viewDetail")
                  MenuEntry(
                    icon: Icons.menu_book_outlined,
                    text: "Read".tl,
                    onClick: () {
                      appNavigation.mainNavigatorKey?.currentContext?.to(
                        () =>
                            ReaderWithLoading(id: c.id, sourceKey: c.sourceKey),
                      );
                    },
                  ),
              ];
            },
            onTap: (c, heroID) {
              if (multiSelectMode) {
                setState(() {
                  if (selectedComics.containsKey(c as FavoriteItem)) {
                    selectedComics.remove(c);
                    _checkExitSelectMode();
                  } else {
                    selectedComics[c] = true;
                  }
                  lastSelectedIndex = _visibleComics.indexOf(c);
                });
              } else if (GlobalPreferenceStore(
                    appdata.settings,
                  ).read(FavoritePreferences.onClickFavorite) ==
                  "viewDetail") {
                appNavigation.mainNavigatorKey?.currentContext?.to(
                  () => ComicPage(
                    id: c.id,
                    sourceKey: c.sourceKey,
                    cover: c.cover,
                    title: c.title,
                    heroID: heroID,
                  ),
                );
              } else {
                appNavigation.mainNavigatorKey?.currentContext?.to(
                  () => ReaderWithLoading(id: c.id, sourceKey: c.sourceKey),
                );
              }
            },
            onLongPressed: (c, heroID) {
              final visible = _visibleComics;
              setState(() {
                if (!multiSelectMode) {
                  multiSelectMode = true;
                  if (!selectedComics.containsKey(c as FavoriteItem)) {
                    selectedComics[c] = true;
                  }
                  lastSelectedIndex = visible.indexOf(c);
                } else {
                  if (lastSelectedIndex != null) {
                    int start = lastSelectedIndex!;
                    int end = visible.indexOf(c as FavoriteItem);
                    if (start > end) {
                      int temp = start;
                      start = end;
                      end = temp;
                    }

                    for (int i = start; i <= end; i++) {
                      if (i == lastSelectedIndex) continue;

                      var comic = visible[i];
                      if (selectedComics.containsKey(comic)) {
                        selectedComics.remove(comic);
                      } else {
                        selectedComics[comic] = true;
                      }
                    }
                  }
                  lastSelectedIndex = visible.indexOf(c as FavoriteItem);
                }
                _checkExitSelectMode();
              });
            },
          ),
        ],
      ],
    );
    body = AppScrollBar(
      topPadding: 48,
      controller: scrollController,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: body,
      ),
    );
    // Changing modes must not insert/remove an ancestor of the whole grid.
    body = Focus(
      autofocus: multiSelectMode || searchMode,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            _dismissLocalMode()) {
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: body,
    );
    return PopScope(
      canPop: !multiSelectMode && !searchMode && parentFolder == null,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (!_dismissLocalMode()) {
          goToParent();
        }
      },
      child: body,
    );
  }

  void _cancelMetadataUpdates() {
    for (final task in _metadataTasks.toList()) {
      task.cancel();
    }
  }

  void _refreshMetadata(BuildContext context, String folder) {
    final owner = WindowSelectionTask(context);
    _metadataTasks.add(owner);
    final result = showFavoriteMetadataDialog(
      context: context,
      owner: owner,
      manager: _observedManager,
      folder: folder,
      isCurrent: () => _canReadObservedFolder && widget.folder == folder,
    );
    unawaited(
      result.then<void>(
        (_) {
          _metadataTasks.remove(owner);
        },
        onError: (Object error, StackTrace stack) {
          // Presentation reports its original error and host; consume this page's
          // completion without transferring that failure to another page.
          _metadataTasks.remove(owner);
        },
      ),
    );
  }

  void _checkExitSelectMode() {
    if (selectedComics.isEmpty) {
      setState(() {
        multiSelectMode = false;
      });
    }
  }

  void _cancel() {
    setState(() {
      selectedComics.clear();
      lastSelectedIndex = null;
      multiSelectMode = false;
    });
  }
}

class _FavoriteFolderSyncPanel extends StatefulWidget {
  const _FavoriteFolderSyncPanel({
    required this.networkSource,
    required this.networkFolder,
    required this.onUpdate,
  });

  final Future<void> Function(int pages) onUpdate;
  final String networkFolder;
  final String networkSource;

  @override
  State<_FavoriteFolderSyncPanel> createState() =>
      _FavoriteFolderSyncPanelState();
}

class _FavoriteFolderSyncPanelState
    extends SettingsSaveState<_FavoriteFolderSyncPanel> {
  int updatePageNum = 9999999;
  bool startingUpdate = false;
  late final Future<void> Function(int) _update;

  Future<void> _submit() async {
    if (startingUpdate || !acceptsSettingsChanges) return;
    final pages = updatePageNum;
    final update = _update;
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    setState(() => startingUpdate = true);
    try {
      await waitForSettingsSave();
      if (!mounted ||
          !acceptsSettingsChanges ||
          route?.isCurrent != true ||
          !NavigationAdmission.allows(context)) {
        return;
      }
      if (!await navigator.maybePop() || route?.isCurrent == true) return;
      await update(pages);
    } catch (error, stack) {
      Log.error('Favorite update settings', error, stack);
      if (mounted) context.showMessage(message: error.toString());
    } finally {
      if (mounted) setState(() => startingUpdate = false);
    }
  }

  String get _allPageText => 'All'.tl;

  static const pageCounts = [1, 2, 3, 5, 10, 20, 50, 100, 200, 9999999];

  @override
  void initState() {
    _update = widget.onUpdate;
    final stored = appdata.implicitData['local_favorites_update_page_num'];
    updatePageNum = stored is int && stored > 0 ? stored : 9999999;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    var source = ComicSource.find(widget.networkSource);
    final sourceName = source?.name ?? widget.networkSource;
    var text = "The folder is Linked to @source".tlParams({
      "source": sourceName,
    });
    if (widget.networkFolder.isNotEmpty) {
      text += "\n${"Source Folder".tl}: ${widget.networkFolder}";
    }

    final target = (widget.networkSource, widget.networkFolder);
    return protectSettings(
      FlyoutContent(
        title: 'Sync'.tl,
        actions: [
          FilledButton(
            onPressed: startingUpdate ? null : _submit,
            child: Text('Update'.tl),
          ),
        ],
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text("Update the page number by the latest collection".tl),
                Select(
                  current: updatePageNum.toString() == '9999999'
                      ? _allPageText
                      : updatePageNum.toString(),
                  values: [
                    for (final value in pageCounts)
                      value == 9999999 ? _allPageText : '$value',
                  ],
                  minWidth: 48,
                  onTap: (index) {
                    if (!mounted ||
                        !acceptsSettingsChanges ||
                        startingUpdate ||
                        target !=
                            (widget.networkSource, widget.networkFolder) ||
                        index < 0 ||
                        index >= pageCounts.length) {
                      return;
                    }
                    final value = pageCounts[index];
                    setState(() {
                      updatePageNum = value;
                    });
                    saveSetting(
                      'local_favorites_update_page_num',
                      () => appdata.updateImplicit((draft) {
                        draft['local_favorites_update_page_num'] = value;
                      }),
                    );
                  },
                ),
              ],
            ),
            settingsSaveStatus,
          ],
        ),
      ),
    );
  }
}

class _LocalFavoritesFilterDialog extends StatefulWidget {
  const _LocalFavoritesFilterDialog({
    required this.initReadFilterSelect,
    required this.updateConfig,
  });

  final String initReadFilterSelect;
  final ValueChanged<String> updateConfig;

  @override
  State<_LocalFavoritesFilterDialog> createState() =>
      _LocalFavoritesFilterDialogState();
}

const readFilterList = ['All', 'UnCompleted', 'Completed'];

class _LocalFavoritesFilterDialogState
    extends SettingsSaveState<_LocalFavoritesFilterDialog> {
  List<String> optionTypes = ['Filter'];
  late var readFilter = widget.initReadFilterSelect;
  @override
  Widget build(BuildContext context) {
    Widget tabBar = Material(
      borderRadius: BorderRadius.circular(8),
      child: AppTabBar(
        key: PageStorageKey(optionTypes),
        tabs: optionTypes.map((e) => Tab(text: e.tl, key: Key(e))).toList(),
      ),
    ).paddingTop(context.padding.top);
    return protectSettings(
      ContentDialog(
        content: DefaultTabController(
          length: optionTypes.length,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              tabBar,
              TabViewBody(
                children: [
                  Column(
                    children: [
                      ListTile(
                        title: Text("Filter reading status".tl),
                        trailing: Select(
                          current: readFilter.tl,
                          values: readFilterList.map((e) => e.tl).toList(),
                          minWidth: 64,
                          onTap: (index) {
                            if (!mounted ||
                                !acceptsSettingsChanges ||
                                savingSettings ||
                                hasSettingsSaveError ||
                                index < 0 ||
                                index >= readFilterList.length) {
                              return;
                            }
                            setState(() {
                              readFilter = readFilterList[index];
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          settingsSaveStatus,
          FilledButton(
            onPressed: savingSettings || hasSettingsSaveError
                ? null
                : () {
                    final value = readFilter;
                    saveSetting(
                      'local_favorites_read_filter',
                      () => appdata.updateImplicit((draft) {
                        draft['local_favorites_read_filter'] = value;
                      }),
                      onSaved: () {
                        widget.updateConfig(value);
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) leaveSettings();
                        });
                      },
                    );
                  },
            child: Text("Confirm".tl),
          ),
        ],
      ),
    );
  }
}
