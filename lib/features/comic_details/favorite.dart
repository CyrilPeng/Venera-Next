import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:shimmer_animation/shimmer_animation.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';
import 'package:venera_next/network/cache.dart';

class ComicFavoritePanel extends StatefulWidget {
  const ComicFavoritePanel({
    super.key,
    required this.cid,
    required this.type,
    required this.isFavorite,
    required this.onFavorite,
    required this.favoriteItem,
    this.updateTime,
  });

  final String cid;

  final ComicType type;

  /// whether the comic is in the network favorite list
  ///
  /// if null, the comic source does not support favorite or support multiple favorite lists
  final bool? isFavorite;

  final void Function(bool?, bool?) onFavorite;

  final FavoriteItem favoriteItem;

  final String? updateTime;

  @override
  State<ComicFavoritePanel> createState() => _FavoritePanelState();
}

class _FavoritePanelState extends State<ComicFavoritePanel>
    with SingleTickerProviderStateMixin {
  late ComicSource comicSource;

  late bool hasNetwork;

  late List<String> localFolders;

  late List<String> added;

  @override
  void initState() {
    comicSource = widget.type.comicSource!;
    localFolders = LocalFavoritesManager().folderNames;
    added = LocalFavoritesManager().find(widget.cid, widget.type);
    hasNetwork = comicSource.favoriteData != null && comicSource.isLogged;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text("Favorite".tl)),
      body: _FavoriteList(
        cid: widget.cid,
        type: widget.type,
        isFavorite: widget.isFavorite,
        onFavorite: widget.onFavorite,
        favoriteItem: widget.favoriteItem,
        updateTime: widget.updateTime,
        comicSource: comicSource,
        hasNetwork: hasNetwork,
        localFolders: localFolders,
        added: added,
      ),
    );
  }
}

class _FavoriteList extends StatefulWidget {
  const _FavoriteList({
    required this.cid,
    required this.type,
    required this.isFavorite,
    required this.onFavorite,
    required this.favoriteItem,
    this.updateTime,
    required this.comicSource,
    required this.hasNetwork,
    required this.localFolders,
    required this.added,
  });

  final String cid;
  final ComicType type;
  final bool? isFavorite;
  final void Function(bool?, bool?) onFavorite;
  final FavoriteItem favoriteItem;
  final String? updateTime;
  final ComicSource comicSource;
  final bool hasNetwork;
  final List<String> localFolders;
  final List<String> added;

  @override
  State<_FavoriteList> createState() => _FavoriteListState();
}

class _FavoriteListState extends State<_FavoriteList> {
  @override
  Widget build(BuildContext context) {
    final localFavoritesFirst = GlobalPreferenceStore(
      appdata.settings,
    ).read(FavoritePreferences.localFavoritesFirst);

    final localSection = _LocalSection(
      cid: widget.cid,
      type: widget.type,
      favoriteItem: widget.favoriteItem,
      updateTime: widget.updateTime,
      localFolders: widget.localFolders,
      added: widget.added,
      onFavorite: (local) {
        widget.onFavorite(local, null);
      },
    );

    final networkSection = widget.hasNetwork
        ? NetworkFavoriteSection(
            cid: widget.cid,
            favoriteData: widget.comicSource.favoriteData!,
            isFavorite: widget.isFavorite,
            onFavorite: (network) {
              widget.onFavorite(null, network);
            },
          )
        : null;

    final divider = widget.hasNetwork
        ? Container(
            height: 1,
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: context.colorScheme.outlineVariant.withValues(alpha: 0.3),
          )
        : null;

    return ListView(
      children: [
        if (localFavoritesFirst) ...[
          localSection,
          if (widget.hasNetwork) ...[divider!, networkSection!],
        ] else ...[
          if (widget.hasNetwork) ...[networkSection!, divider!],
          localSection,
        ],
      ],
    );
  }
}

class NetworkFavoriteSection extends StatefulWidget {
  const NetworkFavoriteSection({
    super.key,
    required this.cid,
    required this.favoriteData,
    required this.isFavorite,
    required this.onFavorite,
  });

  final String cid;
  final FavoriteData favoriteData;
  final bool? isFavorite;
  final void Function(bool) onFavorite;

  @override
  State<NetworkFavoriteSection> createState() => _NetworkSectionState();
}

class _NetworkSectionState extends State<NetworkFavoriteSection> {
  bool isLoading = false;
  Map<String, String>? folders;
  var addedFolders = <String>{};
  var isLoadingFolders = true;
  bool? localIsFavorite;
  final Map<String, bool> _itemLoading = {};
  late List<double> _skeletonWidths;

  @override
  void initState() {
    super.initState();
    localIsFavorite = widget.isFavorite;
    _skeletonWidths = List.generate(
      3,
      (_) => 0.3 + math.Random().nextDouble() * 0.5,
    );
    if (widget.favoriteData.loadFolders != null) {
      loadFolders();
    } else {
      isLoadingFolders = false;
    }
  }

