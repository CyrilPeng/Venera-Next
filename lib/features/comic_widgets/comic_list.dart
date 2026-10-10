import 'dart:async';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/keyword_filter.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/layout.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

import 'comic_tile.dart';

class SliverGridComics extends StatefulWidget {
  const SliverGridComics({
    super.key,
    required this.comics,
    this.onLastItemBuild,
    this.badgeBuilder,
    this.menuBuilder,
    this.onTap,
    this.onLongPressed,
    this.selections,
    this.useFavoriteDisplaySettings = false,
  });

  final List<Comic> comics;

  final Map<Comic, bool>? selections;

  final void Function()? onLastItemBuild;

  final String? Function(Comic)? badgeBuilder;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final void Function(Comic, int heroID)? onTap;

  final void Function(Comic, int heroID)? onLongPressed;

  final bool useFavoriteDisplaySettings;

  @override
  State<SliverGridComics> createState() => _SliverGridComicsState();
}

class _SliverGridComicsState extends State<SliverGridComics> {
  List<Comic> comics = [];
  List<int> heroIDs = [];

  static int _nextHeroID = 0;

  void generateHeroID() {
    heroIDs.clear();
    for (var i = 0; i < comics.length; i++) {
      heroIDs.add(_nextHeroID++);
    }
  }

