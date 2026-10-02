import 'dart:async';
import 'dart:convert';

import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';

import 'favorites.dart';
import 'models.dart';
import 'source.dart';

import 'source_parser_context.dart';

class SourceFavoritesParser {
  const SourceFavoritesParser(this.context);
  final SourceParserContext context;

  FavoriteData? loadFavoriteData() {
    if (!context.checkExists("favorites")) return null;

    final bool multiFolder = context.getValue("favorites.multiFolder");
    final bool? isOldToNewSort = context.getValue("favorites.isOldToNewSort");
    final bool? singleFolderForSingleComic = context.getValue(
      "favorites.singleFolderForSingleComic",
    );

    Future<Res<T>> retryZone<T>(Future<Res<T>> Function() func) async {
      if (!ComicSource.find(context.key)!.isLogged) {
        return const Res.error("Not login");
      }
      var res = await func();
      if (res.error && res.errorMessage!.contains("Login expired")) {
        var reLoginRes = await ComicSource.find(context.key)!.reLogin();
        if (!reLoginRes) {
          return const Res.error("Login expired and re-login failed");
        } else {
          return func();
        }
      }
      return res;
    }

    Future<Res<bool>> addOrDelFavFunc(
      String comicId,
      String folderId,
      bool isAdding,
      String? favId,
    ) async {
      func() async {
        try {
          await JsEngine().runCode("""
            ComicSource.sources.${context.key}.favorites.addOrDelFavorite(
              ${jsonEncode(comicId)}, ${jsonEncode(folderId)}, ${jsonEncode(isAdding)})
          """);
          return const Res(true);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res<bool>.error(e.toString());
        }
      }

      return retryZone(func);
    }

    Future<Res<List<Comic>>> Function(int page, [String? folder])? loadComic;

    Future<Res<List<Comic>>> Function(String? next, [String? folder])? loadNext;

    if (context.checkExists("favorites.loadComics")) {
      loadComic = (int page, [String? folder]) async {
        Future<Res<List<Comic>>> func() async {
          try {
            var res = await JsEngine().runReadCode("""
            ComicSource.sources.${context.key}.favorites.loadComics(
              ${jsonEncode(page)}, ${jsonEncode(folder)})
          """);
            return context.parseComicListResult(res, "maxPage");
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        }

        return retryZone(func);
      };
    }

    if (context.checkExists("favorites.loadNext")) {
      loadNext = (String? next, [String? folder]) async {
        Future<Res<List<Comic>>> func() async {
          try {
            var res = await JsEngine().runReadCode("""
            ComicSource.sources.${context.key}.favorites.loadNext(
              ${jsonEncode(next)}, ${jsonEncode(folder)})
          """);
            return context.parseComicListResult(res, "next");
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        }

        return retryZone(func);
      };
    }

    Future<Res<Map<String, String>>> Function([String? comicId])? loadFolders;

    Future<Res<bool>> Function(String name)? addFolder;

    Future<Res<bool>> Function(String key)? deleteFolder;

    if (multiFolder) {
      loadFolders = ([String? comicId]) async {
        Future<Res<Map<String, String>>> func() async {
          try {
            var res = await JsEngine().runReadCode("""
            ComicSource.sources.${context.key}.favorites.loadFolders(${jsonEncode(comicId)})
          """);
            List<String>? subData;
            if (res["favorited"] != null) {
              subData = List.from(res["favorited"]);
            }
            return Res(Map.from(res["folders"]), subData: subData);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        }

        return retryZone(func);
      };
      if (context.checkExists("favorites.addFolder")) {
        addFolder = (name) async {
          try {
            await JsEngine().runCode("""
            ComicSource.sources.${context.key}.favorites.addFolder(${jsonEncode(name)})
          """);
            return const Res(true);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      }
      if (context.checkExists("favorites.deleteFolder")) {
        deleteFolder = (key) async {
          try {
            await JsEngine().runCode("""
            ComicSource.sources.${context.key}.favorites.deleteFolder(${jsonEncode(key)})
          """);
            return const Res(true);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      }
    }

    return FavoriteData(
      key: context.key,
      title: context.name,
      multiFolder: multiFolder,
      loadComic: loadComic,
      loadNext: loadNext,
      loadFolders: loadFolders,
      addFolder: addFolder,
      deleteFolder: deleteFolder,
      addOrDelFavorite: addOrDelFavFunc,
      isOldToNewSort: isOldToNewSort,
      singleFolderForSingleComic: singleFolderForSingleComic ?? false,
    );
  }
}
