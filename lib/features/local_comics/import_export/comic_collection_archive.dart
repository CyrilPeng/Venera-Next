import 'dart:io';

import 'package:archive/archive_io.dart' as archive;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/features/comic_storage/comic_storage.dart';

class ComicArchiveLimits {
  const ComicArchiveLimits({
    this.maxEntries = 100000,
    this.maxExpandedBytes = 8 * 1024 * 1024 * 1024,
    this.maxComics = 1000,
  });

  final int maxEntries;
  final int maxExpandedBytes;
  final int maxComics;
}

class ComicArchiveIndex {
  ComicArchiveIndex(this.entryCount, this.expandedBytes, Iterable<String> files)
    : files = List.unmodifiable(files);

  final int entryCount;
  final int expandedBytes;
  final List<String> files;

  /// Only an archive of CBZ files at its root or in one common outer folder.
  /// Image/chapter archives keep their existing single-comic interpretation.
  List<String>? get cbzFiles {
    final visible = files
        .where((name) => !p.split(name).any(isIgnoredComicStorageEntry))
        .toList();
    if (visible.isEmpty ||
        visible.any((name) => p.extension(name).toLowerCase() != '.cbz')) {
      return null;
    }
    final parts = visible.map(p.split).toList();
    if (!parts.every((name) => name.length == 1) &&
        !parts.every(
          (name) => name.length == 2 && name.first == parts.first.first,
        )) {
      return null;
    }
    visible.sort(compareComicFileNames);
    return List.unmodifiable(visible);
  }
}

/// Inspect metadata without expanding file content, away from the UI isolate.
Future<ComicArchiveIndex> inspectComicArchive(
  File source, {
  ComicArchiveLimits limits = const ComicArchiveLimits(),
}) => compute(_inspectArchive, (source: source.path, limits: limits));

/// The caller owns the empty workspace until extraction and import have drained.
/// Root pages are allowed only when explicitly extracting an individual CBZ.
Future<void> extractComicCollection(
  File source,
  Directory workspace, {
  bool allowRootImages = false,
  ComicArchiveLimits limits = const ComicArchiveLimits(),
}) => compute(_extractCollection, (
  source: source.path,
  output: workspace.path,
  allowRootImages: allowRootImages,
  limits: limits,
));

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

typedef _ArchiveEntry = ({
  archive.ArchiveFile entry,
  String name,
  bool directory,
});

({List<_ArchiveEntry> entries, int count, int expandedBytes}) _readEntries(
  archive.InputFileStream input, {
  required bool allowRootImages,
  required ComicArchiveLimits limits,
}) {
  final entries = <_ArchiveEntry>[];
  final names = <String, bool>{};
  var count = 0;
  var expandedBytes = 0;
  archive.ZipDecoder().decodeStream(
    input,
    throwOnError: true,
    callback: (entry) {
      count++;
      expandedBytes += entry.size;
      if (entry.size < 0 ||
          count > limits.maxEntries ||
          expandedBytes > limits.maxExpandedBytes) {
        throw const FormatException('The archive exceeds import limits');
      }
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
      if (!allowRootImages &&
          !directory &&
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
  // Validate before writing, including duplicates seen by the decoder callback
  // and file/parent collisions that Archive would otherwise coalesce.
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
  return (entries: entries, count: count, expandedBytes: expandedBytes);
}

Future<ComicArchiveIndex> _inspectArchive(
  ({String source, ComicArchiveLimits limits}) request,
) async {
  final input = archive.InputFileStream(request.source);
  try {
    final decoded = _readEntries(
      input,
      allowRootImages: true,
      limits: request.limits,
    );
    return ComicArchiveIndex(
      decoded.count,
      decoded.expandedBytes,
      decoded.entries.where((item) => !item.directory).map((item) => item.name),
    );
  } finally {
    await input.close();
  }
}

Future<void> _extractCollection(
  ({
    String source,
    String output,
    bool allowRootImages,
    ComicArchiveLimits limits,
  })
  request,
) async {
  final root = Directory(request.output);
  if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
          FileSystemEntityType.directory ||
      root.listSync(followLinks: false).isNotEmpty) {
    throw StateError('Collection extraction requires an empty owned directory');
  }
  final input = archive.InputFileStream(request.source);
  try {
    final decoded = _readEntries(
      input,
      allowRootImages: request.allowRootImages,
      limits: request.limits,
    );
    for (final item in decoded.entries) {
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
