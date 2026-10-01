import 'favorite_models.dart';
import 'favorites_repository.dart';
import 'package:venera_next/foundation/comic_type.dart';

/// Read-later policy without application globals or widget dependencies.
/// Mutation callbacks retain the owner's cache and notification behavior.
class ReadLaterService {
  ReadLaterService({
    required this.repository,
    required this.configuredFolder,
    required this.selectFolder,
    required this.createFolder,
    required this.addFirst,
    required this.remove,
    required this.saveSettings,
  });

  final FavoritesRepository Function() repository;
  final Object? Function() configuredFolder;
  final void Function(String) selectFolder;
  final void Function(String) createFolder;
  final void Function(String, FavoriteItem) addFirst;
  final void Function(String, String, ComicType) remove;
  final Future<void> Function() saveSettings;

  String? get folder {
    final value = configuredFolder();
    return value is String && repository().folderNames().contains(value)
        ? value
        : null;
  }

  bool contains(String id, ComicType type) {
    final current = folder;
    return current != null && repository().comicExists(current, id, type.value);
  }

  List<FavoriteItem> comics({int? limit}) {
    final current = folder;
    return current == null
        ? []
        : repository().getFolderComics(current, limit: limit);
  }

  Future<void> set(
    FavoriteItem comic, {
    required bool included,
    required String folderName,
  }) async {
    var current = folder;
    if (included) {
      if (current == null) {
        var candidate = folderName;
        var suffix = 2;
        final existing = repository().folderNames().toSet();
        while (existing.contains(candidate)) {
          candidate = '$folderName (${suffix++})';
        }
        createFolder(candidate);
        selectFolder(candidate);
        current = candidate;
      }
      addFirst(current, comic);
    } else if (current != null &&
        repository().comicExists(current, comic.id, comic.type.value)) {
      remove(current, comic.id, comic.type);
    }
    await saveSettings();
  }
}
