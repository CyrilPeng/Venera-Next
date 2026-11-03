class FavoriteFolder {
  const FavoriteFolder({
    required this.id,
    required this.name,
    required this.order,
    this.parentId,
  });

  final String id;
  final String name;
  final String? parentId;
  final int order;
}

/// An immutable, validated two-level snapshot. Names remain storage keys;
/// stable IDs belong to hierarchy relationships, not display paths.
class FavoriteFolderTree {
  FavoriteFolderTree(Iterable<FavoriteFolder> folders) {
    for (final folder in folders) {
      if (folder.id.isEmpty ||
          folder.name.isEmpty ||
          _byId.containsKey(folder.id) ||
          _byName.containsKey(folder.name)) {
        throw const FormatException('Invalid favorite folder identity');
      }
      _byId[folder.id] = folder;
      _byName[folder.name] = folder;
    }
    for (final folder in _byId.values) {
      final parent = _byId[folder.parentId];
      if (folder.parentId != null &&
          (parent == null ||
              parent.id == folder.id ||
              parent.parentId != null)) {
        throw const FormatException('Invalid two-level favorite hierarchy');
      }
      (_children[folder.parentId] ??= []).add(folder);
    }
    for (final siblings in _children.values) {
      siblings.sort((a, b) {
        final order = a.order.compareTo(b.order);
        return order == 0 ? a.name.compareTo(b.name) : order;
      });
    }
  }

  factory FavoriteFolderTree.flat(Iterable<String> names) =>
      FavoriteFolderTree([
        for (final (index, name) in names.indexed)
          FavoriteFolder(id: name, name: name, order: index),
      ]);

  final _byId = <String, FavoriteFolder>{};
  final _byName = <String, FavoriteFolder>{};
  final _children = <String?, List<FavoriteFolder>>{};

  FavoriteFolder? named(String name) => _byName[name];
  FavoriteFolder? identified(String id) => _byId[id];

  List<FavoriteFolder> childrenOf(String? id) =>
      List.unmodifiable(_children[id] ?? const <FavoriteFolder>[]);

  List<FavoriteFolder> get roots => childrenOf(null);

  List<FavoriteFolder> get flattened => [
    for (final root in roots) ...[root, ...childrenOf(root.id)],
  ];

  String label(String name) {
    final folder = named(name);
    final parent = _byId[folder?.parentId];
    return parent == null ? name : '${parent.name} / $name';
  }
}