  Future<void> loadFolders() async {
    Res<Map<String, String>> res;
    try {
      res = await widget.favoriteData.loadFolders!(widget.cid);
    } catch (error, stack) {
      res = Res.fromException(error, stack);
    }
    if (!mounted) return;
    if (res.error) {
      context.showMessage(message: res.errorMessage!);
    } else {
      folders = res.data;
      addedFolders = res.subData is List
          ? Set<String>.from(res.subData)
          : <String>{};
      localIsFavorite = addedFolders.isNotEmpty;
    }
    setState(() => isLoadingFolders = false);
  }

  Future<void> _toggle(
    String folder,
    bool wasAdded, {
    required bool multi,
  }) async {
    if (multi ? (_itemLoading[folder] ?? false) : isLoading) return;
    setState(() {
      if (multi) {
        _itemLoading[folder] = true;
      } else {
        isLoading = true;
      }
    });
    Res<bool> result;
    try {
      result = await widget.favoriteData.addOrDelFavorite!(
        widget.cid,
        folder,
        !wasAdded,
        null,
      );
    } catch (error, stack) {
      result = Res.fromException(error, stack);
    }
    // The accepted remote mutation outlives the panel; invalidate stale lists
    // even when the caller has already closed it.
    if (result.success) NetworkCacheManager().clear();
    if (!mounted) return;
    setState(() {
      _itemLoading.remove(folder);
      isLoading = false;
      if (result.success) {
        if (multi) {
          if (wasAdded) {
            addedFolders.remove(folder);
          } else {
            addedFolders.add(folder);
          }
          localIsFavorite = addedFolders.isNotEmpty;
        } else {
          localIsFavorite = !wasAdded;
        }
      }
    });
    if (result.error) {
      context.showMessage(message: result.errorMessage!);
      return;
    }
    widget.onFavorite(localIsFavorite!);
    if (!mounted) return;
    context.showMessage(
      message: multi ? "Success".tl : (wasAdded ? "Removed".tl : "Added".tl),
    );
    if (GlobalPreferenceStore(
      appdata.settings,
    ).read(FavoritePreferences.autoCloseFavoritePanel)) {
      context.pop();
    }
  }

  Widget _buildLoadingSkeleton() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            "Network Favorites".tl,
            style: ts.s14.copyWith(
              fontWeight: FontWeight.w600,
              color: context.colorScheme.primary,
            ),
          ),
        ),
        Shimmer(
          child: Column(
            children: List.generate(3, (index) {
              return ListTile(
                title: Container(
                  height: 20,
                  width: double.infinity,
                  margin: const EdgeInsets.only(right: 16),
                  child: FractionallySizedBox(
                    widthFactor: _skeletonWidths[index],
                    alignment: Alignment.centerLeft,
                    child: Container(
                      decoration: BoxDecoration(
                        color: context.colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
                trailing: Container(
                  height: 28,
                  width: 60 + (index * 2),
                  decoration: BoxDecoration(
                    color: context.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isLoadingFolders) {
      return _buildLoadingSkeleton();
    }

    if (widget.favoriteData.loadFolders != null && folders == null) {
      return TextButton(
        onPressed: () {
          setState(() => isLoadingFolders = true);
          loadFolders();
        },
        child: Text("Retry".tl),
      );
    }
    bool isMultiFolder = widget.favoriteData.loadFolders != null;

    if (isMultiFolder) {
      return _buildMultiFolder();
    } else {
      return _buildSingleFolder();
    }
  }

  Widget _buildSingleFolder() {
    var isFavorite = localIsFavorite ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            "Network Favorites".tl,
            style: ts.s14.copyWith(
              fontWeight: FontWeight.w600,
              color: context.colorScheme.primary,
            ),
          ),
        ),
        ListTile(
          title: Row(
            children: [
              Text("Network Favorites".tl),
              const SizedBox(width: 8),
              if (isFavorite)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: context.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text("Added".tl, style: ts.s12),
                ),
            ],
          ),
          trailing: isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : _HoverButton(
                  isFavorite: isFavorite,
                  onTap: () => _toggle('', isFavorite, multi: false),
                ),
        ),
      ],
    );
  }

  Widget _buildMultiFolder() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            "Network Favorites".tl,
            style: ts.s14.copyWith(
              fontWeight: FontWeight.w600,
              color: context.colorScheme.primary,
            ),
          ),
        ),
        ...folders!.entries.map((entry) {
          var name = entry.value;
          var id = entry.key;
          var isAdded = addedFolders.contains(id);
          // When `singleFolderForSingleComic` is `false`, all add and remove buttons are clickable.
          // When `singleFolderForSingleComic` is `true`, the remove button is always clickable,
          // while the add button is only clickable if the comic has not been added to any list.
          var enabled =
              !(widget.favoriteData.singleFolderForSingleComic &&
                  addedFolders.isNotEmpty &&
                  !isAdded);

          return ListTile(
            title: Row(
              children: [
                Text(name),
                const SizedBox(width: 8),
                if (isAdded)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: context.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text("Added".tl, style: ts.s12),
                  ),
              ],
            ),
            trailing: (_itemLoading[id] ?? false)
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : _HoverButton(
                    isFavorite: isAdded,
                    enabled: enabled,
                    onTap: () => _toggle(id, isAdded, multi: true),
                  ),
          );
        }),
      ],
    );
  }
}

