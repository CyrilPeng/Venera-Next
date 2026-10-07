import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/file_system.dart';

import 'image_favorites_models.dart';

/// Keep the persisted v2 identity shared by display and cache deletion.
String imageFavoriteCacheKey(ImageFavorite favorite) =>
    'ImageFavorites v2 ${jsonEncode([
      favorite.sourceKey,
      favorite.id,
      favorite.eid.isEmpty ? ['ordinal', favorite.ep] : ['id', favorite.eid],
      favorite.page,
      favorite.imageKey,
    ])}';

File imageFavoriteCacheFile(String key) => File(
  FilePath.join(
    App.cachePath,
    'image_favorites',
    md5.convert(key.codeUnits).toString(),
  ),
);

Future<void> deleteImageFavoriteCache(ImageFavorite favorite) async {
  final file = imageFavoriteCacheFile(imageFavoriteCacheKey(favorite));
  if (file.existsSync()) {
    await file.delete();
  }
}
