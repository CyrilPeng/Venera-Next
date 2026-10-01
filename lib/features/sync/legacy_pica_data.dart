import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites_api.dart';
import 'package:venera_next/features/history/history_api.dart';
import 'legacy_pica_reader.dart';

/// Fully decoded source records. Construct before changing any destination data.
class LegacyPicaData {
  LegacyPicaData._(this.folders, this.links, this.history, this.images);

  final Map<String, List<FavoriteItem>> folders;
  final List<LegacyPicaFolderLink> links;
  final List<History> history;
  final List<LegacyPicaImage> images;

  static LegacyPicaData read(
    String directory, {
    required bool Function(String) sourceAvailable,
  }) {
    final folders = <String, List<FavoriteItem>>{};
    var links = <LegacyPicaFolderLink>[];
    var history = <History>[];
    var images = <LegacyPicaImage>[];
    void readDatabase(String name, void Function(LegacyPicaReader) read) {
      final file = File(p.join(directory, name));
      if (!file.existsSync()) return;
      final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
      try {
        read(LegacyPicaReader(db));
      } finally {
        db.dispose();
      }
    }

    readDatabase('local_favorite.db', (reader) {
      links = reader.folderLinks().toList();
      for (final folder in reader.favoriteFolders()) {
        folders[folder] = reader.favorites(folder).toList();
      }
    });
    readDatabase('history.db', (reader) {
      history = reader.history().toList();
      images = reader.images(sourceAvailable: sourceAvailable).toList();
    });
    return LegacyPicaData._(folders, links, history, images);
  }
}
