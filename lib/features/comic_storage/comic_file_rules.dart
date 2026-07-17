const comicImageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'jpe'};

const comicArchiveExtensions = {'cbz', 'zip', '7z', 'cb7'};

String comicFileExtension(String name) {
  final baseName = _baseName(name);
  final dot = baseName.lastIndexOf('.');
  if (dot <= 0 || dot == baseName.length - 1) return '';
  return baseName.substring(dot + 1).toLowerCase();
}

String comicFileStem(String name) {
  final baseName = _baseName(name);
  final dot = baseName.lastIndexOf('.');
  return dot <= 0 ? baseName : baseName.substring(0, dot);
}

bool isComicImageFileName(String name) {
  return comicImageExtensions.contains(comicFileExtension(name));
}

bool isComicArchiveFileName(String name) {
  return comicArchiveExtensions.contains(comicFileExtension(name));
}

bool isNamedComicCover(String name) {
  return isComicImageFileName(name) &&
      comicFileStem(name).toLowerCase() == 'cover';
}

bool isIgnoredComicStorageEntry(String name) {
  final baseName = _baseName(name);
  return baseName == '__MACOSX' ||
      baseName == '.DS_Store' ||
      baseName.startsWith('.');
}

List<T> sortedComicImageEntries<T>(
  Iterable<T> entries, {
  required String Function(T entry) nameOf,
  bool includeCover = true,
}) {
  final result = entries.where((entry) {
    final name = nameOf(entry);
    return !isIgnoredComicStorageEntry(name) &&
        isComicImageFileName(name) &&
        (includeCover || !isNamedComicCover(name));
  }).toList();
  result.sort((a, b) => compareComicFileNames(nameOf(a), nameOf(b)));
  return result;
}

T? findNamedComicCover<T>(
  Iterable<T> entries, {
  required String Function(T entry) nameOf,
}) {
  for (final entry in entries) {
    if (isNamedComicCover(nameOf(entry))) return entry;
  }
  return null;
}

int compareComicFileNames(String a, String b) {
  final aName = _baseName(a);
  final bName = _baseName(b);
  final aIndex = int.tryParse(comicFileStem(aName));
  final bIndex = int.tryParse(comicFileStem(bName));
  if (aIndex != null && bIndex != null) {
    final numericComparison = aIndex.compareTo(bIndex);
    if (numericComparison != 0) return numericComparison;
  }
  final insensitiveComparison = aName.toLowerCase().compareTo(
    bName.toLowerCase(),
  );
  return insensitiveComparison != 0
      ? insensitiveComparison
      : aName.compareTo(bName);
}

String _baseName(String name) {
  final slash = name.lastIndexOf('/');
  final backslash = name.lastIndexOf('\\');
  final separator = slash > backslash ? slash : backslash;
  return separator < 0 ? name : name.substring(separator + 1);
}
