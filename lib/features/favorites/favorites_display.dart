import 'package:flutter/material.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/preferences.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/translations.dart';

class FavoriteDisplayButton extends StatefulWidget {
  const FavoriteDisplayButton({super.key});

  @override
  State<FavoriteDisplayButton> createState() => _FavoriteDisplayButtonState();
}

class _FavoriteDisplayButtonState
    extends SettingsSaveState<FavoriteDisplayButton>
    with ContextMenuOwner {
  bool get _gallery =>
      GlobalPreferenceStore(
        appdata.settings,
      ).read(FavoritePreferences.displayMode) ==
      'gallery';
  int get _columns => GlobalPreferenceStore(
    appdata.settings,
  ).read(FavoritePreferences.galleryColumns);
  @override
  Object get contextMenuIdentity => (_gallery, _columns);
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
    contextMenus.revalidate();
    final gallery = _gallery;
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
    void select<T>(Preference<T> preference, T value) {
      if (!mounted ||
          !acceptsSettingsChanges ||
          generation != _menuGeneration ||
          !identical(ModalRoute.of(context), route) ||
          route?.isCurrent != true ||
          !NavigationAdmission.allows(context)) {
        return;
      }
      saveSetting(
        preference.key,
        () => appdata.updateSettings(
          (draft) => GlobalPreferenceStore(draft).write(preference, value),
        ),
      );
    }

    contextMenus.show(context, offset, _buildEntries(gallery, select));
  }

  List<MenuEntry> _buildEntries(
    bool gallery,
    void Function<T>(Preference<T>, T) select,
  ) {
    final columns = _columns;
    return [
      MenuEntry(
        icon: gallery ? Icons.view_list : Icons.check,
        text: 'List'.tl,
        onClick: () => select(FavoritePreferences.displayMode, 'list'),
      ),
      MenuEntry(
        icon: gallery ? Icons.check : Icons.grid_view,
        text: 'Gallery'.tl,
        onClick: () => select(FavoritePreferences.displayMode, 'gallery'),
      ),
      if (gallery) ...[
        MenuEntry(
          icon: columns == FavoritePreferences.galleryColumns.defaultValue
              ? Icons.check
              : Icons.auto_awesome_mosaic_outlined,
          text: 'Auto'.tl,
          onClick: () => select(
            FavoritePreferences.galleryColumns,
            FavoritePreferences.galleryColumns.defaultValue,
          ),
        ),
        for (
          var count = FavoritePreferences.galleryColumns.min;
          count <= FavoritePreferences.galleryColumns.max;
          count++
        )
          MenuEntry(
            icon: columns == count ? Icons.check : Icons.grid_view_outlined,
            text: '@c columns'.tlParams({'c': count}),
            onClick: () => select(FavoritePreferences.galleryColumns, count),
          ),
      ],
    ];
  }
}
