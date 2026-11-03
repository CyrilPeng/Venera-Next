import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'local_comic_model.dart';

LocalComic localComicFromRow(Row row) => LocalComic(
  id: row['id'] as String,
  title: row['title'] as String,
  subtitle: row['subtitle'] as String,
  tags: List<String>.from(jsonDecode(row['tags'] as String)),
  directory: row['directory'] as String,
  chapters: ComicChapters.fromJsonOrNull(jsonDecode(row['chapters'] as String)),
  cover: row['cover'] as String,
  comicType: ComicType(row['comic_type'] as int),
  downloadedChapters: List<String>.from(
    jsonDecode(row['downloadedChapters'] as String),
  ),
  createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
  incompleteChapters: Map.unmodifiable({
    for (final entry
        in (jsonDecode(
                  row.keys.contains('incomplete_pages')
                      ? row['incomplete_pages'] as String
                      : '{}',
                )
                as Map)
            .entries)
      entry.key as String: IncompleteChapter.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      ),
  }),
);
