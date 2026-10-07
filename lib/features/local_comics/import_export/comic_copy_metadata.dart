import 'dart:convert';

import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/comic_type.dart';

import '../local_comic_model.dart';

/// Capture import intent before the copy isolate runs. LocalComic.toJson is a
/// display/history representation and omits fields needed to resume an import.
String encodeComicCopyMetadata(LocalComic comic, String? folder) => jsonEncode({
  'version': 1,
  'title': comic.title,
  'subtitle': comic.subtitle,
  'tags': comic.tags,
  'chapters': comic.chapters?.toJson(),
  'cover': comic.cover,
  'type': comic.comicType.value,
  'downloadedChapters': comic.downloadedChapters,
  'createdAt': comic.createdAt.toIso8601String(),
  'folder': folder,
});

// SQLite persists milliseconds, while the source may carry microseconds or a
// different timezone. Compare persisted values, retaining chapter/tag order.
String _storedMetadata(LocalComic comic) => jsonEncode({
  'title': comic.title,
  'subtitle': comic.subtitle,
  'tags': comic.tags,
  'chapters': comic.chapters?.toJson(),
  'cover': comic.cover,
  'type': comic.comicType.value,
  'downloadedChapters': comic.downloadedChapters,
  'createdAt': comic.createdAt.millisecondsSinceEpoch,
});

bool matchesComicCopyMetadata(LocalComic intended, LocalComic registered) =>
    _storedMetadata(intended) == _storedMetadata(registered);

/// Bind cleanup to the current row, not title or a guessed folder association.
String comicCopyRegistration(LocalComic comic) => jsonEncode({
  'id': comic.id,
  'directory': comic.directory,
  'metadata': _storedMetadata(comic),
});

({LocalComic comic, String? folder}) decodeComicCopyMetadata(
  String encoded,
  String directory,
) {
  final data = jsonDecode(encoded);
  if (data is! Map<String, dynamic> ||
      data['version'] != 1 ||
      data['title'] is! String ||
      data['subtitle'] is! String ||
      data['cover'] is! String ||
      data['type'] is! int ||
      data['createdAt'] is! String ||
      (data['folder'] != null && data['folder'] is! String)) {
    throw const FormatException('Invalid comic copy metadata');
  }
  final tags = List<String>.from(data['tags'] as List);
  final downloaded = List<String>.from(data['downloadedChapters'] as List);
  final chapters = data['chapters'];
  if (chapters != null) {
    if (chapters is! Map<String, dynamic> ||
        !chapters.values.every((value) => value is String) &&
            !chapters.values.every(
              (value) =>
                  value is Map<String, dynamic> &&
                  value.values.every((title) => title is String),
            )) {
      throw const FormatException('Invalid comic copy chapters');
    }
  }
  final parsedChapters = ComicChapters.fromJsonOrNull(chapters);
  // Recovery must never turn metadata into an absolute/traversing file path.
  void relativePath(String value) {
    final segments = value.replaceAll('\\', '/').split('/');
    if (segments.any((part) => part.isEmpty || part == '.' || part == '..') ||
        value.contains(':')) {
      throw const FormatException('Invalid copied comic relative path');
    }
  }

  relativePath(data['cover'] as String);
  for (final chapter in [...?parsedChapters?.ids, ...downloaded]) {
    relativePath(chapter);
  }
  return (
    comic: LocalComic(
      id: '0',
      title: data['title'] as String,
      subtitle: data['subtitle'] as String,
      tags: tags,
      directory: directory,
      chapters: parsedChapters,
      cover: data['cover'] as String,
      comicType: ComicType(data['type'] as int),
      downloadedChapters: downloaded,
      createdAt: DateTime.parse(data['createdAt'] as String),
    ),
    folder: data['folder'] as String?,
  );
}
