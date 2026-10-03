import 'network_favorite_import.dart';
import 'network_favorite_import_dialog.dart';
import 'favorite_models.dart';
import 'create_favorite_folder_dialog.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

/// Open a dialog to create a new favorite folder.
Future<void> newFolder() => showDialog<void>(
  context: App.rootContext,
  builder: (_) => CreateFavoriteFolderDialog(
    validate: validateFolderName,
    create: (name) => LocalFavoritesManager().createFolder(name),
    selectImport: () async {
      final file = await selectFile(ext: ['json']);
      return file == null ? null : utf8.decode(await file.readAsBytes());
    },
    importJson: (json) => LocalFavoritesManager().fromJson(json),
  ),
);

String? validateFolderName(String newFolderName) {
  var folders = LocalFavoritesManager().folderNames;
  if (newFolderName.isEmpty) {
    return "Folder name cannot be empty".tl;
  } else if (newFolderName.length > 50) {
    return "Folder name is too long".tl;
  } else if (folders.contains(newFolderName)) {
    return "Folder already exists".tl;
  }
  return null;
}

void addFavorite(List<Comic> comics) {
  var folders = LocalFavoritesManager().folderNames;

  showDialog(
    context: App.rootContext,
    builder: (context) {
      String? selectedFolder = appdata.settings['quickFavorite'];

      return StatefulBuilder(
        builder: (context, setState) {
          return ContentDialog(
            title: "Select a folder".tl,
            content: ListTile(
              title: Text("Folder".tl),
              trailing: Select(
                current: selectedFolder,
                values: folders,
                minWidth: 112,
                onTap: (v) {
                  setState(() {
                    selectedFolder = folders[v];
                  });
                },
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () {
                  if (selectedFolder != null) {
                    for (var comic in comics) {
                      LocalFavoritesManager().addComic(
                        selectedFolder!,
                        FavoriteItem(
                          id: comic.id,
                          name: comic.title,
                          coverPath: comic.cover,
                          author: comic.subtitle ?? '',
                          type: ComicType(
                            (comic.sourceKey == 'local'
                                ? 0
                                : comic.sourceKey.hashCode),
                          ),
                          tags: comic.tags ?? [],
                        ),
                      );
                    }
                    context.pop();
                  }
                },
                child: Text("Confirm".tl),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<List<FavoriteItem>> updateComicsInfo(String folder) async {
  var comics = LocalFavoritesManager().getFolderComics(folder);

  Future<void> updateSingleComic(int index) async {
    int retry = 3;

    while (true) {
      try {
        var c = comics[index];
        var comicSource = c.type.comicSource;
        if (comicSource == null) return;

        var newInfo = (await comicSource.loadComicInfo!(c.id)).data;

        var newTags = <String>[];
        for (var entry in newInfo.tags.entries) {
          const shouldIgnore = ['author', 'artist', 'time'];
          var namespace = entry.key;
          if (shouldIgnore.contains(namespace.toLowerCase())) {
            continue;
          }
          for (var tag in entry.value) {
            newTags.add("$namespace:$tag");
          }
        }

        comics[index] = FavoriteItem(
          id: c.id,
          name: newInfo.title,
          coverPath: newInfo.cover,
          author:
              newInfo.subTitle ??
              newInfo.tags['author']?.firstOrNull ??
              c.author,
          type: c.type,
          tags: newTags,
        );

        LocalFavoritesManager().updateInfo(folder, comics[index]);
        return;
      } catch (e) {
        retry--;
        if (retry == 0) {
          rethrow;
        }
        continue;
      }
    }
  }

  var finished = ValueNotifier(0);

  var errors = 0;

  var index = 0;

  bool isCanceled = false;

  showDialog(
    context: App.rootContext,
    builder: (context) {
      return ValueListenableBuilder(
        valueListenable: finished,
        builder: (context, value, child) {
          var isFinished = value == comics.length;
          return ContentDialog(
            title: isFinished ? "Finished".tl : "Updating".tl,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                LinearProgressIndicator(value: value / comics.length),
                const SizedBox(height: 4),
                Text("$value/${comics.length}"),
                const SizedBox(height: 4),
                if (errors > 0) Text('${"Error".tl}: $errors'),
              ],
            ).paddingHorizontal(16),
            actions: [
              Button.filled(
                color: isFinished ? null : context.colorScheme.error,
                onPressed: () {
                  isCanceled = true;
                  context.pop();
                },
                child: isFinished ? Text("OK".tl) : Text("Cancel".tl),
              ),
            ],
          );
        },
      );
    },
  ).then((_) {
    isCanceled = true;
  });

  while (index < comics.length) {
    var futures = <Future>[];
    const maxConcurrency = 4;

    if (isCanceled) {
      return comics;
    }

    for (var i = 0; i < maxConcurrency; i++) {
      if (index + i >= comics.length) break;
      futures.add(
        updateSingleComic(index + i).then(
          (v) {
            finished.value++;
          },
          onError: (_) {
            errors++;
            finished.value++;
          },
        ),
      );
    }

    await Future.wait(futures);
    index += maxConcurrency;
  }

  return comics;
}

Future<void> sortFolders() async {
  var folders = LocalFavoritesManager().folderNames;

  await showPopUpWidget(
    App.rootContext,
    StatefulBuilder(
      builder: (context, setState) {
        return PopUpWidgetScaffold(
          title: "Sort".tl,
          tailing: [
            Tooltip(
              message: "Help".tl,
              child: IconButton(
                icon: const Icon(Icons.help_outline),
                onPressed: () {
                  showInfoDialog(
                    context: context,
                    title: "Reorder".tl,
                    content: "Long press and drag to reorder.".tl,
                  );
                },
              ),
            ),
          ],
          body: ReorderableListView.builder(
            onReorder: (oldIndex, newIndex) {
              if (oldIndex < newIndex) {
                newIndex--;
              }
              setState(() {
                var item = folders.removeAt(oldIndex);
                folders.insert(newIndex, item);
              });
            },
            itemCount: folders.length,
            itemBuilder: (context, index) {
              return ListTile(
                key: ValueKey(folders[index]),
                title: Text(folders[index]),
              );
            },
          ),
        );
      },
    ),
  );

  LocalFavoritesManager().updateOrder(folders);
}

Future<void> importNetworkFolder(
  String source,
  int updatePageNum,
  String? folder,
  String? folderID,
) async {
  final comicSource = ComicSource.find(source);
  final data = comicSource?.favoriteData;
  if (comicSource == null || data == null || updatePageNum <= 0) return;
  final resultName = folder == null || folder.isEmpty
      ? comicSource.name
      : folder;
  final manager = LocalFavoritesManager();
  if (manager.existsFolder(resultName) &&
      !manager.isLinkedToNetworkFolder(resultName, source, folderID ?? '')) {
    App.rootContext.showMessage(message: 'Folder already exists'.tl);
    return;
  }
  await showDialog<void>(
    context: App.rootContext,
    builder: (_) => NetworkFavoriteImportDialog(
      collect: (scope, progress) => collectNetworkFavorites(
        data: data,
        sourceKey: source,
        folderId: folderID,
        pageLimit: updatePageNum,
        scope: scope,
        exists: (id) =>
            manager.existsFolder(resultName) &&
            manager.comicExists(resultName, id, ComicType(source.hashCode)),
        onProgress: progress,
      ),
      publish: manager.publishNetworkFavoriteImport,
      commit: (items) => manager.importNetworkFavorites(
        resultName,
        source,
        folderID ?? '',
        items,
        oldToNew: data.isOldToNewSort ?? false,
      ),
    ),
  );
}
