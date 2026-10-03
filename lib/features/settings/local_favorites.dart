import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/features/settings/settings_task_presenter.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/favorites/favorites.dart';
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
        SwitchSetting(
          title: "Show local favorites before network favorites".tl,
          settingKey: "localFavoritesFirst",
        ).toSliver(),
        SwitchSetting(
          title: "Auto close favorite panel after operation".tl,
          settingKey: "autoCloseFavoritePanel",
        ).toSliver(),
        SelectSetting(
          title: "Add new favorite to".tl,
          settingKey: "newFavoriteAddTo",
          optionTranslation: {"start": "Start".tl, "end": "End".tl},
        ).toSliver(),
        SelectSetting(
          title: "Move favorite after reading".tl,
          settingKey: "moveFavoriteAfterRead",
          optionTranslation: {
            "none": "None".tl,
            "end": "End".tl,
            "start": "Start".tl,
          },
        ).toSliver(),
        SelectSetting(
          title: "Quick Favorite".tl,
          settingKey: "quickFavorite",
          help:
              "Long press on the favorite button to quickly add to this folder"
                  .tl,
          optionTranslation: {
            for (var e in LocalFavoritesManager().folderNames) e: e,
          },
        ).toSliver(),
        CallbackSetting(
          title: "Delete all unavailable local favorite items".tl,
          callback: () async {
            var count = 0;
            await _tasks.run(
              context,
              task: () async {
                count = await LocalFavoritesManager().removeInvalid();
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
        SelectSetting(
          title: "Click favorite".tl,
          settingKey: "onClickFavorite",
          optionTranslation: {
            "viewDetail": "View Detail".tl,
            "read": "Read".tl,
          },
        ).toSliver(),
      ],
    );
  }
}
