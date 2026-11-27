import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/tv_navigation.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/features/follow_updates/follow_updates.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/history/history_scope.dart';
import 'package:venera_next/features/image_favorites/image_favorites.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/search/search.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/consts.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appdata.settings,
    builder: (context, _) {
      final layout = _HomeLayout.read();
      final view = SmoothCustomScrollView(
        slivers: [
          SliverPadding(padding: EdgeInsets.only(top: context.padding.top)),
          const SearchEntry(),
          const SyncStatusSummary(),
          SliverToBoxAdapter(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                icon: const Icon(Icons.dashboard_customize_outlined),
                label: Text('Customize home'.tl),
                onPressed: () => context.to(() => const _HomeLayoutPage()),
              ),
            ).paddingHorizontal(8),
          ),
          for (final module in layout.order)
            if (!layout.hidden.contains(module))
              KeyedSubtree(
                key: ValueKey(module.id),
                child: module.buildSummary(context),
              ),
          SliverPadding(padding: EdgeInsets.only(top: context.padding.bottom)),
        ],
      );
      return context.width > changePoint ? view.paddingHorizontal(8) : view;
    },
  );
}

enum _HomeModule {
  history('history'),
  readLater('read-later'),
  localComics('local-comics'),
  followUpdates('follow-updates'),
  comicSources('comic-sources'),
  imageFavorites('image-favorites');

  const _HomeModule(this.id);
  final String id;

  String get label => switch (this) {
    history => 'History'.tl,
    readLater => 'Read later'.tl,
    localComics => 'Local'.tl,
    followUpdates => 'Follow Updates'.tl,
    comicSources => 'Comic Source'.tl,
    imageFavorites => 'Image Favorites'.tl,
  };

  Widget buildSummary(BuildContext context) => switch (this) {
    history => HistorySummary(
      manager: HistoryScope.read(context),
      favoriteChanges: FavoritesScope.read(context),
    ),
    readLater => const ReadLaterSummary(),
    localComics => const LocalComicsSummary(),
    followUpdates => const FollowUpdatesWidget(),
    comicSources => ComicSourceSummary(manager: ComicSourceManager.current),
    imageFavorites => const ImageFavoritesSummary(),
  };
}

class _HomeLayout {
  const _HomeLayout(this.order, this.hidden);

  factory _HomeLayout.read() {
    final store = GlobalPreferenceStore(appdata.settings);
    final hidden = store.read(HomePreferences.hiddenModules).toSet();
    final byId = {for (final module in _HomeModule.values) module.id: module};
    // Existing users keep the old order. A module added in a later version
    // appears at the end of any saved layout until the user moves it.
    final order = <_HomeModule>{
      for (final id in store.read(HomePreferences.moduleOrder)) ?byId[id],
      ..._HomeModule.values,
    };
    return _HomeLayout(order.toList(), {
      for (final module in _HomeModule.values)
        if (hidden.contains(module.id)) module,
    });
  }

  static const defaults = _HomeLayout(_HomeModule.values, {});
  final List<_HomeModule> order;
  final Set<_HomeModule> hidden;

  Future<void> persist() => appdata.updateSettings<void>((settings) {
    final store = GlobalPreferenceStore(settings);
    store.write(HomePreferences.moduleOrder, [
      for (final item in order) item.id,
    ]);
    store.write(HomePreferences.hiddenModules, [
      for (final item in order)
        if (hidden.contains(item)) item.id,
    ]);
  });
}

class _HomeLayoutPage extends StatefulWidget {
  const _HomeLayoutPage();

  @override
  State<_HomeLayoutPage> createState() => _HomeLayoutPageState();
}

class _HomeLayoutPageState extends SettingsSaveState<_HomeLayoutPage> {
  late _HomeLayout _draft = _HomeLayout.read();

  bool get _canEdit => acceptsSettingsChanges && !savingSettings;

  void _move(int from, int to) {
    if (!_canEdit || from == to) return;
    final order = List.of(_draft.order);
    order.insert(to, order.removeAt(from));
    setState(() => _draft = _HomeLayout(order, _draft.hidden));
  }

  void _setShown(_HomeModule module, bool shown) {
    if (!_canEdit) return;
    final hidden = {..._draft.hidden};
    if (shown) {
      hidden.remove(module);
    } else {
      hidden.add(module);
    }
    setState(() => _draft = _HomeLayout(_draft.order, hidden));
  }

  void _save() {
    if (!_canEdit) return;
    final dataPath = App.dataPath;
    unawaited(
      saveSetting(
        HomePreferences.moduleOrder.key,
        _draft.persist,
        isCurrent: () => App.dataPath == dataPath,
        onSaved: () => unawaited(leaveSettings()),
      ),
    );
  }

  Widget _buildRow(int index, {required bool isTv}) {
    final module = _draft.order[index];
    final canMoveUp = _canEdit && index > 0;
    final canMoveDown = _canEdit && index + 1 < _draft.order.length;
    return Row(
      key: ValueKey(module.id),
      children: [
        if (!isTv)
          ReorderableDragStartListener(
            index: index,
            enabled: _canEdit,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Tooltip(
                message: 'Drag to reorder'.tl,
                child: const SizedBox.square(
                  dimension: 44,
                  child: Icon(Icons.drag_handle),
                ),
              ),
            ),
          ),
        Expanded(
          child: SwitchListTile(
            autofocus: isTv && index == 0,
            contentPadding: const EdgeInsetsDirectional.only(start: 4, end: 6),
            title: Text(module.label),
            value: !_draft.hidden.contains(module),
            onChanged: _canEdit ? (shown) => _setShown(module, shown) : null,
          ),
        ),
        ExcludeFocus(
          excluding: !canMoveUp,
          child: IconButton(
            tooltip: 'Move up'.tl,
            onPressed: canMoveUp ? () => _move(index, index - 1) : null,
            icon: const Icon(Icons.arrow_upward),
          ),
        ),
        ExcludeFocus(
          excluding: !canMoveDown,
          child: IconButton(
            tooltip: 'Move down'.tl,
            onPressed: canMoveDown ? () => _move(index, index + 1) : null,
            icon: const Icon(Icons.arrow_downward),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTv = TvNavigation.enabledOf(context);
    const listPadding = EdgeInsets.symmetric(horizontal: 8);
    return Scaffold(
      appBar: AppBar(title: Text('Customize home'.tl)),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: protectSettings(
                    // Keyed rows keep their focus when reordered by a remote.
                    isTv
                        ? ListView(
                            padding: listPadding,
                            children: [
                              for (var i = 0; i < _draft.order.length; i++)
                                _buildRow(i, isTv: true),
                            ],
                          )
                        : ReorderableListView.builder(
                            buildDefaultDragHandles: false,
                            padding: listPadding,
                            itemCount: _draft.order.length,
                            onReorder: (from, to) =>
                                _move(from, to > from ? to - 1 : to),
                            itemBuilder: (_, index) =>
                                _buildRow(index, isTv: false),
                          ),
                  ),
                ),
                if (showSettingsSaveProgress || hasSettingsSaveError)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: settingsSaveStatus,
                  ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: _canEdit
                            ? () =>
                                  setState(() => _draft = _HomeLayout.defaults)
                            : null,
                        child: Text('Restore defaults'.tl),
                      ),
                      FilledButton(
                        onPressed: _canEdit ? _save : null,
                        child: Text('Save'.tl),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
