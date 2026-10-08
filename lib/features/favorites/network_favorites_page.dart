import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/async_confirm_dialog.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/input_dialog.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/layout.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/features/favorites/favorite_actions.dart';
import 'package:venera_next/features/favorites/favorites_constants.dart';
import 'package:venera_next/features/favorites/favorites_display.dart';
import 'package:venera_next/foundation/consts.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/cache.dart';

Future<bool> confirmNetworkFavoriteDeletion(
  BuildContext context, {
  required Future<Res<bool>> Function() delete,
  required String message,
  VoidCallback? onCommitted,
  bool Function()? isCurrent,
}) async {
  if (!context.mounted || isCurrent?.call() == false) return false;
  var committed = false;
  await showAsyncConfirmDialog(
    context: context,
    title: 'Remove'.tl,
    content: message,
    btnColor: context.colorScheme.error,
    onConfirm: () async {
      if (isCurrent?.call() == false) throw const SelectionCancelled();
      final result = await delete();
      if (result.error) {
        final failure = result.failure;
        Error.throwWithStackTrace(
          failure ?? StateError(result.errorMessage!),
          failure?.stackTrace ?? StackTrace.current,
        );
      }
      committed = true;
      _publishNetworkFavoriteChange(onCommitted);
    },
  );
  return committed;
}

void _publishNetworkFavoriteChange(VoidCallback? onCommitted) {
  try {
    NetworkCacheManager().clear();
    onCommitted?.call();
  } catch (error, stack) {
    Error.throwWithStackTrace(
      PersistenceFailure(
        commitState: PersistenceCommitState.committed,
        cause: error,
        stackTrace: stack,
      ),
      stack,
    );
  }
}

class NetworkFavoritePage extends StatelessWidget {
  const NetworkFavoritePage(this.data, {super.key, required this.showFolders});

  final FavoriteData data;
  final VoidCallback showFolders;

  @override
  Widget build(BuildContext context) {
    return data.multiFolder
        ? _MultiFolderFavoritesPage(
            data,
            key: ObjectKey(data),
            showFolders: showFolders,
          )
        : _NormalFavoritePage(
            data,
            key: ObjectKey(data),
            showFolders: showFolders,
          );
  }
}

class _NormalFavoritePage extends StatefulWidget {
  const _NormalFavoritePage(this.data, {super.key, required this.showFolders});

  final FavoriteData data;
  final VoidCallback showFolders;

  @override
  State<_NormalFavoritePage> createState() => _NormalFavoritePageState();
}

class _NormalFavoritePageState extends State<_NormalFavoritePage> {
  final comicListKey = GlobalKey<ComicListState>();

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    return ComicList(
      key: comicListKey,
      leadingSliver: SliverAppbar(
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
              : null,
        ),
        title: GestureDetector(
          onTap: context.width < favoritesTwoPanelChangeWidth
              ? widget.showFolders
              : null,
          child: Text(widget.data.title),
        ),
        actions: [
          const FavoriteDisplayButton(),
          Tooltip(
            message: "Refresh".tl,
            child: IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                // Force refresh bypassing cache
                NetworkCacheManager().clear();
                comicListKey.currentState!.refresh();
              },
            ),
          ),
          MenuButton(
            entries: [
              MenuEntry(
                icon: Icons.sync,
                text: "Convert to local".tl,
                onClick: () {
                  importNetworkFolder(
                    context,
                    data.key,
                    9999999,
                    null,
                    null,
                    isCurrent: () => mounted && identical(widget.data, data),
                  );
                },
              ),
            ],
          ),
        ],
      ),
      errorLeading: Appbar(
        leading: Tooltip(
          message: "Folders".tl,
          child: context.width <= favoritesTwoPanelChangeWidth
              ? IconButton(
                  icon: const Icon(Icons.menu),
                  color: context.colorScheme.primary,
                  onPressed: widget.showFolders,
                )
              : null,
        ),
        title: GestureDetector(
          onTap: context.width < favoritesTwoPanelChangeWidth
              ? widget.showFolders
              : null,
          child: Text(widget.data.title),
        ),
      ),
      loadPage: widget.data.loadComic == null
          ? null
          : (i) => widget.data.loadComic!(i),
      loadNext: widget.data.loadNext == null
          ? null
          : (next) => widget.data.loadNext!(next),
      menuBuilder: (comic) {
        return [
          MenuEntry(
            icon: Icons.delete_outline,
            text: "Remove".tl,
            onClick: () async {
              if (!mounted || !identical(widget.data, data)) return;
              final list = comicListKey.currentState;
              await confirmNetworkFavoriteDeletion(
                context,
                delete: () => data.addOrDelFavorite!(
                  comic.id,
                  '',
                  false,
                  comic.favoriteId,
                ),
                message: "Remove comic from favorite?".tl,
                isCurrent: () => mounted && identical(widget.data, data),
                onCommitted: () {
                  if (mounted &&
                      identical(widget.data, data) &&
                      identical(comicListKey.currentState, list)) {
                    list?.remove(comic);
                  }
                },
              );
            },
          ),
        ];
      },
      enablePageStorage: true,
      useFavoriteDisplaySettings: true,
    );
  }
}

