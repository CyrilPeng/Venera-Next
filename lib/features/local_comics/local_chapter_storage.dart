/// Existing chapter-to-directory mapping. Keep this stable for downloaded books.
String localChapterDirectoryName(String name) {
  final builder = StringBuffer();
  for (var i = 0; i < name.length; i++) {
    final char = name[i];
    builder.write('/\\:*?"<>|'.contains(char) ? '_' : char);
  }
  return builder.toString();
}

/// Only remove directories that are not shared with retained chapters. Treat
/// case and trailing dots/spaces conservatively for case-insensitive filesystems.
/// Empty/dot paths never designate a deletable chapter directory.
List<String> localChapterDirectoriesToDelete({
  required Iterable<String> removed,
  required Iterable<String> retained,
}) {
  String key(String name) =>
      name.replaceFirst(RegExp(r'[. ]+$'), '').toLowerCase();
  final protected = retained.map(localChapterDirectoryName).map(key).toSet();
  final selected = <String>{};
  final directories = <String>[];
  for (final chapter in removed) {
    final directory = localChapterDirectoryName(chapter);
    final identity = key(directory);
    if (identity.isEmpty ||
        protected.contains(identity) ||
        !selected.add(identity)) {
      continue;
    }
    directories.add(directory);
  }
  return directories;
}
