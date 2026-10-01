import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:venera_next/foundation/sqlite_snapshot.dart';

/// Stages stable files for compression. Each DB is internally consistent;
/// this is not a transaction across independent databases and settings.
Future<List<String>> createAppDataSnapshot(
  String dataPath,
  String destinationPath, {
  required String settingsJson,
}) async {
  final entries = <String>[];
  for (final name in ['history.db', 'local_favorite.db', 'cookie.db']) {
    await createSqliteSnapshot(
      p.join(dataPath, name),
      p.join(destinationPath, name),
    );
    entries.add(name);
  }
  File(p.join(destinationPath, 'appdata.json')).writeAsStringSync(settingsJson);
  entries.add('appdata.json');
  final sourceDirectory = Directory(p.join(dataPath, 'comic_source'));
  for (final file in sourceDirectory.listSync()) {
    if (file is! File) continue;
    final name = 'comic_source/${p.basename(file.path)}';
    final destination = File(p.join(destinationPath, name));
    destination.parent.createSync(recursive: true);
    file.copySync(destination.path);
    entries.add(name);
  }
  return entries;
}