class _LocalSection extends StatefulWidget {
  const _LocalSection({
    required this.cid,
    required this.type,
    required this.favoriteItem,
    this.updateTime,
    required this.localFolders,
    required this.added,
    required this.onFavorite,
  });

  final String cid;
  final ComicType type;
  final FavoriteItem favoriteItem;
  final String? updateTime;
  final List<String> localFolders;
  final List<String> added;
  final void Function(bool) onFavorite;

  @override
  State<_LocalSection> createState() => _LocalSectionState();
}

class _LocalSectionState extends State<_LocalSection> {
  late List<String> localFolders;
  late Set<String> localAdded;
  bool saving = false;

  Future<void> changeFavorite(String folder, bool remove) async {
    if (saving) return;
    final target = widget;
    bool sameTarget() => widget.cid == target.cid && widget.type == target.type;
    final owner = context;
    final route = ModalRoute.of(owner);
    final manager = LocalFavoritesManager();
    final generation = manager.connectionGeneration;
    setState(() => saving = true);
    try {
      await AppDataOperations.instance.access(() async {
        if (!mounted || !sameTarget()) return;
        if (manager.connectionGeneration != generation) {
          throw StateError('Favorites database changed. Try again.');
        }
        if (remove) {
          await manager.deleteComicWithId(folder, target.cid, target.type);
        } else {
          await manager.addComic(
            folder,
            target.favoriteItem,
            null,
            target.updateTime,
          );
        }
      });
      if (!mounted || !sameTarget()) return;
      setState(() {
        localAdded = manager.find(target.cid, target.type).toSet();
      });
      target.onFavorite(localAdded.isNotEmpty);
      if (owner.mounted &&
          route?.isCurrent != false &&
          (GlobalPreferenceStore(
            appdata.settings,
          ).read(FavoritePreferences.autoCloseFavoritePanel))) {
        owner.pop();
      }
    } catch (error, stack) {
      Log.error('Local favorite', error, stack);
      if (owner.mounted && sameTarget()) {
        owner.showMessage(message: error.toString());
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  void initState() {
    super.initState();
    localFolders = widget.localFolders;
    localAdded = widget.added.toSet();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            "Local Favorites".tl,
            style: ts.s14.copyWith(
              fontWeight: FontWeight.w600,
              color: context.colorScheme.primary,
            ),
          ),
        ),
        ...localFolders.map((folder) {
          var isAdded = localAdded.contains(folder);

          return ListTile(
            title: Row(
              children: [
                Text(folder),
                const SizedBox(width: 8),
                if (isAdded)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: context.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text("Added".tl, style: ts.s12),
                  ),
              ],
            ),
            trailing: _HoverButton(
              isFavorite: isAdded,
              enabled: !saving,
              onTap: () => changeFavorite(folder, isAdded),
            ),
          );
        }),
        // New folder button
        ListTile(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.add, size: 20),
              const SizedBox(width: 4),
              Text("New Folder".tl),
            ],
          ),
          onTap: () {
            final target = widget;
            newFolder(
              context,
              onChanged: (folders) {
                if (!mounted ||
                    widget.cid != target.cid ||
                    widget.type != target.type) {
                  return;
                }
                setState(() => localFolders = folders);
              },
            );
          },
        ),
      ],
    );
  }
}

class _HoverButton extends StatefulWidget {
  const _HoverButton({
    required this.isFavorite,
    required this.onTap,
    this.enabled = true,
  });

  final bool isFavorite;
  final VoidCallback onTap;
  final bool enabled;

  @override
  State<_HoverButton> createState() => _HoverButtonState();
}

class _HoverButtonState extends State<_HoverButton> {
  bool isHovered = false;

  @override
  Widget build(BuildContext context) {
    final removeColor = context.colorScheme.error;
    final removeHoverColor = Color.lerp(removeColor, Colors.black, 0.2)!;
    final addColor = context.colorScheme.primary;
    final addHoverColor = Color.lerp(addColor, Colors.black, 0.2)!;

    return MouseRegion(
      onEnter: widget.enabled ? (_) => setState(() => isHovered = true) : null,
      onExit: widget.enabled ? (_) => setState(() => isHovered = false) : null,
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: widget.enabled
                ? (widget.isFavorite
                      ? (isHovered ? removeHoverColor : removeColor)
                      : (isHovered ? addHoverColor : addColor))
                : context.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            widget.isFavorite ? "Remove".tl : "Add".tl,
            style: ts.s12.copyWith(
              color: widget.enabled
                  ? context.colorScheme.onPrimary
                  : context.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
