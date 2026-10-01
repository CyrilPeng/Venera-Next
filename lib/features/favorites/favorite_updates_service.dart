import 'favorites_repository.dart';

/// Tracking-folder state follows current configuration and committed storage.
class FavoriteUpdatesService {
  FavoriteUpdatesService({required this.repository, required this.folder});

  final FavoritesRepository Function() repository;
  final Object? Function() folder;
  Set<(String, int)> _identities = {};
  String? _loadedFolder;

  void clear() {
    _identities.clear();
    _loadedFolder = null;
  }

  void refresh() {
    final selected = folder();
    if (selected is! String || !repository().folderNames().contains(selected)) {
      clear();
      return;
    }
    final identities = repository()
        .identities(selected, updatedOnly: true)
        .toSet();
    _identities = identities;
    _loadedFolder = selected;
  }

  bool contains(String id, int type) =>
      folder() == _loadedFolder && _identities.contains((id, type));

  void recordCommittedUpdate(
    String targetFolder,
    String id,
    int type,
    bool updated,
  ) {
    if (folder() != targetFolder) return;
    if (_loadedFolder != targetFolder) {
      // A configuration switch must not relabel identities from the old folder.
      refresh();
      return;
    }
    if (updated) {
      _identities.add((id, type));
    } else {
      _identities.remove((id, type));
    }
  }

  void recordCommittedRead(String id, int type) {
    if (folder() != _loadedFolder) refresh();
    _identities.remove((id, type));
  }
}
