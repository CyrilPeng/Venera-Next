import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:venera_next/foundation/translations.dart';
import 'cbz.dart';
import 'package:venera_next/foundation/file_interaction.dart';

class ImportComic {
  final String? selectedFolder;
  final bool copyToLocal;

  const ImportComic({this.selectedFolder, this.copyToLocal = true});

  Future<bool> cbz() async {
    var file = await selectFile(ext: ['cbz', 'zip', '7z', 'cb7']);
    Map<String?, List<LocalComic>> imported = {};
    if (file == null) {
      return false;
    }
    var controller = showLoadingDialog(App.rootContext, allowCancel: false);
    try {
      var comic = await CBZ.import(File(file.path));
      imported[selectedFolder] = [comic];
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
    }
    controller.close();
    return registerComics(imported, false);
  }

  Future<bool> multipleCbz() async {
    var picker = DirectoryPicker();
    var dir = await picker.pickDirectory(directAccess: true);
    if (dir != null) {
      var files = (await dir.list().toList()).whereType<File>().toList();
      files.removeWhere((file) => !isComicArchiveFileName(file.name));
      Map<String?, List<LocalComic>> imported = {};
      var controller = showLoadingDialog(App.rootContext, allowCancel: false);
      var comics = <LocalComic>[];
      for (var file in files) {
        try {
          var comic = await CBZ.import(file);
          comics.add(comic);
        } catch (e, s) {
          Log.error("Import Comic", e.toString(), s);
        }
      }
      if (comics.isEmpty) {
        App.rootContext.showMessage(message: "No valid comics found".tl);
      }
      imported[selectedFolder] = comics;
      controller.close();
      return registerComics(imported, false);
    }
    return false;
  }

  Future<bool> ehViewer() async {
    var dbFile = await selectFile(ext: ['db']);
    final picker = DirectoryPicker();
    final comicSrc = await picker.pickDirectory();
    Map<String?, List<LocalComic>> imported = {};
    if (dbFile == null || comicSrc == null) {
      return false;
    }

    bool cancelled = false;
    var controller = showLoadingDialog(
      App.rootContext,
      onCancel: () {
        cancelled = true;
      },
    );

    try {
      var db = sql.sqlite3.open(dbFile.path);

      Future<List<LocalComic>> validateComics(List<sql.Row> comics) async {
        List<LocalComic> imported = [];
        for (var comic in comics) {
          if (cancelled) {
            return imported;
          }
          var comicDir = Directory(
            FilePath.join(comicSrc.path, comic['DIRNAME'] as String),
          );
          String titleJP = comic['TITLE_JPN'] == null
              ? ""
              : comic['TITLE_JPN'] as String;
          String title = titleJP == "" ? comic['TITLE'] as String : titleJP;
          int timeStamp = comic['TIME'] as int;
          DateTime downloadTime = timeStamp != 0
              ? DateTime.fromMillisecondsSinceEpoch(timeStamp)
              : DateTime.now();
          var comicObj = await _checkSingleComic(
            comicDir,
            title: title,
            tags: [
              //1 >> x
              [
                "MISC",
                "DOUJINSHI",
                "MANGA",
                "ARTISTCG",
                "GAMECG",
                "IMAGE SET",
                "COSPLAY",
                "ASIAN PORN",
                "NON-H",
                "WESTERN",
              ][(log(comic['CATEGORY'] as int) / ln2).floor()],
            ],
            createTime: downloadTime,
          );
          if (comicObj == null) {
            continue;
          }
          imported.add(comicObj);
        }
        return imported;
      }

      var tags = <String>[""];
      tags.addAll(
        db
            .select("""
            SELECT * FROM DOWNLOAD_LABELS LB
            ORDER BY  LB.TIME DESC;
          """)
            .map((r) => r['LABEL'] as String)
            .toList(),
      );

      for (var tag in tags) {
        if (cancelled) {
          break;
        }
        var folderName = tag == '' ? '(EhViewer)Default'.tl : '(EhViewer)$tag';
        var comicList = db.select("""
              SELECT * 
              FROM DOWNLOAD_DIRNAME DN
              LEFT JOIN DOWNLOADS DL
              ON DL.GID = DN.GID
              WHERE DL.LABEL ${tag == '' ? 'IS NULL' : '= \'$tag\''} AND DL.STATE = 3
              ORDER BY DL.TIME DESC
            """).toList();

        var validComics = await validateComics(comicList);
        imported[folderName] = validComics;
        if (validComics.isNotEmpty &&
            !LocalFavoritesManager().existsFolder(folderName)) {
          LocalFavoritesManager().createFolder(folderName);
        }
      }
      db.dispose();

      //Android specific
      var cache = FilePath.join(App.cachePath, dbFile.name);
      await File(cache).deleteIgnoreError();
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
    }
    controller.close();
    if (cancelled) return false;
    return registerComics(imported, copyToLocal);
  }

