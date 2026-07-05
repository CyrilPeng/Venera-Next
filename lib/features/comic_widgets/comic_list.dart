import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/layout.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/translations.dart';

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
  });

  final List<Comic> comics;

  final Map<Comic, bool>? selections;

  final void Function()? onLastItemBuild;

  final String? Function(Comic)? badgeBuilder;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final void Function(Comic, int heroID)? onTap;

  final void Function(Comic, int heroID)? onLongPressed;

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
    HistoryManager().addListener(update);
    LocalFavoritesManager().addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    HistoryManager().removeListener(update);
    LocalFavoritesManager().removeListener(update);
    super.dispose();
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
      gridDelegate: SliverGridDelegateWithComics(),
    );
  }
}

/// return the first blocked keyword, or null if not blocked
String? isBlocked(Comic item) {
  for (var word in appdata.settings['blockedWords']) {
    if (item.title.contains(word)) {
      return word;
    }
    if (item.subtitle?.contains(word) ?? false) {
      return word;
    }
    if (item.description.contains(word)) {
      return word;
    }
    for (var tag in item.tags ?? <String>[]) {
      if (tag == word) {
        return word;
      }
      if (tag.contains(':')) {
        tag = tag.split(':')[1];
        if (tag == word) {
          return word;
        }
      }
    }
  }
  return null;
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
    this.enablePageStorage = false,
  });

  final Future<Res<List<Comic>>> Function(int page)? loadPage;

  final Future<Res<List<Comic>>> Function(String? next)? loadNext;

  final Widget? leadingSliver;

  final Widget? trailingSliver;

  final Widget? errorLeading;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final ScrollController? controller;

  final void Function(VoidCallback c)? refreshHandlerCallback;

  final bool enablePageStorage;

  @override
  State<ComicList> createState() => ComicListState();
}

class ComicListState extends State<ComicList> {
  int? _maxPage;

  final Map<int, List<Comic>> _data = {};

  int _page = 1;

  String? _error;

  final Map<int, bool> _loading = {};

  String? _nextUrl;

  late bool enablePageStorage = widget.enablePageStorage;

  Map<String, dynamic> get state => {
    'maxPage': _maxPage,
    'data': _data,
    'page': _page,
    'error': _error,
    'loading': _loading,
    'nextUrl': _nextUrl,
  };

  void restoreState(Map<String, dynamic>? state) {
    if (state == null || !enablePageStorage) {
      return;
    }
    _maxPage = state['maxPage'];
    _data.clear();
    _data.addAll(state['data']);
    _page = state['page'];
    _error = state['error'];
    _loading.clear();
    _loading.addAll(state['loading']);
    _nextUrl = state['nextUrl'];
  }

  void storeState() {
    if (enablePageStorage) {
      PageStorage.of(context).writeState(context, state);
    }
  }

  void refresh() {
    _data.clear();
    _page = 1;
    _maxPage = null;
    _error = null;
    _nextUrl = null;
    _loading.clear();
    storeState();
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    restoreState(PageStorage.of(context).readState(context));
    widget.refreshHandlerCallback?.call(refresh);
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
                    context: App.rootContext,
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
                  child: Text("Page $_page / ${_maxPage ?? '?'}"),
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
    if (widget.loadPage == null && widget.loadNext == null) {
      _error = "loadPage and loadNext can't be null at the same time";
      Future.microtask(() {
        setState(() {});
      });
    }
    if (_data[page] != null || _loading[page] == true) {
      return;
    }
    _loading[page] = true;
    try {
      if (widget.loadPage != null) {
        var res = await widget.loadPage!(page);
        if (!mounted) return;
        if (res.success) {
          if (res.data.isEmpty) {
            setState(() {
              _data[page] = const [];
              _maxPage ??= page;
            });
          } else {
            setState(() {
              _data[page] = res.data;
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
        try {
          while (_data[page] == null) {
            await _fetchNext();
          }
          if (mounted) {
            setState(() {});
          }
        } catch (e) {
          if (mounted) {
            setState(() {
              _error = e.toString();
            });
          }
        }
      }
    } finally {
      _loading[page] = false;
      storeState();
    }
  }

  Future<void> _fetchNext() async {
    var res = await widget.loadNext!(_nextUrl);
    _data[_data.length + 1] = res.data;
    if (res.subData == null) {
      _maxPage = _data.length;
    } else {
      _nextUrl = res.subData;
    }
  }

  @override
  Widget build(BuildContext context) {
    var type = appdata.settings['comicListDisplayMode'];
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
