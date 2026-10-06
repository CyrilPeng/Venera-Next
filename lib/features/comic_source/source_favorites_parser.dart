import 'dart:async';
import 'dart:convert';

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
      try {
        context.checkCurrent();
        final source = ComicSource.requireRuntime(
          context.key,
          context.identity,
        );
        if (!source.isLogged) return const Res.error('Not login');
        final res = await func();
        context.checkCurrent();
        if (res.error && res.errorMessage!.contains('Login expired')) {
          final loggedIn = await source.reLogin();
          context.checkCurrent();
          if (!loggedIn) {
            return const Res.error('Login expired and re-login failed');
          }
          return func();
        }
        return res;
      } catch (error, stack) {
        return Res.fromException(error, stack);
      }
    }

    Future<Res<bool>> addOrDelFavFunc(
      String comicId,
      String folderId,
      bool isAdding,
      String? favId,
    ) async {
      func() async {
        try {
          await context.runCode("""
            ${context.sourceExpression}.favorites.addOrDelFavorite(
              ${jsonEncode(comicId)}, ${jsonEncode(folderId)}, ${jsonEncode(isAdding)})
          """);
          return const Res(true);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res<bool>.fromException(e, s);
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
            var res = await context.runReadCode("""
            ${context.sourceExpression}.favorites.loadComics(
              ${jsonEncode(page)}, ${jsonEncode(folder)})
          """);
            return context.parseComicListResult(res, "maxPage");
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.fromException(e, s);
          }
        }

        return retryZone(func);
      };
    }

    if (context.checkExists("favorites.loadNext")) {
      loadNext = (String? next, [String? folder]) async {
        Future<Res<List<Comic>>> func() async {
          try {
            var res = await context.runReadCode("""
            ${context.sourceExpression}.favorites.loadNext(
              ${jsonEncode(next)}, ${jsonEncode(folder)})
          """);
            return context.parseComicListResult(res, "next");
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.fromException(e, s);
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
            var res = await context.runReadCode("""
            ${context.sourceExpression}.favorites.loadFolders(${jsonEncode(comicId)})
          """);
            List<String>? subData;
            if (res["favorited"] != null) {
              subData = List.from(res["favorited"]);
            }
            return Res(Map.from(res["folders"]), subData: subData);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.fromException(e, s);
          }
        }

        return retryZone(func);
      };
      if (context.checkExists("favorites.addFolder")) {
        addFolder = (name) async {
          try {
            await context.runCode("""
            ${context.sourceExpression}.favorites.addFolder(${jsonEncode(name)})
          """);
            return const Res(true);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.fromException(e, s);
          }
        };
      }
      if (context.checkExists("favorites.deleteFolder")) {
        deleteFolder = (key) async {
          try {
            await context.runCode("""
            ${context.sourceExpression}.favorites.deleteFolder(${jsonEncode(key)})
          """);
            return const Res(true);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.fromException(e, s);
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
