import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/layout.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/translations.dart';

import 'favorite_models.dart';
import 'favorites_manager.dart';

void reorderFavoriteComics(
  BuildContext context, {
  required LocalFavoritesManager manager,
  required String folder,
  required bool Function() isCurrent,
}) {
  if (!context.mounted || !isCurrent()) return;
  final owner = WindowSelectionTask(context);
  final popup = context
      .getInheritedWidgetOfExactType<PopupIndicatorWidget>()
      ?.route;
  if (!owner.canPresent ||
      popup?.isCurrent == false ||
      !identical(LocalFavoritesManager.cache, manager) ||
      !manager.existsFolder(folder)) {
    return;
  }
  final generation = manager.connectionGeneration;
  final dataPath = App.dataPath;
  final comics = manager.getFolderComics(folder);
  // The editor owns each accepted save. No presentation Future is retained:
  // destroying a Navigator need not complete the Future returned by push.
  unawaited(
    context.to<void>(
      () => _ComicReorderPage(
        manager: manager,
        generation: generation,
        dataPath: dataPath,
        folder: folder,
        comics: comics,
        isCurrent: () =>
            owner.active && popup?.isActive != false && isCurrent(),
      ),
    ),
  );
}

class _ComicReorderPage extends StatefulWidget {
  const _ComicReorderPage({
    required this.manager,
    required this.generation,
    required this.dataPath,
    required this.folder,
    required this.comics,
    required this.isCurrent,
  });

  final LocalFavoritesManager manager;
  final int generation;
  final String dataPath;
  final String folder;
  final List<FavoriteItem> comics;
  final bool Function() isCurrent;

  @override
  State<_ComicReorderPage> createState() => _ComicReorderPageState();
}

class _ComicReorderPageState extends SettingsSaveState<_ComicReorderPage> {
  final _key = GlobalKey();
  final _reorderWidgetKey = UniqueKey();
  final _scrollController = ScrollController();
  final _orderKey = Object();
  late List<FavoriteItem> _comics;
  WindowSelectionTask? _owner;

  bool get _isCurrentDatabase =>
      identical(LocalFavoritesManager.cache, widget.manager) &&
      widget.manager.connectionGeneration == widget.generation &&
      App.dataPath == widget.dataPath;

  bool get _hasOriginalTarget =>
      mounted &&
      widget.isCurrent() &&
      _isCurrentDatabase &&
      widget.manager.existsFolder(widget.folder);

  bool get _canEdit =>
      _hasOriginalTarget &&
      acceptsSettingsChanges &&
      _owner?.canPresent == true;

  @override
  bool get mayLeaveSettingsAfterSaveFailure => !_hasOriginalTarget;

  @override
  void initState() {
    super.initState();
    _comics = widget.comics.map((comic) => comic.detached()).toList();
    appdata.settings.addListener(_onDisplaySettingsChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _owner ??= WindowSelectionTask(context);
  }

  void _onDisplaySettingsChanged() {
    if (mounted) setState(() {});
  }

  void _reorder(List<FavoriteItem> Function(List<FavoriteItem>) reorder) {
    if (!_canEdit) return;
    final next = reorder(List<FavoriteItem>.of(_comics));
    if (!_canEdit) return;
    final snapshot = next.map((comic) => comic.detached()).toList();
    setState(() => _comics = next);
    unawaited(
      saveSetting(
        _orderKey,
        () => AppDataOperations.instance.access(() async {
          // Recheck at actual admission, after any queued data replacement.
          // A retired target cancels this assignment without a close failure.
          if (!_isCurrentDatabase ||
              !widget.manager.existsFolder(widget.folder)) {
            return;
          }
          await widget.manager.reorder(snapshot, widget.folder);
        }),
        isCurrent: () => _canEdit,
      ),
    );
  }

  void _leave() {
    // The current editor may close even when its initiating page or database
    // has retired; editing still requires that original owner.
    if (!mounted ||
        ModalRoute.of(context)?.isCurrent == false ||
        !NavigationAdmission.allows(context)) {
      return;
    }
    unawaited(leaveSettings());
  }

  static int _floatToInt8(double x) => (x * 255.0).round() & 0xff;

  Color lightenColor(Color color, double lightenValue) {
    int red = (_floatToInt8(color.r) + ((255 - color.r) * lightenValue))
        .round();
    int green = (_floatToInt8(color.g) * 255 + ((255 - color.g) * lightenValue))
        .round();
    int blue = (_floatToInt8(color.b) * 255 + ((255 - color.b) * lightenValue))
        .round();
    return Color.fromARGB(_floatToInt8(color.a), red, green, blue);
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_onDisplaySettingsChanged);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gallery =
        GlobalPreferenceStore(
          appdata.settings,
        ).read(FavoritePreferences.displayMode) ==
        'gallery';
    final displayMode = gallery
        ? ComicTileDisplayMode.gallery
        : ComicTileDisplayMode.detailed;
    final tiles = _comics.map((e) {
      final comicSource = e.type.comicSource;
      return Padding(
        key: Key(e.hashCode.toString()),
        padding: const EdgeInsets.all(4),
        child: ComicTile(
          enableLongPressed: false,
          displayMode: displayMode,
          comic: Comic(
            e.name,
            e.coverPath,
            e.id,
            e.author,
            e.tags,
            "${e.time} | ${comicSource?.name ?? "Unknown"}",
            comicSource?.key ??
                (e.type == ComicType.local ? "local" : "Unknown"),
            null,
            null,
          ),
        ),
      );
    }).toList();
    return protectSettings(
      Scaffold(
        appBar: Appbar(
          title: Text("Reorder".tl),
          leading: Tooltip(
            message: 'Back'.tl,
            child: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: _leave,
            ),
          ),
          actions: [
            settingsSaveStatus,
            Tooltip(
              message: "Information".tl,
              child: IconButton(
                icon: const Icon(Icons.info_outline),
                onPressed: () {
                  if (!_canEdit) return;
                  showInfoDialog(
                    context: context,
                    title: "Reorder".tl,
                    content: "Long press and drag to reorder.".tl,
                  );
                },
              ),
            ),
            Tooltip(
              message: "Reverse".tl,
              child: IconButton(
                icon: const Icon(Icons.swap_vert),
                onPressed: () => _reorder((items) => items.reversed.toList()),
              ),
            ),
          ],
        ),
        body: ReorderableBuilder<FavoriteItem>(
          key: _reorderWidgetKey,
          scrollController: _scrollController,
          longPressDelay: App.isDesktop
              ? const Duration(milliseconds: 100)
              : const Duration(milliseconds: 500),
          onReorder: _reorder,
          dragChildBoxDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: lightenColor(
              Theme.of(context).splashColor.withAlpha(255),
              0.2,
            ),
          ),
          builder: (children) => GridView(
            key: _key,
            controller: _scrollController,
            gridDelegate: SliverGridDelegateWithComics(
              galleryColumns: gallery
                  ? GlobalPreferenceStore(
                      appdata.settings,
                    ).read(FavoritePreferences.galleryColumns)
                  : null,
              forceDetailed: !gallery,
            ),
            children: children,
          ),
          children: tiles,
        ),
      ),
    );
  }
}