  @override
  void didUpdateWidget(covariant SliverGridComics oldWidget) {
    if (oldWidget.useFavoriteDisplaySettings !=
        widget.useFavoriteDisplaySettings) {
      if (widget.useFavoriteDisplaySettings) {
        appdata.settings.addListener(_onSettingsChanged);
      } else {
        appdata.settings.removeListener(_onSettingsChanged);
      }
    }
    if (!comics.isEqualTo(widget.comics)) {
      comics.clear();
      for (var comic in widget.comics) {
        if (isBlocked(comic) == null) {
          comics.add(comic);
        }
      }
      generateHeroID();
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void initState() {
    for (var comic in widget.comics) {
      if (isBlocked(comic) == null) {
        comics.add(comic);
      }
    }
    generateHeroID();
    addComicWidgetStateListener(update);
    if (widget.useFavoriteDisplaySettings) {
      appdata.settings.addListener(_onSettingsChanged);
    }
    super.initState();
  }

  @override
  void dispose() {
    removeComicWidgetStateListener(update);
    if (widget.useFavoriteDisplaySettings) {
      appdata.settings.removeListener(_onSettingsChanged);
    }
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void update() {
    setState(() {
      comics.clear();
      for (var comic in widget.comics) {
        if (isBlocked(comic) == null) {
          comics.add(comic);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final favoriteDisplayState = comicFavoriteDisplayState();
    final favoriteDisplayMode = widget.useFavoriteDisplaySettings
        ? (favoriteDisplayState.isGallery
              ? ComicTileDisplayMode.gallery
              : ComicTileDisplayMode.detailed)
        : null;
    return _SliverGridComics(
      comics: comics,
      heroIDs: heroIDs,
      selection: widget.selections,
      onLastItemBuild: widget.onLastItemBuild,
      badgeBuilder: widget.badgeBuilder,
      menuBuilder: widget.menuBuilder,
      onTap: widget.onTap,
      onLongPressed: widget.onLongPressed,
      onBlocked: update,
      favoriteDisplayMode: favoriteDisplayMode,
      galleryColumns: favoriteDisplayMode == ComicTileDisplayMode.gallery
          ? favoriteDisplayState.galleryColumns
          : null,
    );
  }
}

class _SliverGridComics extends StatelessWidget {
  const _SliverGridComics({
    required this.comics,
    required this.heroIDs,
    this.onLastItemBuild,
    this.badgeBuilder,
    this.menuBuilder,
    this.onTap,
    this.onLongPressed,
    this.onBlocked,
    this.selection,
    this.favoriteDisplayMode,
    this.galleryColumns,
  });

  final List<Comic> comics;

  final List<int> heroIDs;

  final Map<Comic, bool>? selection;

  final void Function()? onLastItemBuild;

  final String? Function(Comic)? badgeBuilder;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final void Function(Comic, int heroID)? onTap;

  final void Function(Comic, int heroID)? onLongPressed;

  final VoidCallback? onBlocked;

  final ComicTileDisplayMode? favoriteDisplayMode;

  final int? galleryColumns;

  @override
  Widget build(BuildContext context) {
    return SliverGrid(
      delegate: SliverChildBuilderDelegate((context, index) {
        if (index == comics.length - 1) {
          onLastItemBuild?.call();
        }
        var badge = badgeBuilder?.call(comics[index]);
        var isSelected = selection == null
            ? false
            : selection![comics[index]] ?? false;
        var comic = ComicTile(
          comic: comics[index],
          badge: badge,
          menuOptions: menuBuilder?.call(comics[index]),
          onTap: onTap != null
              ? () => onTap!(comics[index], heroIDs[index])
              : null,
          onLongPressed: onLongPressed != null
              ? () => onLongPressed!(comics[index], heroIDs[index])
              : null,
          onBlocked: onBlocked,
          heroID: heroIDs[index],
          displayMode: favoriteDisplayMode,
        );
        if (selection == null) {
          return comic;
        }
        return AnimatedContainer(
          key: ValueKey(comics[index].id),
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: isSelected
                ? Theme.of(
                    context,
                  ).colorScheme.secondaryContainer.toOpacity(0.72)
                : null,
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(4),
          child: comic,
        );
      }, childCount: comics.length),
      gridDelegate: SliverGridDelegateWithComics(
        galleryColumns: galleryColumns,
        forceDetailed: favoriteDisplayMode == ComicTileDisplayMode.detailed,
      ),
    );
  }
}

/// return the first blocked keyword, or null if not blocked
String? isBlocked(Comic item) {
  return KeywordFilter(
    GlobalPreferenceStore(appdata.settings).read(KeywordPreferences.comics),
  ).firstComicMatch(
    title: item.title,
    subtitle: item.subtitle,
    description: item.description,
    tags: item.tags ?? const [],
  );
}

class ComicList extends StatefulWidget {
  const ComicList({
    super.key,
    this.loadPage,
    this.loadNext,
    this.leadingSliver,
    this.trailingSliver,
    this.errorLeading,
    this.menuBuilder,
    this.controller,
    this.refreshHandlerCallback,
    this.reloadHandlerCallback,
    this.enablePageStorage = false,
    this.useFavoriteDisplaySettings = false,
  });

  final Future<Res<List<Comic>>> Function(int page)? loadPage;

  final Future<Res<List<Comic>>> Function(String? next)? loadNext;

  final Widget? leadingSliver;

  final Widget? trailingSliver;

  final Widget? errorLeading;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final ScrollController? controller;

  final void Function(VoidCallback c)? refreshHandlerCallback;

  final void Function(VoidCallback c)? reloadHandlerCallback;

  final bool enablePageStorage;

  final bool useFavoriteDisplaySettings;

  @override
  State<ComicList> createState() => ComicListState();
}

class ComicListState extends State<ComicList> {
  int? _maxPage;

  final Map<int, List<Comic>> _data = {};

  int _page = 1;

  String? _error;

  final Map<int, bool> _loading = {};

  bool _isReloading = false;
  int _generation = 0;

  String? _nextUrl;

  late bool enablePageStorage = widget.enablePageStorage;

  void _restoreState(Object? state) {
    if (state is! _ComicListSnapshot || !enablePageStorage) {
      return;
    }
    _maxPage = state.maxPage;
    _data.clear();
    for (final entry in state.data.entries) {
      _data[entry.key] = List.of(entry.value);
    }
    _page = state.page;
    _error = state.error;
    _nextUrl = state.nextUrl;
  }

  void storeState() {
    if (mounted && enablePageStorage) {
      PageStorage.of(context).writeState(
        context,
        _ComicListSnapshot(
          maxPage: _maxPage,
          data: _data,
          page: _page,
          error: _error,
          nextUrl: _nextUrl,
        ),
      );
    }
  }

  void refresh() {
    if (!mounted) return;
    _generation++;
    _isReloading = false;
    _data.clear();
    _page = 1;
    _maxPage = null;
    _error = null;
    _nextUrl = null;
    _loading.clear();
    storeState();
    setState(() {});
  }

  Future<void> reload() async {
    if (!mounted || _isReloading) return;
    final loadPage = widget.loadPage;
    if (loadPage == null || _data.isEmpty) {
      refresh();
      return;
    }
    _isReloading = true;
    final generation = _generation;
    final pages = _data.keys.toList()..sort();
    try {
      final results = await Future.wait([
        for (final page in pages) loadPage(page),
      ]);
      if (!_isCurrent(generation)) return;
      setState(() {
        for (var index = 0; index < pages.length; index++) {
          final result = results[index];
          if (!result.success) continue;
          _data[pages[index]] = List<Comic>.from(result.data);
          if (result.subData is int) {
            _maxPage = result.subData as int;
          }
        }
        final maxPage = _maxPage;
        if (maxPage != null) {
          _data.removeWhere((page, _) => page > maxPage);
        }
      });
      storeState();
    } finally {
      if (_isCurrent(generation)) _isReloading = false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _restoreState(PageStorage.of(context).readState(context));
    widget.refreshHandlerCallback?.call(refresh);
    widget.reloadHandlerCallback?.call(() {
      unawaited(reload());
    });
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  void remove(Comic c) {
    if (_data[_page] == null || !_data[_page]!.remove(c)) {
      for (var page in _data.values) {
        if (page.remove(c)) {
          break;
        }
      }
    }
    setState(() {});
  }

  Widget _buildPageSelector() {
    return Row(
      children: [
        FilledButton(
          onPressed: _page > 1
              ? () {
                  setState(() {
                    _error = null;
                    _page--;
                  });
                }
              : null,
          child: Text("Back".tl),
        ).fixWidth(84),
        Expanded(
          child: Center(
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(8),
              child: ClickInkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  String value = '';
                  showDialog(
                    context: appNavigation.rootContext,
                    builder: (context) {
                      return ContentDialog(
                        title: "Jump to page".tl,
                        content: TextField(
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(labelText: "Page".tl),
                          inputFormatters: <TextInputFormatter>[
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          onChanged: (v) {
                            value = v;
                          },
                        ).paddingHorizontal(16),
                        actions: [
                          Button.filled(
                            onPressed: () {
                              Navigator.of(context).pop();
                              var page = int.tryParse(value);
                              if (page == null) {
                                context.showMessage(message: "Invalid page".tl);
                              } else {
                                if (page > 0 &&
                                    (_maxPage == null || page <= _maxPage!)) {
                                  setState(() {
                                    _error = null;
                                    _page = page;
                                  });
                                } else {
                                  context.showMessage(
                                    message: "Invalid page".tl,
                                  );
                                }
                              }
                            },
                            child: Text("Jump".tl),
                          ),
                        ],
                      );
                    },
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Text(
                    "Page @page".tlParams({
                      "page": "$_page / ${_maxPage ?? '?'}",
                    }),
                  ),
                ),
              ),
            ),
          ),
        ),
        FilledButton(
          onPressed: _page < (_maxPage ?? (_page + 1))
              ? () {
                  setState(() {
                    _error = null;
                    _page++;
                  });
                }
              : null,
          child: Text("Next".tl),
        ).fixWidth(84),
      ],
    ).paddingVertical(8).paddingHorizontal(16);
  }

  Widget _buildSliverPageSelector() {
    return SliverToBoxAdapter(child: _buildPageSelector());
  }

  Future<void> _loadPage(int page) async {
    final generation = _generation;
    final loadPage = widget.loadPage;
    final loadNext = widget.loadNext;
    if (loadPage == null && loadNext == null) {
      _error = "loadPage and loadNext can't be null at the same time";
      Future.microtask(() {
        if (_isCurrent(generation)) setState(() {});
      });
      return;
    }
    if (_data[page] != null || _loading[page] == true) {
      return;
    }
    _loading[page] = true;
    try {
      if (loadPage != null) {
        var res = await loadPage(page);
        if (!_isCurrent(generation)) return;
        if (res.success) {
          if (res.data.isEmpty) {
            setState(() {
              _data[page] = <Comic>[];
              _maxPage ??= page;
            });
          } else {
            setState(() {
              _data[page] = List<Comic>.from(res.data);
              if (res.subData != null && res.subData is int) {
                _maxPage = res.subData;
              }
            });
          }
        } else {
          setState(() {
            _error = res.errorMessage ?? "Unknown error".tl;
          });
        }
      } else {
        while (_isCurrent(generation) && _data[page] == null) {
          await _fetchNext(loadNext!, generation);
        }
        if (_isCurrent(generation)) {
          setState(() {});
        }
      }
    } catch (error) {
      if (_isCurrent(generation)) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (_isCurrent(generation)) {
        _loading[page] = false;
        storeState();
      }
    }
  }

  Future<void> _fetchNext(
    Future<Res<List<Comic>>> Function(String?) loadNext,
    int generation,
  ) async {
    var res = await loadNext(_nextUrl);
    if (!_isCurrent(generation)) return;
    res.throwIfError();
    _data[_data.length + 1] = List<Comic>.from(res.data);
    if (res.subData == null) {
      _maxPage = _data.length;
    } else {
      _nextUrl = res.subData as String;
    }
  }

  @override
  Widget build(BuildContext context) {
    final type = GlobalPreferenceStore(
      appdata.settings,
    ).read(DiscoveryPreferences.comicListDisplayMode);
    return type == 'paging' ? buildPagingMode() : buildContinuousMode();
  }

  Widget buildPagingMode() {
    if (_error != null) {
      return Column(
        children: [
          if (widget.errorLeading != null) widget.errorLeading!,
          _buildPageSelector(),
          Expanded(
            child: NetworkError(
              withAppbar: false,
              message: _error!,
              retry: () {
                setState(() {
                  _error = null;
                });
              },
            ),
          ),
        ],
      );
    }
    if (_data[_page] == null) {
      _loadPage(_page);
      return Column(
        children: [
          if (widget.errorLeading != null) widget.errorLeading!,
          const Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      );
    }
    return SmoothCustomScrollView(
      key: enablePageStorage ? PageStorageKey('scroll$_page') : null,
      controller: widget.controller,
      slivers: [
        if (widget.leadingSliver != null) widget.leadingSliver!,
        if (_maxPage != 1) _buildSliverPageSelector(),
        SliverGridComics(
          comics: _data[_page] ?? const [],
          menuBuilder: widget.menuBuilder,
          useFavoriteDisplaySettings: widget.useFavoriteDisplaySettings,
        ),
        if (_data[_page]!.length > 6 && _maxPage != 1)
          _buildSliverPageSelector(),
        if (widget.trailingSliver != null) widget.trailingSliver!,
      ],
    );
  }

  Widget buildContinuousMode() {
    if (_error != null && _data.isEmpty) {
      return Column(
        children: [
          if (widget.errorLeading != null) widget.errorLeading!,
          _buildPageSelector(),
          Expanded(
            child: NetworkError(
              withAppbar: false,
              message: _error!,
              retry: () {
                setState(() {
                  _error = null;
                });
              },
            ),
          ),
        ],
      );
    }
    if (_data[1] == null) {
      _loadPage(1);
      return Column(
        children: [
          if (widget.errorLeading != null) widget.errorLeading!,
          const Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      );
    }
    return SmoothCustomScrollView(
      key: enablePageStorage ? PageStorageKey('scroll$_page') : null,
      controller: widget.controller,
      slivers: [
        if (widget.leadingSliver != null) widget.leadingSliver!,
        SliverGridComics(
          comics: _data.values.expand((element) => element).toList(),
          menuBuilder: widget.menuBuilder,
          useFavoriteDisplaySettings: widget.useFavoriteDisplaySettings,
          onLastItemBuild: () {
            if (_error == null &&
                (_maxPage == null || _data.length < _maxPage!)) {
              _loadPage(_data.length + 1);
            }
          },
        ),
        if (_error != null)
          SliverToBoxAdapter(
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.error_outline),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_error!, maxLines: 3)),
                  ],
                ),
                const SizedBox(height: 8),
                Center(
                  child: OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _error = null;
                      });
                    },
                    child: Text("Retry".tl),
                  ),
                ),
              ],
            ).paddingHorizontal(16).paddingVertical(8),
          )
        else if (_maxPage == null || _data.length < _maxPage!)
          const SliverListLoadingIndicator(),
        if (widget.trailingSliver != null) widget.trailingSliver!,
      ],
    );
  }
}

/// PageStorage is an in-memory UI snapshot, not a persisted data format. Active
/// requests belong to their original State and are never restored as loading.
class _ComicListSnapshot {
  _ComicListSnapshot({
    required this.maxPage,
    required Map<int, List<Comic>> data,
    required this.page,
    required this.error,
    required this.nextUrl,
  }) : data = Map.unmodifiable({
         for (final entry in data.entries)
           entry.key: List<Comic>.unmodifiable(entry.value),
       });

  final int? maxPage;
  final Map<int, List<Comic>> data;
  final int page;
  final String? error;
  final String? nextUrl;
}
