import 'dart:convert';
import 'favorite_models.dart';
import 'favorites_repository.dart';
import 'package:venera_next/foundation/sqlite_transaction.dart';

/// Decode the entire folder before writing; publish no partial folder on error.
(String, List<FavoriteItem>) importFavoriteFolder(
  String json,
  FavoritesRepository repository, {
  required bool append,
  required String Function(List<String>) translateTags,
}) {
  final data = jsonDecode(json);
  if (data is! Map || data['name'] is! String || data['comics'] is! List) {
    throw const FormatException('Invalid favorite folder data');
  }
  final name = data['name'] as String;
  if (name.isEmpty) throw const FormatException('Empty favorite folder name');
  final comics = (data['comics'] as List)
      .map((value) => FavoriteItem.fromJson(value))
      .toList();
  final translations = comics
      .map((comic) => translateTags(comic.tags))
      .toList();
  return runSqliteTransaction(repository.db, () {
    final folders = repository.folderNames().toSet();
    var folder = name;
    var suffix = 0;
    while (folders.contains(folder)) {
      folder = '$name(${suffix++})';
    }
    repository.createFolder(folder);
    for (var index = 0; index < comics.length; index++) {
      repository.addComic(
        folder,
        comics[index],
        translatedTags: translations[index],
        append: append,
      );
    }
    return (folder, comics);
  });
}
