import 'package:venera_next/features/history/history_scope.dart';
import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/components/file_save_task.dart';
import 'favorite_models.dart';
import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
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
import 'package:venera_next/foundation/comic_type.dart';
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

  late String readFilterSelect;

  var searchResults = <FavoriteItem>[];

  void updateSearchResult() {
    setState(() {
      if (keyword.trim().isEmpty) {
        searchResults = comics;
      } else {
        searchResults = [];
        for (var comic in comics) {
          if (matchKeyword(keyword, comic) ||
              matchKeywordT(keyword, comic) ||
              matchKeywordS(keyword, comic)) {
            searchResults.add(comic);
          }
        }
      }
    });
  }

  void updateComics() {
    if (!_canReadObservedFolder) return;
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
        comics = [];
      } else if (count < _asyncDataFetchLimit) {
        comics = isAllFolder
            ? manager.getAllComics()
            : manager.getFolderComics(folder);
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
              setState(() {
                isLoading = false;
                comics = value;
              });
            },
            onError: (Object error, StackTrace stack) {
              Log.error('Favorites query', error, stack);
              if (!_canReadObservedFolder ||
                  generation != _queryGeneration ||
                  widget.folder != folder) {
                return;
              }
              setState(() {
                isLoading = false;
                _loadError = error;
              });
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

  List<FavoriteItem> filterComics(List<FavoriteItem> curComics) {
    return curComics.where((comic) {
      var history = HistoryScope.read(
        context,
      ).find(comic.id, ComicType(comic.sourceKey.hashCode));
      if (readFilterSelect == "UnCompleted") {
        return history == null || history.page != history.maxPage;
      } else if (readFilterSelect == "Completed") {
        return history != null && history.page == history.maxPage;
      }
      return true;
    }).toList();
  }

  bool matchKeyword(String keyword, FavoriteItem comic) {
    var list = keyword.split(" ");
    for (var k in list) {
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

  // Convert keyword to traditional Chinese to match comics
  bool matchKeywordT(String keyword, FavoriteItem comic) {
    if (!OpenCC.hasChineseSimplified(keyword)) {
      return false;
    }
    keyword = OpenCC.simplifiedToTraditional(keyword);
    return matchKeyword(keyword, comic);
  }

  // Convert keyword to simplified Chinese to match comics
  bool matchKeywordS(String keyword, FavoriteItem comic) {
    if (!OpenCC.hasChineseTraditional(keyword)) {
      return false;
    }
    keyword = OpenCC.traditionalToSimplified(keyword);
    return matchKeyword(keyword, comic);
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
    _observedManager.addListener(updateComics);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_queryOwner != null) return;
    _queryOwner = WindowSelectionTask(context);
    updateComics();
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
      final linked = isAllFolder || !_canReadObservedFolder
          ? (null, null)
          : _observedManager.findLinked(widget.folder);
      networkSource = linked.$1;
      networkFolder = linked.$2;
      updateComics();
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
    scrollController.dispose();
    super.dispose();
  }

  void selectAll() {
    setState(() {
      if (searchMode) {
        selectedComics = searchResults.asMap().map((k, v) => MapEntry(v, true));
      } else {
        selectedComics = comics.asMap().map((k, v) => MapEntry(v, true));
      }
    });
  }

  void invertSelection() {
    setState(() {
      if (searchMode) {
        for (var c in searchResults) {
          if (selectedComics.containsKey(c)) {
            selectedComics.remove(c);
          } else {
            selectedComics[c] = true;
          }
        }
      } else {
        for (var c in comics) {
          if (selectedComics.containsKey(c)) {
            selectedComics.remove(c);
          } else {
            selectedComics[c] = true;
          }
        }
      }
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
  Widget build(BuildContext context) {
    final target = widget;
    final selection = selectedComics.keys.cast<FavoriteItem>().toList();
    final selectedItems = selection.map((comic) => comic.detached()).toList();
    bool isCurrentSelection() =>
        _canReadObservedFolder &&
        widget.folder == target.folder &&
        multiSelectMode &&
        listEquals(selectedComics.keys.toList(), selection);
    var title = widget.folder;
    if (title == localAllFolderLabel) {
      title = "All".tl;
    }

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
            title: GestureDetector(
              onTap: context.width < favoritesTwoPanelChangeWidth
                  ? widget.showFolders
                  : null,
              child: Text(title),
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
                            });
                            updateComics();
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
                      searchMode = true;
                      updateSearchResult();
                    });
                  },
                ),
              ),
              if (!isAllFolder)
                MenuButton(
                  entries: [
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
                    MenuEntry(
                      icon: Icons.reorder,
                      text: "Reorder".tl,
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
                      text: "Export".tl,
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
                        confirmFavoriteMutation(
                          context: context,
                          manager: _observedManager,
                          folder: target.folder,
                          title: "Delete".tl,
                          content: "Delete folder '@f' ?".tlParams({
                            "f": target.folder,
                          }),
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
                onPressed: () {
                  setState(() {
                    multiSelectMode = false;
                    selectedComics.clear();
                  });
                },
              ),
            ),
            title: Text(
              "Selected @c comics".tlParams({"c": selectedComics.length}),
            ),
            actions: [
              MenuButton(
                entries: [
                  if (!isAllFolder)
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
                  if (!isAllFolder)
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
                  if (!isAllFolder)
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
                onPressed: () {
                  setState(() {
                    setState(() {
                      searchMode = false;
                    });
                  });
                },
              ),
            ),
            title: TextField(
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
        if (_loadError != null)
          SliverToBoxAdapter(
            child: Column(
              children: [
                Text(_loadError.toString()),
                TextButton(onPressed: updateComics, child: Text('Retry'.tl)),
              ],
            ),
          )
        else if (isLoading)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 200,
              child: const Center(child: CircularProgressIndicator()),
            ),
          )
        else
          SliverGridComics(
            comics: searchMode ? searchResults : filterComics(comics),
            selections: selectedComics,
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
                      lastSelectedIndex = comics.indexOf(c);
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
                  lastSelectedIndex = comics.indexOf(c);
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
              setState(() {
                if (!multiSelectMode) {
                  multiSelectMode = true;
                  if (!selectedComics.containsKey(c as FavoriteItem)) {
                    selectedComics[c] = true;
                  }
                  lastSelectedIndex = comics.indexOf(c);
                } else {
                  if (lastSelectedIndex != null) {
                    int start = lastSelectedIndex!;
                    int end = comics.indexOf(c as FavoriteItem);
                    if (start > end) {
                      int temp = start;
                      start = end;
                      end = temp;
                    }

                    for (int i = start; i <= end; i++) {
                      if (i == lastSelectedIndex) continue;

                      var comic = comics[i];
                      if (selectedComics.containsKey(comic)) {
                        selectedComics.remove(comic);
                      } else {
                        selectedComics[comic] = true;
                      }
                    }
                  }
                  lastSelectedIndex = comics.indexOf(c as FavoriteItem);
                }
                _checkExitSelectMode();
              });
            },
          ),
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
    return PopScope(
      canPop: !multiSelectMode && !searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
        } else if (searchMode) {
          setState(() {
            searchMode = false;
            keyword = "";
            updateComics();
          });
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
