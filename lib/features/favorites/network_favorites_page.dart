import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/layout.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/features/favorites/favorite_actions.dart';
import 'package:venera_next/features/favorites/favorites_constants.dart';
import 'package:venera_next/features/favorites/favorites_display.dart';
import 'package:venera_next/foundation/consts.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';
import 'package:venera_next/network/cache.dart';

Future<bool> confirmNetworkFavoriteDeletion(
  BuildContext context, {
  required Future<Res<bool>> Function() delete,
  required String message,
  VoidCallback? onCommitted,
}) async {
  var loading = false;
  return await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setState) => ContentDialog(
            title: "Remove".tl,
            content: Text(message).paddingHorizontal(16),
            actions: [
              Button.filled(
                isLoading: loading,
                color: context.colorScheme.error,
                onPressed: () async {
                  if (loading) return;
                  setState(() => loading = true);
                  Res<bool> result;
                  try {
                    result = await delete();
                  } catch (error, stack) {
                    result = Res.fromException(error, stack);
                  }
                  if (result.success) {
                    NetworkCacheManager().clear();
                    onCommitted?.call();
                  }
                  if (!context.mounted) return;
                  if (result.success) {
                    context.showMessage(message: "Deleted".tl);
                    Navigator.of(context).pop(true);
                  } else {
                    setState(() => loading = false);
                    context.showMessage(message: result.errorMessage!);
                  }
                },
                child: Text("Confirm".tl),
              ),
            ],
          ),
        ),
      ) ??
      false;
}

class NetworkFavoritePage extends StatelessWidget {
  const NetworkFavoritePage(this.data, {super.key, required this.showFolders});

  final FavoriteData data;
  final VoidCallback showFolders;

  @override
  Widget build(BuildContext context) {
    return data.multiFolder
        ? _MultiFolderFavoritesPage(data, showFolders: showFolders)
        : _NormalFavoritePage(data, showFolders: showFolders);
  }
}

class _NormalFavoritePage extends StatefulWidget {
  const _NormalFavoritePage(this.data, {required this.showFolders});

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
                  importNetworkFolder(widget.data.key, 9999999, null, null);
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
              await confirmNetworkFavoriteDeletion(
                context,
                delete: () => data.addOrDelFavorite!(
                  comic.id,
                  '',
                  false,
                  comic.favoriteId,
                ),
                message: "Remove comic from favorite?".tl,
                onCommitted: () => comicListKey.currentState?.remove(comic),
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
  const _MultiFolderFavoritesPage(this.data, {required this.showFolders});

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
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text("Create a folder".tl),
                        const Icon(Icons.add, size: 18),
                      ],
                    ),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (context) {
                          return _CreateFolderDialog(widget.data, reload);
                        },
                      );
                    },
                  ),
                ),
              ),
            ),
        ],
      );
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
      onCommitted: updateState,
    );
  }
}

class _CreateFolderDialog extends StatefulWidget {
  const _CreateFolderDialog(this.data, this.updateState);

  final FavoriteData data;

  final void Function() updateState;

  @override
  State<_CreateFolderDialog> createState() => _CreateFolderDialogState();
}

class _CreateFolderDialogState extends State<_CreateFolderDialog> {
  var controller = TextEditingController();
  bool loading = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: "Create a folder".tl,
      content: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: TextField(
              controller: controller,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: "name".tl,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
      actions: [
        Button.filled(
          isLoading: loading,
          onPressed: () async {
            if (loading) return;
            setState(() => loading = true);
            final onCommitted = widget.updateState;
            Res<bool> result;
            try {
              result = await widget.data.addFolder!(controller.text);
            } catch (error, stack) {
              result = Res.fromException(error, stack);
            }
            if (result.success) {
              NetworkCacheManager().clear();
              onCommitted();
            }
            if (!context.mounted) return;
            if (result.error) {
              setState(() => loading = false);
              context.showMessage(message: result.errorMessage!);
            } else {
              context.showMessage(message: "Created successfully".tl);
              context.pop();
            }
          },
          child: Text("Submit".tl),
        ),
      ],
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
                  importNetworkFolder(data.key, 9999999, title, folderID);
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
                onCommitted: () => comicListKey.currentState?.remove(comic),
              );
            },
          ),
        ];
      },
      useFavoriteDisplaySettings: true,
    );
  }
}
