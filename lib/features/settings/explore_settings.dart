import 'package:venera_next/foundation/application_preferences.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/features/settings/keyword_blocking.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

class ExploreSettings extends StatefulWidget {
  const ExploreSettings({super.key});

  @override
  State<ExploreSettings> createState() => _ExploreSettingsState();
}

class _ExploreSettingsState extends State<ExploreSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Explore".tl)),
        SelectSetting.preference(
          title: "Display mode of comic tile".tl,
          preference: DiscoveryPreferences.comicDisplayMode,
          optionTranslation: {"detailed": "Detailed".tl, "brief": "Brief".tl},
        ).toSliver(),
        SliderSetting.preference(
          title: "Size of comic tile".tl,
          preference: DiscoveryPreferences.comicTileScale,
        ).toSliver(),
        PopupWindowSetting(
          title: "Explore Pages".tl,
          builder: setExplorePagesWidget,
        ).toSliver(),
        PopupWindowSetting(
          title: "Category Pages".tl,
          builder: setCategoryPagesWidget,
        ).toSliver(),
        PopupWindowSetting(
          title: "Network Favorite Pages".tl,
          builder: setFavoritesPagesWidget,
        ).toSliver(),
        PopupWindowSetting(
          title: "Search Sources".tl,
          builder: setSearchSourcesWidget,
        ).toSliver(),
        SwitchSetting.preference(
          title: "Show favorite status on comic tile".tl,
          preference: DiscoveryPreferences.showFavoriteStatusOnTile,
        ).toSliver(),
        SwitchSetting.preference(
          title: "Show history on comic tile".tl,
          preference: DiscoveryPreferences.showHistoryStatusOnTile,
        ).toSliver(),
        SwitchSetting.preference(
          title: "Show update status on comic tile".tl,
          preference: DiscoveryPreferences.showUpdateStatusOnTile,
        ).toSliver(),
        SwitchSetting.preference(
          title: "Reverse default chapter order".tl,
          preference: AppPreferences.reverseChapterOrder,
        ).toSliver(),
        PopupWindowSetting(
          title: "Keyword blocking".tl,
          builder: () => const KeywordBlockingSettings(),
        ).toSliver(),
        PopupWindowSetting(
          title: "Comment keyword blocking".tl,
          builder: () => const KeywordBlockingSettings(comments: true),
        ).toSliver(),
        SelectSetting.preference(
          title: "Default Search Target".tl,
          preference: DiscoveryPreferences.defaultSearchTarget,
          optionTranslation: {
            '_aggregated_': "Aggregated".tl,
            ...(() {
              var map = <String, String>{};
              for (var c in ComicSource.all()) {
                map[c.key] = c.name;
              }
              return map;
            }()),
          },
        ).toSliver(),
        SelectSetting.preference(
          title: "Auto Language Filters".tl,
          preference: DiscoveryPreferences.autoAddLanguageFilter,
          optionTranslation: {
            'none': "None".tl,
            'chinese': "Chinese",
            'english': "English",
            'japanese': "Japanese",
          },
        ).toSliver(),
        SelectSetting.preference(
          title: "Initial Page".tl,
          preference: DiscoveryPreferences.initialPage,
          optionTranslation: {
            '0': "Home Page".tl,
            '1': "Favorites Page".tl,
            '2': "Explore Page".tl,
            '3': "Categories Page".tl,
          },
        ).toSliver(),
        SelectSetting.preference(
          title: "Display mode of comic list".tl,
          preference: DiscoveryPreferences.comicListDisplayMode,
          optionTranslation: {
            "paging": "Paging".tl,
            "Continuous": "Continuous".tl,
          },
        ).toSliver(),
      ],
    );
  }
}

Widget setExplorePagesWidget() {
  var pages = <String, String>{};
  for (var c in ComicSource.all()) {
    for (var page in c.explorePages) {
      pages[page.title] = page.title.ts(c.key);
    }
  }
  return MultiPagesFilter(
    title: "Explore Pages".tl,
    preference: DiscoveryPreferences.explorePages,
    pages: pages,
  );
}

Widget setCategoryPagesWidget() {
  var pages = <String, String>{};
  for (var c in ComicSource.all()) {
    if (c.categoryData != null) {
      pages[c.categoryData!.key] = c.categoryData!.title;
    }
  }
  return MultiPagesFilter(
    title: "Category Pages".tl,
    preference: DiscoveryPreferences.categoryPages,
    pages: pages,
  );
}

Widget setFavoritesPagesWidget() {
  var pages = <String, String>{};
  for (var c in ComicSource.all()) {
    if (c.favoriteData != null) {
      pages[c.favoriteData!.key] = c.favoriteData!.title;
    }
  }
  return MultiPagesFilter(
    title: "Network Favorite Pages".tl,
    preference: DiscoveryPreferences.favoritePages,
    pages: pages,
  );
}

Widget setSearchSourcesWidget() {
  var pages = <String, String>{};
  for (var c in ComicSource.all()) {
    if (c.searchPageData != null) {
      pages[c.key] = c.name;
    }
  }
  return MultiPagesFilter(
    title: "Search Sources".tl,
    preference: DiscoveryPreferences.searchSources,
    pages: pages,
  );
}
