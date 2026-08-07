import 'package:flutter/material.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/foundation/appdata.dart';
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

int normalizeFavoriteGalleryColumns(dynamic value) {
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

void setFavoriteDisplayMode(String mode) {
  if (mode != favoriteDisplayList && mode != favoriteDisplayGallery) {
    return;
  }
  appdata.settings[favoriteDisplayModeKey] = mode;
  appdata.saveData();
}

void setFavoriteGalleryColumns(int columns) {
  appdata.settings[favoriteGalleryColumnsKey] = normalizeFavoriteGalleryColumns(
    columns,
  );
  appdata.saveData();
}

class FavoriteDisplayButton extends StatefulWidget {
  const FavoriteDisplayButton({super.key});

  @override
  State<FavoriteDisplayButton> createState() => _FavoriteDisplayButtonState();
}

class _FavoriteDisplayButtonState extends State<FavoriteDisplayButton> {
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
    return Button.icon(
      icon: Icon(gallery ? Icons.grid_view : Icons.view_list),
      tooltip: 'Favorite display mode'.tl,
      onPressed: () {
        final renderBox = context.findRenderObject() as RenderBox;
        final offset = renderBox.localToGlobal(Offset.zero);
        showMenuX(context, offset, _buildEntries(gallery));
      },
    );
  }

  List<MenuEntry> _buildEntries(bool gallery) {
    final columns = favoriteGalleryColumns();
    return [
      MenuEntry(
        icon: gallery ? Icons.view_list : Icons.check,
        text: 'List'.tl,
        onClick: () => setFavoriteDisplayMode(favoriteDisplayList),
      ),
      MenuEntry(
        icon: gallery ? Icons.check : Icons.grid_view,
        text: 'Gallery'.tl,
        onClick: () => setFavoriteDisplayMode(favoriteDisplayGallery),
      ),
      if (gallery) ...[
        MenuEntry(
          icon: columns == favoriteGalleryAutoColumns
              ? Icons.check
              : Icons.auto_awesome_mosaic_outlined,
          text: 'Auto'.tl,
          onClick: () => setFavoriteGalleryColumns(favoriteGalleryAutoColumns),
        ),
        for (
          var count = favoriteGalleryMinColumns;
          count <= favoriteGalleryMaxColumns;
          count++
        )
          MenuEntry(
            icon: columns == count ? Icons.check : Icons.grid_view_outlined,
            text: '@c columns'.tlParams({'c': count}),
            onClick: () => setFavoriteGalleryColumns(count),
          ),
      ],
    ];
  }
}