class _MultiFolderFavoritesPage extends StatefulWidget {
  const _MultiFolderFavoritesPage(
    this.data, {
    super.key,
    required this.showFolders,
  });

  final FavoriteData data;
  final VoidCallback showFolders;

  @override
  State<_MultiFolderFavoritesPage> createState() =>
      _MultiFolderFavoritesPageState();
}

class _MultiFolderFavoritesPageState extends State<_MultiFolderFavoritesPage> {
  bool _loading = true;

  String? _errorMessage;

  Map<String, String>? folders;

  bool _requestRunning = false;

  @override
  void initState() {
    super.initState();
    loadPage();
  }

  Future<void> loadPage() async {
    if (_requestRunning || !mounted) return;
    _requestRunning = true;
    Res<Map<String, String>> res;
    try {
      res = await widget.data.loadFolders!();
    } catch (error, stack) {
      res = Res.fromException(error, stack);
    }
    _requestRunning = false;
    if (!mounted) return;
    setState(() {
      _loading = false;
      _errorMessage = res.errorMessage;
      if (res.success) folders = res.data;
    });
  }

  void reload() {
    if (!mounted || _requestRunning) return;
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    loadPage();
  }

  void openFolder(String key, String title) {
    context.to(() => _FavoriteFolder(widget.data, key, title));
  }

  @override
  Widget build(BuildContext context) {
    var sliverAppBar = SliverAppbar(
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
            : null,
      ),
      title: GestureDetector(
        onTap: context.width < favoritesTwoPanelChangeWidth
            ? widget.showFolders
            : null,
        child: Text(widget.data.title),
      ),
    );

    var appBar = Appbar(
      leading: Tooltip(
        message: "Folders".tl,
        child: context.width <= favoritesTwoPanelChangeWidth
            ? IconButton(
                icon: const Icon(Icons.menu),
                color: context.colorScheme.primary,
                onPressed: widget.showFolders,
              )
            : null,
      ),
      title: GestureDetector(
        onTap: context.width < favoritesTwoPanelChangeWidth
            ? widget.showFolders
            : null,
        child: Text(widget.data.title),
      ),
    );

