import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';

void addSqliteInternalTables(Database db) {
  // SQLite creates these tables itself; dropping the scratch table retains
  // sqlite_sequence, and ANALYZE also creates sqlite_stat4 when supported.
  db.execute('ANALYZE;');
  db.execute(
    'CREATE TABLE sequence_fixture (id INTEGER PRIMARY KEY AUTOINCREMENT);',
  );
  db.execute('INSERT INTO sequence_fixture DEFAULT VALUES;');
  db.execute('DROP TABLE sequence_fixture;');
}

Map<String, Object?> sqliteInternalTableSnapshot(
  Database db, {
  Set<String> excludeStatisticsFor = const {},
}) => {
  for (final row in db.select(
    "SELECT name, sql FROM sqlite_master WHERE type = 'table' "
    "AND name GLOB 'sqlite_*' ORDER BY name;",
  ))
    row['name'] as String: {
      'schema': row['sql'],
      'rows': db
          .select('SELECT * FROM "${row['name']}";')
          .where(
            (entry) =>
                !const {'sqlite_stat1', 'sqlite_stat4'}.contains(row['name']) ||
                !excludeStatisticsFor.contains(entry['tbl']),
          )
          .map((entry) => Map<String, Object?>.from(entry))
          .toList(),
    },
};

void seedAnalyzedLegacyFavorites(Database db) {
  final repository = FavoritesRepository(db)..initializeMetadata();
  db.execute('''CREATE TABLE legacy (
    id TEXT, name TEXT, author TEXT, type INT, tags TEXT, cover_path TEXT,
    time TEXT, display_order INT, PRIMARY KEY (id, type)
  );''');
  db.execute('''INSERT INTO legacy VALUES (
    'legacy-id', 'Legacy favorite', 'Artist', 0, 'tag,second', 'legacy.jpg',
    '2001-02-03 04:05:06', 7
  );''');
  repository.createFolder('sqliteXnotes');
  db.execute('''INSERT INTO sqliteXnotes VALUES (
    'modern-id', 'Modern favorite', 'Artist', 0, 'tag', 'modern.jpg',
    '2002-03-04 05:06:07', -3, 'preserved translation'
  );''');
  repository.prepareForFollowUpdates('sqliteXnotes', clearData: false);
  db.execute('''UPDATE sqliteXnotes SET last_update_time = 'chapter 2',
    has_new_update = 1, last_check_time = 123;''');
  db.execute(
    "INSERT INTO folder_order VALUES ('legacy', 10), ('sqliteXnotes', -5);",
  );
  repository.linkFolderToNetwork('legacy', 'fixture-source', 'remote-folder');
  addSqliteInternalTables(db);
}
