import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'binding.dart';
import 'document.dart';

class SubtitleRevision {
  const SubtitleRevision(this.acbf, this.manifest, this.choices, this.token);
  final Uint8List acbf;
  final Uint8List? manifest;
  final Map<String, SubtitleChoice> choices;
  final String? token;

  SubtitleDocument parse() => SubtitleDocument.parse(acbf, manifest: manifest);
}

class SubtitleStore {
  const SubtitleStore(this.path);
  final String path;

  T _withDatabase<T>(T Function(Database) action) {
    final database = sqlite3.open(path);
    try {
      database.execute(
        'CREATE TABLE IF NOT EXISTS subtitle_chapters ('
        'book TEXT NOT NULL, chapter TEXT NOT NULL, token TEXT NOT NULL, '
        'acbf BLOB NOT NULL, manifest BLOB, choices TEXT NOT NULL, PRIMARY KEY(book,chapter))',
      );
      return action(database);
    } finally {
      database.dispose();
    }
  }

  List<String> chapters(String book) => !File(path).existsSync()
      ? []
      : _withDatabase(
          (db) => [
            for (final row in db.select(
              'SELECT chapter FROM subtitle_chapters WHERE book=?',
              [book],
            ))
              row['chapter'] as String,
          ],
        );

  SubtitleRevision? read(String book, String chapter) {
    if (!File(path).existsSync()) return null;
    return _withDatabase((db) {
      final row = db.select(
        'SELECT * FROM subtitle_chapters WHERE book=? AND chapter=?',
        [book, chapter],
      ).firstOrNull;
      if (row == null) return null;
      final saved = jsonDecode(row['choices'] as String) as Map;
      return SubtitleRevision(
        row['acbf'] as Uint8List,
        row['manifest'] as Uint8List?,
        {
          for (final entry in saved.entries)
            entry.key as String: (
              path: entry.value[0] as String,
              digest: entry.value[1] as String,
            ),
        },
        row['token'] as String,
      );
    });
  }

  void replace(
    String book,
    String chapter,
    String? expected,
    SubtitleRevision? revision,
  ) {
    final choices = jsonEncode({
      for (final entry
          in (revision?.choices ?? <String, SubtitleChoice>{}).entries)
        entry.key: [entry.value.path, entry.value.digest],
    });
    _withDatabase((db) {
      db.execute('BEGIN IMMEDIATE');
      try {
        final current = db.select(
          'SELECT token FROM subtitle_chapters WHERE book=? AND chapter=?',
          [book, chapter],
        ).firstOrNull;
        if (current?['token'] != expected) {
          throw StateError('Subtitle revision changed. Reopen the chapter.');
        }
        if (revision == null) {
          db.execute(
            'DELETE FROM subtitle_chapters WHERE book=? AND chapter=?',
            [book, chapter],
          );
        } else {
          db.execute(
            'INSERT OR REPLACE INTO subtitle_chapters (book,chapter,token,acbf,manifest,choices) VALUES (?,?,?,?,?,?)',
            [
              book,
              chapter,
              const Uuid().v4(),
              revision.acbf,
              revision.manifest,
              choices,
            ],
          );
        }
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    });
  }
}