    if (_loading) {
      return Column(
        children: [
          appBar,
          const Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      );
    } else if (_errorMessage != null) {
      return Column(
        children: [
          appBar,
          Expanded(
            child: NetworkError(
              message: _errorMessage!,
              withAppbar: false,
              retry: reload,
            ),
          ),
        ],
      );
    } else {
      var length = folders!.length;
      if (widget.data.allFavoritesId != null) length++;
      final keys = folders!.keys.toList();

      return SmoothCustomScrollView(
        slivers: [
          sliverAppBar,
          SliverGridViewWithFixedItemHeight(
            delegate: SliverChildBuilderDelegate(childCount: length, (
              context,
              i,
            ) {
              if (widget.data.allFavoritesId != null) {
                if (i == 0) {
                  return _FolderTile(
                    name: "All".tl,
                    onTap: () =>
                        openFolder(widget.data.allFavoritesId!, "All".tl),
                  );
                } else {
                  i--;
                  return _FolderTile(
                    name: folders![keys[i]]!,
                    onTap: () => openFolder(keys[i], folders![keys[i]]!),
                    deleteFolder: widget.data.deleteFolder == null
                        ? null
                        : () => widget.data.deleteFolder!(keys[i]),
                    updateState: reload,
                  );
                }
              } else {
                return _FolderTile(
                  name: folders![keys[i]]!,
                  onTap: () => openFolder(keys[i], folders![keys[i]]!),
                  deleteFolder: widget.data.deleteFolder == null
                      ? null
                      : () => widget.data.deleteFolder!(keys[i]),
                  updateState: reload,
                );
              }
            }),
            maxCrossAxisExtent: 450,
            itemHeight: 52,
          ),
          if (widget.data.addFolder != null)
            SliverToBoxAdapter(
              child: SizedBox(
                height: 60,
                width: double.infinity,
                child: Center(
                  child: TextButton(
                    onPressed: createFolder,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text("Create a folder".tl),
                        const Icon(Icons.add, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }
  }

  Future<void> createFolder() async {
    if (!mounted) return;
    final data = widget.data;
    try {
      await showInputDialog(
        context: context,
        title: 'Create a folder'.tl,
        hintText: 'name'.tl,
        confirmText: 'Submit',
        reportConfirmationFailureOnClose: true,
        onConfirm: (name) async {
          if (!mounted || !identical(widget.data, data)) {
            throw const SelectionCancelled();
          }
          final result = await data.addFolder!(name);
          if (result.error) {
            final failure = result.failure;
            Error.throwWithStackTrace(
              failure ?? StateError(result.errorMessage!),
              failure?.stackTrace ?? StackTrace.current,
            );
          }
          _publishNetworkFavoriteChange(() {
            if (mounted && identical(widget.data, data)) reload();
          });
          return null;
        },
      );
    } on SelectionCancelled {
      // A retired folder page cannot start another request.
    } catch (error, stack) {
      Log.error('Network favorite folder creation', error, stack);
    }
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.name,
    required this.onTap,
    this.deleteFolder,
    this.updateState,
  });

  final String name;

  final Future<Res<bool>> Function()? deleteFolder;

  final void Function()? updateState;

  final void Function() onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      child: ClickInkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Icon(
                Icons.folder,
                size: 28,
                color: Theme.of(context).colorScheme.secondary,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              if (deleteFolder != null)
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => onDeleteFolder(context),
                )
              else
                const Icon(Icons.arrow_right),
            ],
          ),
        ),
      ),
    );
  }

  void onDeleteFolder(BuildContext context) {
    confirmNetworkFavoriteDeletion(
      context,
      delete: deleteFolder!,
      message: "Delete folder?".tl,
      isCurrent: () => context.mounted && identical(context.widget, this),
      onCommitted: updateState,
    );
  }
}

class _FavoriteFolder extends StatelessWidget {
  _FavoriteFolder(this.data, this.folderID, this.title);

  final FavoriteData data;

  final String folderID;

  final String title;

  final comicListKey = GlobalKey<ComicListState>();

  @override
  Widget build(BuildContext context) {
    return ComicList(
      key: comicListKey,
      enablePageStorage: true,
      leadingSliver: SliverAppbar(
        title: Text(title),
        actions: [
          const FavoriteDisplayButton(),
          MenuButton(
            entries: [
              MenuEntry(
                icon: Icons.sync,
                text: "Convert to local".tl,
                onClick: () {
                  importNetworkFolder(
                    context,
                    data.key,
                    9999999,
                    title,
                    folderID,
                    isCurrent: () => identical(context.widget, this),
                  );
                },
              ),
            ],
          ),
        ],
      ),
      errorLeading: Appbar(title: Text(title)),
      loadPage: data.loadComic == null
          ? null
          : (i) => data.loadComic!(i, folderID),
      loadNext: data.loadNext == null
          ? null
          : (next) => data.loadNext!(next, folderID),
      menuBuilder: (comic) {
        return [
          MenuEntry(
            icon: Icons.delete_outline,
            text: "Remove".tl,
            onClick: () async {
              await confirmNetworkFavoriteDeletion(
                context,
                delete: () => data.addOrDelFavorite!(
                  comic.id,
                  folderID,
                  false,
                  comic.favoriteId,
                ),
                message: "Remove comic from favorite?".tl,
                isCurrent: () =>
                    context.mounted && identical(context.widget, this),
                onCommitted: () {
                  if (context.mounted && identical(context.widget, this)) {
                    comicListKey.currentState?.remove(comic);
                  }
                },
              );
            },
          ),
        ];
      },
      useFavoriteDisplaySettings: true,
    );
  }
}
