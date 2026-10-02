import 'package:venera_next/features/comic_storage/comic_storage.dart';

class WebDavLibraryEntry {
  const WebDavLibraryEntry({
    required this.name,
    required this.isDirectory,
    this.eTag,
    this.modifiedAt,
  });

  final String name;
  final bool isDirectory;
  final String? eTag;
  final int? modifiedAt;
}

const webDavRootChapterId = '__root__';
const webDavRootChapterTitle = 'Images';
const webDavMetadataFileName = 'metadata.json';
const webDavMetadataChapterPrefix = '__cbz_range_';

List<WebDavLibraryEntry> webDavSortedDirectories(
  List<WebDavLibraryEntry> entries,
) {
  return entries
      .where((entry) => entry.isDirectory)
      .where((entry) => !_isIgnoredEntry(entry.name))
      .toList()
    ..sort((a, b) => compareComicFileNames(a.name, b.name));
}

List<WebDavLibraryEntry> webDavImageEntries(List<WebDavLibraryEntry> entries) {
  return sortedComicImageEntries(
    entries.where((entry) => !entry.isDirectory),
    nameOf: (entry) => entry.name,
  );
}

WebDavLibraryEntry? webDavFindNamedCover(List<WebDavLibraryEntry> entries) {
  return findNamedComicCover(
    webDavImageEntries(entries),
    nameOf: (entry) => entry.name,
  );
}

bool _isIgnoredEntry(String name) {
  return isIgnoredComicStorageEntry(name) || isComicArchiveFileName(name);
}
