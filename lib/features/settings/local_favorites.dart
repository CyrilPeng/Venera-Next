import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/features/settings/settings_task_presenter.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

class LocalFavoritesSettings extends StatefulWidget {
  const LocalFavoritesSettings({super.key});

  @override
  State<LocalFavoritesSettings> createState() => _LocalFavoritesSettingsState();
}

class _LocalFavoritesSettingsState extends State<LocalFavoritesSettings> {
  final _tasks = SettingsTaskPresenter();
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Local Favorites".tl)),
        SwitchSetting.preference(
          title: "Show local favorites before network favorites".tl,
          preference: FavoritePreferences.localFavoritesFirst,
        ).toSliver(),
        SwitchSetting.preference(
          title: "Auto close favorite panel after operation".tl,
          preference: FavoritePreferences.autoCloseFavoritePanel,
        ).toSliver(),
        SelectSetting.preference(
          title: "Add new favorite to".tl,
          preference: FavoritePreferences.newFavoriteAddTo,
          optionTranslation: {"start": "Start".tl, "end": "End".tl},
        ).toSliver(),
        SelectSetting.preference(
          title: "Move favorite after reading".tl,
          preference: FavoritePreferences.moveFavoriteAfterRead,
          optionTranslation: {
            "none": "None".tl,
            "end": "End".tl,
            "start": "Start".tl,
          },
        ).toSliver(),
        SelectSetting.preference(
          title: "Quick Favorite".tl,
          preference: FavoritePreferences.quickFavorite,
          help:
              "Long press on the favorite button to quickly add to this folder"
                  .tl,
          optionTranslation: {
            for (var e in FavoritesScope.read(context).folderNames) e: e,
          },
        ).toSliver(),
        CallbackSetting(
          title: "Delete all unavailable local favorite items".tl,
          callback: () async {
            var count = 0;
            await _tasks.run(
              context,
              task: (_) async {
                final local = LocalManager();
                count = await FavoritesScope.read(context).removeInvalid(
                  localComicExists: (id) =>
                      local.find(id, ComicType.local) != null,
                );
                return null;
              },
              errorMessage: "Error".tl,
              onSuccess: () => context.showMessage(
                message: "Deleted @a favorite items".tlParams({'a': count}),
              ),
            );
          },
          actionTitle: 'Delete'.tl,
        ).toSliver(),
        SelectSetting.preference(
          title: "Click favorite".tl,
          preference: FavoritePreferences.onClickFavorite,
          optionTranslation: {
            "viewDetail": "View Detail".tl,
            "read": "Read".tl,
          },
        ).toSliver(),
      ],
    );
  }
}
