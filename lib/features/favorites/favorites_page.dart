import 'dart:math';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';
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

class _FavoritesPageState extends SettingsSaveState<FavoritesPage> {
  Route<void>? _folderSelector;
  String? folder;

  bool isNetwork = false;

  FolderList? folderList;

  void setFolder(bool isNetwork, String? folder) {
    if (!acceptsSettingsChanges) return;
    setState(() {
      this.isNetwork = isNetwork;
      this.folder = folder;
    });
    folderList?.update();
    saveSetting(
      'favoriteFolder',
      () => appdata.updateImplicit((draft) {
        draft['favoriteFolder'] = {'name': folder, 'isNetwork': isNetwork};
      }),
    );
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
    return protectSettings(
      Column(
        children: [
          if (savingSettings || hasSettingsSaveError) settingsSaveStatus,
          Expanded(
            child: IconTheme(
              data: IconThemeData(
                color: Theme.of(context).colorScheme.secondary,
              ),
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
            ),
          ),
        ],
      ),
    );
  }

  void showFolderSelector() {
    if (!acceptsSettingsChanges || _folderSelector != null) return;
    final origin = ModalRoute.of(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = PageRouteBuilder<void>(
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
                onFolderSelected: (network, name) {
                  if (mounted &&
                      identical(ModalRoute.of(this.context), origin)) {
                    setFolder(network, name);
                  }
                },
                onFolderListReady: (list) {
                  folderList = list;
                },
                onSelected: () {
                  if (context.mounted &&
                      ModalRoute.of(context)?.isCurrent == true) {
                    Navigator.of(context).maybePop();
                  }
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
    );
    _folderSelector = route;
    navigator.push(route).whenComplete(() {
      if (identical(_folderSelector, route)) _folderSelector = null;
    });
  }

  @override
  void dispose() {
    final route = _folderSelector;
    _folderSelector = null;
    scheduleMicrotask(() {
      final navigator = route?.navigator;
      if (navigator?.mounted == true && route!.isActive) {
        navigator!.removeRoute(route);
      }
    });
    super.dispose();
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
