import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'webdav_library_entries.dart';

const webDavLibrarySnapshotFormatVersion = 3;

class WebDavComicSnapshot {
  const WebDavComicSnapshot({
    required this.title,
    required this.author,
    required this.tags,
    required this.cover,
    required this.chapters,
    required this.metadataChapters,
    required this.rootImages,
  });

  final String title;
  final String author;
  final List<String> tags;
  final String cover;
  final Map<String, String> chapters;
  final Map<String, ComicChapter> metadataChapters;
  final List<WebDavLibraryEntry> rootImages;

  factory WebDavComicSnapshot.fromJson(Map<String, dynamic> json) {
    final chapters = json['chapters'];
    final metadataChapters = json['metadataChapters'];
    final rootImages = json['rootImages'];
    return WebDavComicSnapshot(
      title: json['title'] as String,
      author: json['author'] as String? ?? '',
      tags: (json['tags'] as List?)?.whereType<String>().toList() ?? const [],
      cover: json['cover'] as String? ?? '',
      chapters: chapters is Map
          ? chapters.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
          : const {},
      metadataChapters: metadataChapters is Map
          ? metadataChapters.map(
              (key, value) => MapEntry(
                key.toString(),
                ComicChapter.fromJson(Map<String, dynamic>.from(value as Map)),
              ),
            )
          : const {},
      rootImages: rootImages is List
          ? rootImages
                .whereType<Map>()
                .map(
                  (entry) => WebDavLibraryEntry(
                    name: entry['name'] as String,
                    isDirectory: false,
                    eTag: entry['eTag'] as String?,
                    modifiedAt: entry['modifiedAt'] as int?,
                  ),
                )
                .toList()
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
    'formatVersion': webDavLibrarySnapshotFormatVersion,
    'title': title,
    'author': author,
    'tags': tags,
    'cover': cover,
    'chapters': chapters,
    'metadataChapters': metadataChapters.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
    'rootImages': [
      for (final entry in rootImages)
        {
          'name': entry.name,
          'eTag': entry.eTag,
          'modifiedAt': entry.modifiedAt,
        },
    ],
  };

  Map<String, List<String>> get detailTags => {
    'Source': const ['WebDAV'],
    if (tags.isNotEmpty) 'Tags': tags,
  };
}
