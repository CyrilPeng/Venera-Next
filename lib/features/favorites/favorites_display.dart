import 'package:flutter/material.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/translations.dart';

const favoriteDisplayModeKey = 'favoritesDisplayMode';
const favoriteGalleryColumnsKey = 'favoritesGalleryColumns';

const favoriteDisplayList = 'list';
const favoriteDisplayGallery = 'gallery';

const favoriteGalleryAutoColumns = 0;
const favoriteGalleryMinColumns = 2;
const favoriteGalleryMaxColumns = 6;

bool isFavoriteGalleryMode() {
  return appdata.settings[favoriteDisplayModeKey] == favoriteDisplayGallery;
}

int normalizeFavoriteGalleryColumns(Object? value) {
  if (value is! num) {
    return favoriteGalleryAutoColumns;
  }
  final columns = value.round();
  if (columns == favoriteGalleryAutoColumns) {
    return favoriteGalleryAutoColumns;
  }
  return columns.clamp(favoriteGalleryMinColumns, favoriteGalleryMaxColumns);
}

int favoriteGalleryColumns() {
  return normalizeFavoriteGalleryColumns(
    appdata.settings[favoriteGalleryColumnsKey],
  );
}

class FavoriteDisplayButton extends StatefulWidget {
  const FavoriteDisplayButton({super.key});

  @override
  State<FavoriteDisplayButton> createState() => _FavoriteDisplayButtonState();
}

class _FavoriteDisplayButtonState
    extends SettingsSaveState<FavoriteDisplayButton> {
  int _menuGeneration = 0;
  @override
  void initState() {
    appdata.settings.addListener(_onSettingsChanged);
    super.initState();
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final gallery = isFavoriteGalleryMode();
    return protectSettings(
      Button.icon(
        icon: Icon(
          hasSettingsSaveError
              ? Icons.refresh
              : gallery
              ? Icons.grid_view
              : Icons.view_list,
        ),
        isLoading: savingSettings,
        tooltip: (hasSettingsSaveError ? 'Retry' : 'Favorite display mode').tl,
        onPressed: () {
          if (hasSettingsSaveError) {
            retrySettingsSave();
          } else {
            _openMenu(gallery);
          }
        },
      ),
    );
  }

  void _openMenu(bool gallery) {
    if (!acceptsSettingsChanges || !NavigationAdmission.allows(context)) return;
    final route = ModalRoute.of(context);
    final generation = ++_menuGeneration;
    final renderBox = context.findRenderObject() as RenderBox;
    final offset = renderBox.localToGlobal(Offset.zero);
    void select(String key, Object value) {
      if (!mounted ||
          !acceptsSettingsChanges ||
          generation != _menuGeneration ||
          !identical(ModalRoute.of(context), route) ||
          route?.isCurrent != true ||
          !NavigationAdmission.allows(context)) {
        return;
      }
      saveSetting(
        key,
        () => appdata.updateSettings((draft) => draft[key] = value),
      );
    }

    showMenuX(context, offset, _buildEntries(gallery, select));
  }

  List<MenuEntry> _buildEntries(
    bool gallery,
    void Function(String, Object) select,
  ) {
    final columns = favoriteGalleryColumns();
    return [
      MenuEntry(
        icon: gallery ? Icons.view_list : Icons.check,
        text: 'List'.tl,
        onClick: () => select(favoriteDisplayModeKey, favoriteDisplayList),
      ),
      MenuEntry(
        icon: gallery ? Icons.check : Icons.grid_view,
        text: 'Gallery'.tl,
        onClick: () => select(favoriteDisplayModeKey, favoriteDisplayGallery),
      ),
      if (gallery) ...[
        MenuEntry(
          icon: columns == favoriteGalleryAutoColumns
              ? Icons.check
              : Icons.auto_awesome_mosaic_outlined,
          text: 'Auto'.tl,
          onClick: () =>
              select(favoriteGalleryColumnsKey, favoriteGalleryAutoColumns),
        ),
        for (
          var count = favoriteGalleryMinColumns;
          count <= favoriteGalleryMaxColumns;
          count++
        )
          MenuEntry(
            icon: columns == count ? Icons.check : Icons.grid_view_outlined,
            text: '@c columns'.tlParams({'c': count}),
            onClick: () => select(
              favoriteGalleryColumnsKey,
              normalizeFavoriteGalleryColumns(count),
            ),
          ),
      ],
    ];
  }
}
