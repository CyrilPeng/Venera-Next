import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/features/history/history_scope.dart';
import 'dart:async';
import 'package:venera_next/foundation/log.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/flyout.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/translations.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, this.manager});

  final HistoryManager? manager;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late final HistoryManager _manager =
      widget.manager ?? HistoryScope.read(context);

  @override
  void initState() {
    _manager.addListener(onUpdate);
    super.initState();
  }

  @override
  void dispose() {
    _manager.removeListener(onUpdate);
    _cancelRefresh?.call();
    super.dispose();
  }

  void onUpdate() {
    setState(() {
      comics = _manager.getAll();
      if (multiSelectMode) {
        selectedComics.removeWhere((comic, _) => !comics.contains(comic));
        if (selectedComics.isEmpty) {
          multiSelectMode = false;
        }
      }
    });
  }

  late var comics = _manager.getAll();
  var controller = FlyoutController();

  bool multiSelectMode = false;
  Map<History, bool> selectedComics = {};

  void selectAll() {
    setState(() {
      selectedComics = comics.asMap().map((k, v) => MapEntry(v, true));
    });
  }

  void deSelect() {
    setState(() {
      selectedComics.clear();
    });
  }

  void invertSelection() {
    setState(() {
      comics.asMap().forEach((k, v) {
        selectedComics[v] = !selectedComics.putIfAbsent(v, () => false);
      });
      selectedComics.removeWhere((k, v) => !v);
    });
  }

  void _removeHistory(History comic) {
    if (comic.sourceKey.startsWith("Unknown")) {
      _manager.remove(
        comic.id,
        ComicType(int.parse(comic.sourceKey.split(':')[1])),
      );
    } else if (comic.sourceKey == 'local') {
      _manager.remove(comic.id, ComicType.local);
    } else {
      _manager.remove(comic.id, ComicType(comic.sourceKey.hashCode));
    }
  }

  final _refreshing = <(String, int)>{};
  bool _refreshingAll = false;
  VoidCallback? _cancelRefresh;

  void _refreshHistory(History comic) async {
    final identity = (comic.id, comic.type.value);
    if (_refreshingAll || !_refreshing.add(identity)) return;
    try {
      final result = await _manager.refreshHistoryInfo(comic);
      if (mounted) {
        context.showMessage(
          message: result ? 'Refresh Success'.tl : 'Refresh Failed'.tl,
        );
      }
    } catch (error, stack) {
      Log.error('Refresh history', error, stack);
      if (mounted) context.showMessage(message: error.toString());
    } finally {
      _refreshing.remove(identity);
    }
  }

  void _refreshAllHistories() async {
    if (_refreshingAll || _refreshing.isNotEmpty) return;
    _refreshingAll = true;
    var cancelled = false;
    StreamIterator<RefreshProgress>? iterator;
    void cancel() {
      cancelled = true;
      unawaited(iterator?.cancel() ?? Future<void>.value());
    }

    _cancelRefresh = cancel;
    final loading = showLoadingDialog(
      context,
      withProgress: true,
      cancelButtonText: 'Cancel'.tl,
      onCancel: cancel,
      message: 'Refreshing Histories'.tl,
    );
    try {
      iterator = StreamIterator(_manager.refreshAllHistoriesStream());
      var success = 0;
      var failed = 0;
      var skipped = 0;
      while (await iterator.moveNext()) {
        if (cancelled || !mounted) return;
        final progress = iterator.current;
        if (progress.total > 0) {
          loading.setProgress(progress.current / progress.total);
        }
        success = progress.success;
        failed = progress.failed;
        skipped = progress.skipped;
      }
      if (mounted && !cancelled) {
        context.showMessage(
          message:
              'Refresh Completed: Success @success, Failed @failed, Skipped @skipped'
                  .tlParams({
                    'success': success,
                    'failed': failed,
                    'skipped': skipped,
                  }),
        );
      }
    } catch (error, stack) {
      Log.error('Refresh histories', error, stack);
      if (mounted && !cancelled) context.showMessage(message: error.toString());
    } finally {
      try {
        await iterator?.cancel();
      } finally {
        loading.close();
        _cancelRefresh = null;
        _refreshingAll = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> selectActions = [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: "Select All".tl,
        onPressed: selectAll,
      ),
      IconButton(
        icon: const Icon(Icons.deselect),
        tooltip: "Deselect".tl,
        onPressed: deSelect,
      ),
      IconButton(
        icon: const Icon(Icons.flip),
        tooltip: "Invert Selection".tl,
        onPressed: invertSelection,
      ),
      IconButton(
        icon: const Icon(Icons.delete),
        tooltip: "Delete".tl,
        onPressed: selectedComics.isEmpty
            ? null
            : () {
                final comicsToDelete = List<History>.from(selectedComics.keys);
                setState(() {
                  multiSelectMode = false;
                  selectedComics.clear();
                });

                for (final comic in comicsToDelete) {
                  _removeHistory(comic);
                }
              },
      ),
    ];

    List<Widget> normalActions = [
      IconButton(
        icon: const Icon(Icons.query_stats),
        tooltip: 'Reading statistics'.tl,
        onPressed: () => context.to(() => ReadingStatsPage(manager: _manager)),
      ),
      IconButton(
        icon: const Icon(Icons.refresh),
        tooltip: 'Refresh All Histories'.tl,
        onPressed: _refreshAllHistories,
      ),
      IconButton(
        icon: const Icon(Icons.checklist),
        tooltip: multiSelectMode ? "Exit Multi-Select".tl : "Multi-Select".tl,
        onPressed: () {
          setState(() {
            multiSelectMode = !multiSelectMode;
          });
        },
      ),
      Tooltip(
        message: 'Clear History'.tl,
        child: Flyout(
          controller: controller,
          flyoutBuilder: (context) {
            return FlyoutContent(
              title: 'Clear History'.tl,
              content: Text('Are you sure you want to clear your history?'.tl),
              actions: [
                Button.outlined(
                  onPressed: () {
                    _manager.clearUnfavoritedHistory(
                      manager: FavoritesScope.read(context),
                    );
                    context.pop();
                  },
                  child: Text('Clear Unfavorited'.tl),
                ),
                const SizedBox(width: 4),
                Button.filled(
                  color: context.colorScheme.error,
                  onPressed: () {
                    _manager.clearHistory();
                    context.pop();
                  },
                  child: Text('Clear'.tl),
                ),
              ],
            );
          },
          child: IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () {
              controller.show();
            },
          ),
        ),
      ),
    ];

    return PopScope(
      canPop: !multiSelectMode,
      onPopInvokedWithResult: (didPop, result) {
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
        }
      },
      child: Scaffold(
        body: SmoothCustomScrollView(
          slivers: [
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Back".tl,
                child: IconButton(
                  onPressed: () {
                    if (multiSelectMode) {
                      setState(() {
                        multiSelectMode = false;
                        selectedComics.clear();
                      });
                    } else {
                      context.pop();
                    }
                  },
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.arrow_back),
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedComics.length.toString())
                  : Text('History'.tl),
              actions: multiSelectMode ? selectActions : normalActions,
            ),
            SliverGridComics(
              comics: comics,
              selections: selectedComics,
              onLongPressed: null,
              onTap: multiSelectMode
                  ? (c, heroID) {
                      setState(() {
                        if (selectedComics.containsKey(c as History)) {
                          selectedComics.remove(c);
                        } else {
                          selectedComics[c] = true;
                        }
                        if (selectedComics.isEmpty) {
                          multiSelectMode = false;
                        }
                      });
                    }
                  : null,
              badgeBuilder: (c) {
                return ComicSource.find(c.sourceKey)?.name;
              },
              menuBuilder: (c) {
                return [
                  MenuEntry(
                    icon: Icons.refresh,
                    text: 'Refresh Info'.tl,
                    onClick: () {
                      _refreshHistory(c as History);
                    },
                  ),
                  MenuEntry(
                    icon: Icons.remove,
                    text: 'Remove'.tl,
                    color: context.colorScheme.error,
                    onClick: () {
                      _removeHistory(c as History);
                    },
                  ),
                ];
              },
            ),
          ],
        ),
      ),
    );
  }
}
