final _asciiUppercase = RegExp(r'[A-Z]');

/// SQLite folds ASCII in table names, but preserves non-ASCII case distinctions.
String favoriteFolderNameKey(String name) => name.replaceAllMapped(
  _asciiUppercase,
  (match) => String.fromCharCode(match[0]!.codeUnitAt(0) + 32),
);

bool hasFavoriteFolderName(
  Iterable<String> folders,
  String name, {
  String? excluding,
}) {
  final key = favoriteFolderNameKey(name);
  return folders.any(
    (folder) => folder != excluding && favoriteFolderNameKey(folder) == key,
  );
}
