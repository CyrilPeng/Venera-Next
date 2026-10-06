import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app_data_sync_fields.dart';

/// Hash logical SQLite rows, stable JSON and the files included by application
/// export. SQLite headers, WAL layout and ZIP metadata are not business changes.
/// The application caller must hold its existing exclusive data admission.
abstract final class DataSyncContentFingerprint {
  static String capture(
    String root, {
    required String excludedFields,
    String? memorySettingsJson,
    bool? archiveSyncEnabled,
    bool importGuard = false,
  }) {
    final parts = <String, Object?>{'version': 1};
    final metadata = File(p.join(root, 'appdata.json'));
    final disk = metadata.existsSync()
        ? settings(
            metadata.readAsStringSync(),
            excludedFields,
            archiveSyncEnabled: archiveSyncEnabled,
            importGuard: importGuard,
          )
        : null;
    parts['settings'] = disk;
    if (memorySettingsJson != null) {
      final memory = settings(
        memorySettingsJson,
        excludedFields,
        archiveSyncEnabled: archiveSyncEnabled,
        importGuard: importGuard,
      );
      // An unpersisted draft is also dirty; do not overwrite it just because
      // its previously saved disk image still matches the acknowledged one.
      if (memory != disk) parts['unpersistedSettings'] = memory;
    }
    for (final name in ['history.db', 'local_favorite.db', 'cookie.db']) {
      parts[name] = _database(p.join(root, name));
    }
    final sources = Directory(p.join(root, 'comic_source'));
    parts['sources'] = <String, String>{
      if (sources.existsSync())
        for (final file in sources.listSync().whereType<File>())
          p.basename(file.path): sha256
              .convert(file.readAsBytesSync())
              .toString(),
    };
    return _hash(parts);
  }

  static String settings(
    String contents,
    String excludedFields, {
    bool? archiveSyncEnabled,
    bool importGuard = false,
  }) {
    final document = jsonDecode(contents);
    if (document is! Map<String, dynamic> ||
        document['settings'] is! Map<String, dynamic>) {
      throw const FormatException(
        'Invalid settings content for sync comparison',
      );
    }
    final values = document['settings'] as Map<String, dynamic>;
    final archiveEnabled =
        archiveSyncEnabled ?? values['backupWebdavSyncEnabled'] == true;
    final excluded = {...appDataLocalFields, 'dataVersion'};
    if (archiveEnabled) excluded.removeAll(appDataOptionalArchiveFields);
    excluded.addAll(splitAppDataFields(excludedFields));
    // Export always omits custom exclusions. Legacy import instead gives the
    // archive toggle priority for these two fields, so its conflict guard must
    // still protect local edits to fields that incoming data can overwrite.
    if (importGuard && archiveEnabled) {
      excluded.removeAll(appDataOptionalArchiveFields);
    }
    for (final field in excluded) {
      values.remove(field);
    }
    return _hash(document);
  }

  static String? _database(String path) {
    if (!File(path).existsSync()) return null;
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      db.execute('PRAGMA busy_timeout = 5000; BEGIN;');
      final tables = db.select(
        "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT GLOB 'sqlite_*' ORDER BY name",
      );
      final contents = <Object?>[];
      for (final table in tables) {
        final name = table['name'] as String;
        final quoted = '"${name.replaceAll('"', '""')}"';
        final columns = db
            .select('PRAGMA table_info($quoted)')
            .map((row) => row['name'] as String)
            .toList();
        final sql = table['sql'] as String? ?? '';
        final rowId = ['rowid', '_rowid_', 'oid']
            .where(
              (name) => !columns.any((column) => column.toLowerCase() == name),
            )
            .firstOrNull;
        final hasRowId =
            !RegExp(
              r'\bWITHOUT\s+ROWID\b',
              caseSensitive: false,
            ).hasMatch(sql) &&
            rowId != null;
        final statement = db.prepare(
          'SELECT ${hasRowId ? '$rowId, ' : ''}* FROM $quoted',
        );
        final hashes = <String>[];
        try {
          final cursor = statement.selectCursor();
          while (cursor.moveNext()) {
            final row = cursor.current;
            hashes.add(
              _hash([
                for (final value in row.values)
                  if (value is Uint8List)
                    ['blob', base64Encode(value)]
                  else
                    ['value', value],
              ]),
            );
          }
        } finally {
          statement.dispose();
        }
        hashes.sort();
        contents.add([name, sql, columns, hasRowId, hashes]);
      }
      return _hash(contents);
    } finally {
      db.dispose();
    }
  }

  static Object? canonical(Object? value) {
    if (value is Map) {
      if (value.keys.any((key) => key is! String)) {
        throw const FormatException('Sync content object keys must be strings');
      }
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: canonical(value[key])};
    }
    if (value is List) return value.map(canonical).toList();
    return value;
  }

  static String _hash(Object? value) =>
      sha256.convert(utf8.encode(jsonEncode(canonical(value)))).toString();
}
