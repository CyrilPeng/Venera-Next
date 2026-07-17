import 'package:path/path.dart' as path;
import 'package:venera_next/foundation/file_system.dart';

import 'comic_file_rules.dart';

class ComicFileSystemChapter {
  const ComicFileSystemChapter({
    required this.title,
    required this.directory,
    required this.pages,
    this.cover,
  });

  final String title;
  final Directory directory;
  final List<File> pages;
  final File? cover;
}

class ComicFileSystemLayout {
  const ComicFileSystemLayout({
    required this.root,
    required this.rootPages,
    required this.chapters,
    required this.nestedDirectories,
    this.cover,
  });

  final Directory root;
  final List<File> rootPages;
  final List<ComicFileSystemChapter> chapters;
  final List<Directory> nestedDirectories;
  final File? cover;

  bool get useChapterDirectories => rootPages.isEmpty && chapters.isNotEmpty;

  bool get hasImages => rootPages.isNotEmpty || chapters.isNotEmpty;

  File? get inferredCover {
    if (cover != null) return cover;
    if (rootPages.isNotEmpty) return rootPages.first;
    if (chapters.isEmpty) return null;
    return chapters.first.cover ?? chapters.first.pages.first;
  }

  String relativePath(File file) {
    if (file.parent.path == root.path) return file.name;
    for (final chapter in chapters) {
      if (file.parent.path == chapter.directory.path) {
        return FilePath.join(chapter.title, file.name);
      }
    }
    return path.relative(file.path, from: root.path);
  }

  static ComicFileSystemLayout inspect(
    Directory directory, {
    bool unwrapSingleDirectory = false,
  }) {
    final root = unwrapSingleDirectory
        ? _normalizeSingleDirectoryRoot(directory)
        : directory;
    final entries = _visibleEntries(root.listSync());
    final chapterEntries = <String, List<FileSystemEntity>>{
      for (final chapter in entries.whereType<Directory>())
        chapter.path: _visibleEntries(chapter.listSync()),
    };
    return _build(root, entries, chapterEntries);
  }

  static Future<ComicFileSystemLayout> inspectAsync(
    Directory directory, {
    bool unwrapSingleDirectory = false,
  }) async {
    final root = unwrapSingleDirectory
        ? await _normalizeSingleDirectoryRootAsync(directory)
        : directory;
    final entries = _visibleEntries(await root.list().toList());
    final chapterEntries = <String, List<FileSystemEntity>>{};
    for (final chapter in entries.whereType<Directory>()) {
      chapterEntries[chapter.path] = _visibleEntries(
        await chapter.list().toList(),
      );
    }
    return _build(root, entries, chapterEntries);
  }

  static ComicFileSystemLayout _build(
    Directory root,
    List<FileSystemEntity> entries,
    Map<String, List<FileSystemEntity>> chapterEntriesByPath,
  ) {
    final rootImages = sortedComicImageEntries(
      entries.whereType<File>(),
      nameOf: (file) => file.name,
    );
    final cover = findNamedComicCover(rootImages, nameOf: (file) => file.name);
    final rootPages = sortedComicImageEntries(
      rootImages,
      nameOf: (file) => file.name,
      includeCover: false,
    );
    final directories = entries.whereType<Directory>().toList()
      ..sort((a, b) => compareComicFileNames(a.name, b.name));
    final chapters = <ComicFileSystemChapter>[];
    final nestedDirectories = <Directory>[];
    for (final chapterDirectory in directories) {
      final chapterEntries = chapterEntriesByPath[chapterDirectory.path] ?? [];
      nestedDirectories.addAll(chapterEntries.whereType<Directory>());
      final chapterImages = sortedComicImageEntries(
        chapterEntries.whereType<File>(),
        nameOf: (file) => file.name,
      );
      final chapterCover = findNamedComicCover(
        chapterImages,
        nameOf: (file) => file.name,
      );
      final pages = sortedComicImageEntries(
        chapterImages,
        nameOf: (file) => file.name,
        includeCover: false,
      );
      if (pages.isEmpty) continue;
      chapters.add(
        ComicFileSystemChapter(
          title: chapterDirectory.name,
          directory: chapterDirectory,
          pages: pages,
          cover: chapterCover,
        ),
      );
    }
    return ComicFileSystemLayout(
      root: root,
      rootPages: rootPages,
      chapters: chapters,
      nestedDirectories: nestedDirectories,
      cover: cover,
    );
  }
}

Directory _normalizeSingleDirectoryRoot(Directory directory) {
  final entries = _visibleEntries(directory.listSync());
  return entries.length == 1 && entries.first is Directory
      ? entries.first as Directory
      : directory;
}

Future<Directory> _normalizeSingleDirectoryRootAsync(
  Directory directory,
) async {
  final entries = _visibleEntries(await directory.list().toList());
  return entries.length == 1 && entries.first is Directory
      ? entries.first as Directory
      : directory;
}

List<FileSystemEntity> _visibleEntries(Iterable<FileSystemEntity> entries) {
  return entries
      .where((entry) => !isIgnoredComicStorageEntry(entry.name))
      .toList();
}