  Future<bool> directory(bool single) async {
    final picker = DirectoryPicker();
    final path = await picker.pickDirectory();
    if (path == null) {
      return false;
    }
    Map<String?, List<LocalComic>> imported = {selectedFolder: []};
    try {
      if (single) {
        var result = await _checkSingleComic(path);
        if (result != null) {
          imported[selectedFolder]!.add(result);
        } else {
          App.rootContext.showMessage(message: "Invalid Comic".tl);
          return false;
        }
      } else {
        await for (var entry in path.list()) {
          if (entry is Directory) {
            var result = await _checkSingleComic(entry);
            if (result != null) {
              imported[selectedFolder]!.add(result);
            }
          }
        }
      }
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
    }
    return registerComics(imported, copyToLocal);
  }

  Future<bool> localDownloads() async {
    var localDir = LocalManager().directory;
    Map<String?, List<LocalComic>> imported = {null: []};
    bool cancelled = false;
    var controller = showLoadingDialog(
      App.rootContext,
      onCancel: () {
        cancelled = true;
      },
    );
    try {
      if (!await localDir.exists()) {
        App.rootContext.showMessage(message: "Local path not found".tl);
        controller.close();
        return false;
      }
      await for (var entry in localDir.list()) {
        if (cancelled) {
          break;
        }
        if (entry is Directory) {
          var stat = await entry.stat();
          var result = await _checkSingleComic(
            entry,
            createTime: stat.modified,
            useRelativePath: true,
          );
          if (result != null) {
            imported[null]!.add(result);
          }
        }
      }
      if (!cancelled && imported[null]!.isEmpty) {
        App.rootContext.showMessage(message: "No valid comics found".tl);
      }
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
    }
    controller.close();
    if (cancelled) return false;
    return registerComics(imported, false);
  }

  //Automatically search for cover image and chapters
  Future<LocalComic?> _checkSingleComic(
    Directory directory, {
    String? id,
    String? title,
    String? subtitle,
    List<String>? tags,
    DateTime? createTime,
    bool useRelativePath = false,
  }) async {
    if (!(await directory.exists())) return null;
    var name = title ?? directory.name;
    if (LocalManager().findByName(name) != null) {
      Log.info("Import Comic", "Comic already exists: $name");
      return null;
    }
    final layout = await ComicFileSystemLayout.inspectAsync(directory);
    if (layout.nestedDirectories.isNotEmpty) {
      final nested = layout.nestedDirectories.first;
      Log.info(
        "Import Comic",
        "Invalid Chapter: ${nested.parent.name}\nA directory is found in the chapter directory.",
      );
      return null;
    }
    final cover = layout.inferredCover;
    if (!layout.hasImages || cover == null) {
      Log.info("Import Comic", "Invalid Comic: $name\nNo cover image found.");
      return null;
    }
    final chapters = layout.useChapterDirectories
        ? layout.chapters.map((chapter) => chapter.title).toList()
        : const <String>[];
    final coverPath = layout.relativePath(cover);
    var directoryPath = useRelativePath ? directory.name : directory.path;
    return LocalComic(
      id: id ?? '0',
      title: name,
      subtitle: subtitle ?? '',
      tags: tags ?? [],
      directory: directoryPath,
      chapters: layout.useChapterDirectories
          ? ComicChapters(Map.fromIterables(chapters, chapters))
          : null,
      cover: coverPath,
      comicType: ComicType.local,
      downloadedChapters: chapters,
      createdAt: createTime ?? DateTime.now(),
    );
  }

