import 'dart:math';

import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/features/favorites/favorites_constants.dart';
import 'package:venera_next/features/favorites/local_favorites_page.dart';
import 'package:venera_next/features/favorites/network_favorites_page.dart';
import 'package:venera_next/features/favorites/side_bar.dart';

const _kLeftBarWidth = 256.0;

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  String? folder;

  bool isNetwork = false;

  FolderList? folderList;

  void setFolder(bool isNetwork, String? folder) {
    setState(() {
      this.isNetwork = isNetwork;
      this.folder = folder;
    });
    folderList?.update();
    appdata.implicitData['favoriteFolder'] = {
      'name': folder,
      'isNetwork': isNetwork,
    };
    appdata.writeImplicitData();
  }

  @override
  void initState() {
    var data = appdata.implicitData['favoriteFolder'];
    if (data != null) {
      folder = data['name'];
      isNetwork = data['isNetwork'] ?? false;
    }
    if (folder != null &&
        !isNetwork &&
        !LocalFavoritesManager().existsFolder(folder!)) {
      folder = null;
    }
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return IconTheme(
      data: IconThemeData(color: Theme.of(context).colorScheme.secondary),
      child: Stack(
        children: [
          AnimatedPositioned(
            left: context.width <= favoritesTwoPanelChangeWidth
                ? -_kLeftBarWidth
                : 0,
            top: 0,
            bottom: 0,
            duration: const Duration(milliseconds: 200),
            child: FavoritesFolderSidebar(
              selectedFolder: folder,
              isNetworkSelected: isNetwork,
              onFolderSelected: setFolder,
              onFolderListReady: (list) {
                folderList = list;
              },
            ).fixWidth(_kLeftBarWidth),
          ),
          Positioned(
            top: 0,
            left: context.width <= favoritesTwoPanelChangeWidth
                ? 0
                : _kLeftBarWidth,
            right: 0,
            bottom: 0,
            child: buildBody(),
          ),
        ],
      ),
    );
  }

  void showFolderSelector() {
    Navigator.of(App.rootContext).push(
      PageRouteBuilder(
        barrierDismissible: true,
        fullscreenDialog: true,
        opaque: false,
        barrierColor: Colors.black.toOpacity(0.36),
        pageBuilder: (context, animation, secondary) {
          return Align(
            alignment: Alignment.centerLeft,
            child: Material(
              child: SizedBox(
                width: min(300, context.width - 16),
                child: FavoritesFolderSidebar(
                  withAppbar: true,
                  selectedFolder: folder,
                  isNetworkSelected: isNetwork,
                  onFolderSelected: setFolder,
                  onFolderListReady: (list) {
                    folderList = list;
                  },
                  onSelected: () {
                    context.pop();
                  },
                ),
              ),
            ),
          );
        },
        transitionsBuilder: (context, animation, secondary, child) {
          var offset = Tween<Offset>(
            begin: const Offset(-1, 0),
            end: const Offset(0, 0),
          );
          return SlideTransition(
            position: offset.animate(
              CurvedAnimation(parent: animation, curve: Curves.fastOutSlowIn),
            ),
            child: child,
          );
        },
      ),
    );
  }

  Widget buildBody() {
    if (folder == null) {
      return CustomScrollView(
        slivers: [
          SliverAppbar(
            leading: Tooltip(
              message: "Folders".tl,
              child: context.width <= favoritesTwoPanelChangeWidth
                  ? IconButton(
                      icon: const Icon(Icons.menu),
                      color: context.colorScheme.primary,
                      onPressed: showFolderSelector,
                    )
                  : null,
            ),
            title: GestureDetector(
              onTap: context.width < favoritesTwoPanelChangeWidth
                  ? showFolderSelector
                  : null,
              child: Text("Unselected".tl),
            ),
          ),
        ],
      );
    }
    if (!isNetwork) {
      return LocalFavoritesPage(
        folder: folder!,
        key: PageStorageKey("local_$folder"),
        showFolders: showFolderSelector,
        onFolderSelected: setFolder,
        updateFolderList: () {
          folderList?.updateFolders();
        },
      );
    } else {
      var favoriteData = getFavoriteDataOrNull(folder!);
      if (favoriteData == null) {
        folder = null;
        return buildBody();
      } else {
        return NetworkFavoritePage(
          favoriteData,
          key: PageStorageKey("network_$folder"),
          showFolders: showFolderSelector,
        );
      }
    }
  }
}
