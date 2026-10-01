import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites_api.dart';
import 'package:venera_next/features/history/history_api.dart';
import 'package:venera_next/foundation/comic_type.dart';

class LegacyPicaFolderLink {
  const LegacyPicaFolderLink(this.folder, this.sourceKey, this.syncData);
  final String folder;
  final String sourceKey;
  final Object? syncData;

  // Decode only after the caller decides whether an existing link wins.
  String get networkFolder =>
      jsonDecode(syncData as String)['folderId'] as String;
}

class LegacyPicaImage {
  const LegacyPicaImage(
    this.id,
    this.sourceKey,
    this.page,
    this.ep,
    this.title,
  );
  final String id;
  final String sourceKey;
  final int page;
  final int ep;
  final String title;
}

/// Reads old-format rows from a caller-owned connection without writing data.
class LegacyPicaReader {
  const LegacyPicaReader(this.db);
  final Database db;

  static String _sourceKey(String key) =>
      key.toLowerCase() == 'htmanga' ? 'wnacg' : key;

  static int _type(int value, {required bool history}) => switch (value) {
    0 => 'picacg'.hashCode,
    1 => 'ehentai'.hashCode,
    2 => 'jm'.hashCode,
    3 => 'hitomi'.hashCode,
    4 => 'wnacg'.hashCode,
    _ => value == (history ? 5 : 6) ? 'nhentai'.hashCode : value,
  };

  List<String> favoriteFolders() => db
      .select("SELECT name FROM sqlite_master WHERE type='table';")
      .map((row) => row['name'] as String)
      .where((name) => name != 'folder_order' && name != 'folder_sync')
      .toList();

  Iterable<LegacyPicaFolderLink> folderLinks() sync* {
    for (final row in db.select('SELECT * FROM folder_sync;')) {
      yield LegacyPicaFolderLink(
        row['folder_name'],
        _sourceKey(row['key']),
        row['sync_data'],
      );
    }
  }

  Iterable<FavoriteItem> favorites(String folder) sync* {
    final table = '"${folder.replaceAll('"', '""')}"';
    for (final row in db.select('SELECT * FROM $table;')) {
      yield FavoriteItem(
        id: row['target'],
        name: row['name'],
        coverPath: row['cover_path'],
        author: row['author'],
        type: ComicType(_type(row['type'], history: false)),
        tags: (row['tags'] as String).split(','),
      );
    }
  }

  Iterable<History> history() sync* {
    for (final row in db.select('SELECT * FROM history;')) {
      final ep = row['ep'] as int;
      yield History(
        type: ComicType(_type(row['type'], history: true)),
        id: row['target'],
        maxPage: row['max_page'],
        ep: ep,
        page: row['page'],
        time: DateTime.fromMillisecondsSinceEpoch(row['time']),
        title: row['title'],
        subtitle: row['subtitle'],
        cover: row['cover'],
        readEpisode: {ep.toString()},
        readDurationMs: 0,
      );
    }
  }

  Iterable<LegacyPicaImage> images({
    required bool Function(String) sourceAvailable,
  }) sync* {
    for (final row in db.select('SELECT * FROM image_favorites;')) {
      final key = row['id'] as String;
      final separator = key.indexOf('-');
      final source = _sourceKey(
        separator < 0 ? key : key.substring(0, separator),
      );
      if (!sourceAvailable(source)) continue;
      if (separator < 0 || separator == key.length - 1) {
        throw FormatException('Invalid legacy image favorite identity: $key');
      }
      final ep = row['ep'] as int;
      yield LegacyPicaImage(
        key.substring(separator + 1),
        source,
        row['page'],
        ep == 0 ? 1 : ep,
        row['title'],
      );
    }
  }
}