  static Future<Map<String, String>> _copyDirectories(
    Map<String, dynamic> data,
  ) async {
    return overrideIO(() async {
      var toBeCopied = data['toBeCopied'] as List<String>;
      var destination = data['destination'] as String;
      Map<String, String> result = {};
      for (var dir in toBeCopied) {
        var source = Directory(dir);
        var dest = Directory("$destination/${source.name}");
        if (dest.existsSync()) {
          // The destination directory already exists, and it is not managed by the app.
          // Rename the old directory to avoid conflicts.
          Log.info(
            "Import Comic",
            "Directory already exists: ${source.name}\nRenaming the old directory.",
          );
          dest.renameSync(
            findValidDirectoryName(dest.parent.path, "${dest.path}_old"),
          );
        }
        dest.createSync();
        await copyDirectory(source, dest);
        result[source.path] = dest.path;
      }
      return result;
    });
  }

  Future<Map<String?, List<LocalComic>>> _copyComicsToLocalDir(
    Map<String?, List<LocalComic>> comics,
  ) async {
    var destPath = LocalManager().path;
    Map<String?, List<LocalComic>> result = {};
    for (var favoriteFolder in comics.keys) {
      result[favoriteFolder] = comics[favoriteFolder]!
          .where((c) => c.directory.startsWith(destPath))
          .toList();
      comics[favoriteFolder]!.removeWhere(
        (c) => c.directory.startsWith(destPath),
      );

      if (comics[favoriteFolder]!.isEmpty) {
        continue;
      }

      try {
        // copy the comics to the local directory
        var pathMap = await compute<Map<String, dynamic>, Map<String, String>>(
          _copyDirectories,
          {
            'toBeCopied': comics[favoriteFolder]!
                .map((e) => e.directory)
                .toList(),
            'destination': destPath,
          },
        );
        //Construct a new object since LocalComic.directory is a final String
        for (var c in comics[favoriteFolder]!) {
          result[favoriteFolder]!.add(
            LocalComic(
              id: c.id,
              title: c.title,
              subtitle: c.subtitle,
              tags: c.tags,
              directory: pathMap[c.directory]!,
              chapters: c.chapters,
              cover: c.cover,
              comicType: c.comicType,
              downloadedChapters: c.downloadedChapters,
              createdAt: c.createdAt,
            ),
          );
        }
      } catch (e, s) {
        App.rootContext.showMessage(message: "Failed to copy comics".tl);
        Log.error("Import Comic", e.toString(), s);
        return result;
      }
    }
    return result;
  }

  Future<bool> registerComics(
    Map<String?, List<LocalComic>> importedComics,
    bool copy,
  ) async {
    try {
      if (copy) {
        importedComics = await _copyComicsToLocalDir(importedComics);
      }
      int importedCount = 0;
      for (var folder in importedComics.keys) {
        for (var comic in importedComics[folder]!) {
          var id = LocalManager().findValidId(ComicType.local);
          LocalManager().add(comic, id);
          importedCount++;
          if (folder != null) {
            LocalFavoritesManager().addComic(
              folder,
              FavoriteItem(
                id: id,
                name: comic.title,
                coverPath: comic.cover,
                author: comic.subtitle,
                type: comic.comicType,
                tags: comic.tags,
                favoriteTime: comic.createdAt,
              ),
            );
          }
        }
      }
      App.rootContext.showMessage(
        message: "Imported @a comics".tlParams({'a': importedCount}),
      );
    } catch (e, s) {
      App.rootContext.showMessage(message: "Failed to register comics".tl);
      Log.error("Import Comic", e.toString(), s);
      return false;
    }
    return true;
  }
}
