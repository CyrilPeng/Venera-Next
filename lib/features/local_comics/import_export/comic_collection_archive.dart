import 'dart:io';

import 'package:archive/archive_io.dart' as archive;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/features/comic_storage/comic_storage.dart';

/// The caller owns the empty workspace until extraction and import have drained.
/// This explicit collection path does not reinterpret ordinary CBZ imports.
Future<void> extractComicCollection(File source, Directory workspace) =>
    compute(_extractCollection, (source: source.path, output: workspace.path));

class ComicCollectionLayout {
  const ComicCollectionLayout(
    this.root, {
    this.enclosingComic,
    this.comicTitles = const [],
  });

  final Directory root;

  /// Non-null when the same tree also describes a single book with chapters.
  final String? enclosingComic;
  final List<String> comicTitles;
}

/// Inspect only the optional outer folder, never flatten arbitrary nesting.
Future<ComicCollectionLayout> inspectComicCollection(
  Directory workspace,
) async {
  Future<List<FileSystemEntity>> visible(Directory directory) async => [
    await for (final entry in directory.list(followLinks: false))
      if (!isIgnoredComicStorageEntry(p.basename(entry.path))) entry,
  ];

  final roots = (await visible(workspace)).whereType<Directory>().toList();
  if (roots.length != 1) return ComicCollectionLayout(workspace);
  final outer = roots.single;
  final entries = await visible(outer);
  // A page or explicit cover is evidence that this is already the book root.
  if (entries.whereType<File>().any(
    (file) => isComicImageFileName(file.path),
  )) {
    return ComicCollectionLayout(workspace);
  }
  final children = entries.whereType<Directory>().toList()
    ..sort((a, b) => compareComicFileNames(a.path, b.path));
  final titles = <String>[];
  for (final child in children) {
    final layout = await ComicFileSystemLayout.inspectAsync(child);
    if (layout.hasImages && layout.nestedDirectories.isEmpty) {
      titles.add(p.basename(child.path));
    }
  }
  if (titles.isEmpty) return ComicCollectionLayout(workspace);
  final original = await ComicFileSystemLayout.inspectAsync(outer);
  return ComicCollectionLayout(
    outer,
    enclosingComic: original.hasImages && original.nestedDirectories.isEmpty
        ? p.basename(outer.path)
        : null,
    comicTitles: List.unmodifiable(titles),
  );
}

Future<void> _extractCollection(
  ({String source, String output}) request,
) async {
  final root = Directory(request.output);
  if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
          FileSystemEntityType.directory ||
      root.listSync(followLinks: false).isNotEmpty) {
    throw StateError('Collection extraction requires an empty owned directory');
  }
  final input = archive.InputFileStream(request.source);
  try {
    final entries =
        <({archive.ArchiveFile entry, String name, bool directory})>[];
    final names = <String, bool>{};
    archive.ZipDecoder().decodeStream(
      input,
      throwOnError: true,
      callback: (entry) {
        final raw = entry.name.replaceAll('\\', '/');
        final segments = raw
            .split('/')
            .where((s) => s.isNotEmpty && s != '.')
            .toList();
        if (p.posix.isAbsolute(raw) ||
            p.windows.isAbsolute(raw) ||
            segments.any(
              (s) =>
                  s == '..' ||
                  RegExp(r'[\x00<>:"|?*]').hasMatch(s) ||
                  s.endsWith('.') ||
                  s.endsWith(' ') ||
                  RegExp(
                    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
                    caseSensitive: false,
                  ).hasMatch(s),
            ) ||
            segments.length > 32) {
          throw const FormatException('The collection contains an unsafe path');
        }
        final mode = entry.mode & 0xf000;
        if (entry.isSymbolicLink || ![0, 0x4000, 0x8000].contains(mode)) {
          throw const FormatException(
            'Symbolic links and special files are not imported',
          );
        }
        final directory =
            entry.isDirectory || mode == 0x4000 || raw.endsWith('/');
        if (segments.isEmpty) {
          if (directory) return;
          throw const FormatException('The collection contains an unsafe path');
        }
        final name = p.joinAll(segments);
        final key = name.toLowerCase();
        if (names.containsKey(key)) {
          throw const FormatException(
            'The collection contains conflicting paths',
          );
        }
        names[key] = directory;
        if (!directory &&
            segments.length == 1 &&
            !isIgnoredComicStorageEntry(name) &&
            isComicImageFileName(name)) {
          throw const FormatException(
            'The collection root must contain comic folders, not image files',
          );
        }
        entries.add((entry: entry, name: name, directory: directory));
      },
    );
    // Validate all paths before writing, including file/parent collisions. The
    // decoder callback also sees duplicate entries that Archive would coalesce.
    for (final item in entries) {
      var parent = p.dirname(item.name);
      while (parent != '.') {
        if (names[parent.toLowerCase()] == false) {
          throw const FormatException(
            'The collection contains conflicting paths',
          );
        }
        parent = p.dirname(parent);
      }
    }
    for (final item in entries) {
      final destination = p.join(root.path, item.name);
      if (!p.isWithin(root.path, destination)) {
        throw const FormatException('The collection contains an unsafe path');
      }
      if (item.directory) {
        Directory(destination).createSync(recursive: true);
        continue;
      }
      final file = File(destination);
      file.parent.createSync(recursive: true);
      final output = archive.OutputFileStream(destination);
      try {
        item.entry.writeContent(output);
      } finally {
        output.closeSync();
      }
      var size = 0;
      var crc = 0;
      await for (final bytes in file.openRead()) {
        size += bytes.length;
        crc = archive.getCrc32(bytes, crc);
      }
      // Validate the actual streamed bytes independently of decoder defaults.
      if (size != item.entry.size || crc != item.entry.crc32) {
        throw const FormatException(
          'The collection contains damaged file data',
        );
      }
    }
  } finally {
    await input.close();
  }
}
