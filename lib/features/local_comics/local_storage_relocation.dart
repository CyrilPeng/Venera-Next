import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/sqlite_transaction.dart';

import 'import_export/comic_copy_metadata.dart';
import 'import_export/comic_copy_record.dart';
import 'local_comic_model.dart';
import 'local_repository.dart';

/// Created only after copying succeeds. Directory references and the committed
/// root share one SQLite commit; local_path is then a recoverable mirror.
class LocalStorageRelocation {
  LocalStorageRelocation(this.db);
  final Database db;
  LocalRepository get _repository => LocalRepository(db);

  void initialize() => db.execute('''
    CREATE TABLE IF NOT EXISTS local_storage_relocation (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      version INTEGER NOT NULL,
      source TEXT NOT NULL,
      destination TEXT NOT NULL,
      references_json TEXT NOT NULL,
      cleanups_json TEXT NOT NULL,
      committed INTEGER NOT NULL DEFAULT 0
    );
  ''');

  LocalStorageRelocationState? get pending {
    final rows = db.select('SELECT * FROM local_storage_relocation');
    if (rows.isEmpty) return null;
    final row = rows.single;
    if (row['id'] != 1 ||
        row['version'] != 1 ||
        !const [0, 1].contains(row['committed'])) {
      throw const FormatException('Unknown local storage relocation');
    }
    final source = row['source'];
    final destination = row['destination'];
    final references = jsonDecode(row['references_json'] as String);
    final cleanups = jsonDecode(row['cleanups_json'] as String);
    return _validateState(
      source,
      destination,
      references,
      cleanups,
      committed: row['committed'] == 1,
    );
  }

  String snapshot() => jsonEncode(_repository.directoryBindings());

  Future<Map<String, String>> destinations(
    String source,
    String destination, {
    required Future<String> Function(String) resolvePath,
  }) async {
    final actualSource = await resolvePath(source);
    final targets = <String, String>{};
    for (final binding in _repository.directoryBindings()) {
      final stored = binding[2] as String;
      // Existing single names are already library-relative. Preserve the
      // historical meaning of separator-containing references, including SAF.
      if (!stored.contains('/') && !stored.contains('\\')) continue;
      String? relative;
      if (p.equals(source, stored) || p.isWithin(source, stored)) {
        relative = p.relative(stored, from: source);
      } else {
        final actual = await resolvePath(stored);
        if (p.equals(actualSource, actual) ||
            p.isWithin(actualSource, actual)) {
          relative = p.relative(actual, from: actualSource);
        }
      }
      if (relative != null) {
        targets[stored] = relative == '.'
            ? destination
            : p.join(destination, relative);
      }
    }
    return targets;
  }

  /// Keep the old root fully usable until the single directory/reference commit.
  /// Legacy relative names follow the root already. Only absolute references
  /// beneath this library change; unrelated external directories stay literal.
  void prepare(
    String source,
    String destination,
    String expectedSnapshot,
    Map<String, String> targets,
  ) {
    if (!db.autocommit) {
      throw StateError('Relocation requires its own transaction');
    }
    if (pending != null) {
      throw StateError('A library relocation is still pending');
    }
    final references = _repository.directoryBindings();
    if (jsonEncode(references) != expectedSnapshot) {
      throw StateError('Comic directories changed while copying the library');
    }
    final changes = <List<Object?>>[];
    final cleanups = <Map<String, Object?>>[];
    for (final binding in references) {
      final stored = binding[2] as String;
      final target = targets[stored];
      if (target == null) continue;
      changes.add([binding[0], binding[1], stored, target]);
      // Only a uniquely owned receipt can be retired using the old row's
      // identity after the directory update. Other recovery evidence is kept.
      if (references
              .where((other) => p.equals(other[2] as String, stored))
              .length !=
          1) {
        continue;
      }
      final receipt = File(p.join(target, ComicCopyRecord.registrationName));
      if (!receipt.existsSync()) continue;
      final original = _repository.find(
        binding[0] as String,
        ComicType(binding[1] as int),
      )!;
      final record = ComicCopyRecord.readForCleanup(Directory(target));
      final oldRegistration = comicCopyRegistration(original);
      if (!record.hasRegistration(oldRegistration)) continue;
      final intended = decodeComicCopyMetadata(record.metadata!, target).comic;
      if (!matchesComicCopyMetadata(intended, original)) {
        throw StateError('Copy receipt metadata changed before relocation');
      }
      final moved = LocalComic(
        id: original.id,
        title: original.title,
        subtitle: original.subtitle,
        tags: original.tags,
        directory: target,
        chapters: original.chapters,
        cover: original.cover,
        comicType: original.comicType,
        downloadedChapters: original.downloadedChapters,
        createdAt: original.createdAt,
      );
      cleanups.add({
        'id': original.id,
        'type': original.comicType.value,
        'directory': target,
        'intent': record.intentDigest,
        'before': oldRegistration,
        'after': comicCopyRegistration(moved),
      });
    }
    _validateState(source, destination, changes, cleanups, committed: false);
    runSqliteTransaction(db, () {
      if (snapshot() != expectedSnapshot) {
        throw StateError('Comic directories changed before relocation');
      }
      db.execute(
        'INSERT INTO local_storage_relocation (id, version, source, destination, references_json, cleanups_json) VALUES (1, 1, ?, ?, ?, ?)',
        [source, destination, jsonEncode(changes), jsonEncode(cleanups)],
      );
    }, immediate: true);
  }

  LocalStorageRelocationState commit(String expectedSnapshot) {
    if (!db.autocommit) {
      throw StateError('Relocation requires its own transaction');
    }
    final state = pending ?? (throw StateError('Missing library relocation'));
    if (state.committed) {
      throw StateError('Library relocation was already committed');
    }
    runSqliteTransaction(db, () {
      if (snapshot() != expectedSnapshot) {
        throw StateError('Comic directories changed before relocation commit');
      }
      for (final change in state.references) {
        _repository.replaceDirectory(
          change[0] as String,
          ComicType(change[1] as int),
          change[2] as String,
          change[3] as String,
        );
      }
      db.execute(
        'UPDATE local_storage_relocation SET committed = 1 WHERE id = 1',
      );
    }, immediate: true);
    return LocalStorageRelocationState(
      source: state.source,
      destination: state.destination,
      references: state.references,
      cleanups: state.cleanups,
      committed: true,
    );
  }

  Future<void> retireCopyReceipts(
    Future<void> Function(LocalComic) checkOwnership,
  ) async {
    final state = pending ?? (throw StateError('Missing library relocation'));
    if (!state.committed) {
      throw StateError('Library relocation is not committed');
    }
    for (final cleanup in state.cleanups) {
      final directory = cleanup['directory'] as String;
      if (!p.isWithin(state.destination, directory) &&
          !p.equals(state.destination, directory)) {
        throw StateError('Invalid relocated copy directory');
      }
      if (!ComicCopyRecord.exists(Directory(directory))) continue;
      LocalComic current() {
        final comic = _repository.find(
          cleanup['id'] as String,
          ComicType(cleanup['type'] as int),
        );
        if (comic == null || comicCopyRegistration(comic) != cleanup['after']) {
          throw StateError(
            'Relocated copy registration changed before cleanup',
          );
        }
        return comic;
      }

      final record = ComicCopyRecord.readForCleanup(Directory(directory));
      if (record.intentDigest != cleanup['intent']) {
        throw StateError('Relocated copy intent changed before cleanup');
      }
      await checkOwnership(current());
      current();
      record.removeAfterRegistration(cleanup['before'] as String);
    }
  }

  void forget() =>
      db.execute('DELETE FROM local_storage_relocation WHERE id = 1');
}

bool _validPath(Object? value) =>
    value is String && value.isNotEmpty && !value.contains('\u0000');

bool _absolutePath(Object? value) {
  if (!_validPath(value)) return false;
  final path = value as String;
  final uri = Uri.tryParse(path);
  return p.isAbsolute(path) ||
      (uri?.scheme == 'content' && uri!.host.isNotEmpty && uri.path.isNotEmpty);
}

LocalStorageRelocationState _validateState(
  Object? source,
  Object? destination,
  Object? references,
  Object? cleanups, {
  required bool committed,
}) {
  const invalid = FormatException('Invalid local storage relocation');
  if (!_absolutePath(source) ||
      !_absolutePath(destination) ||
      references is! List ||
      cleanups is! List) {
    throw invalid;
  }
  source = source as String;
  destination = destination as String;
  if (p.equals(source, destination) ||
      p.isWithin(source, destination) ||
      p.isWithin(destination, source)) {
    throw invalid;
  }
  final changes = <List<Object?>>[];
  final byIdentity = <(String, int), List<Object?>>{};
  for (final value in references) {
    if (value is! List ||
        value.length != 4 ||
        value[0] is! String ||
        (value[0] as String).isEmpty ||
        value[1] is! int ||
        !_validPath(value[2]) ||
        !_absolutePath(value[3])) {
      throw invalid;
    }
    final change = List<Object?>.from(value);
    final target = change[3] as String;
    if (change[2] == target ||
        (!p.equals(destination, target) && !p.isWithin(destination, target))) {
      throw invalid;
    }
    final key = (change[0] as String, change[1] as int);
    if (byIdentity.containsKey(key)) throw invalid;
    byIdentity[key] = change;
    changes.add(List.unmodifiable(change));
  }
  final receipts = <Map<String, dynamic>>[];
  final seen = <(String, int)>{};
  for (final value in cleanups) {
    if (value is! Map<String, dynamic> ||
        value['id'] is! String ||
        value['type'] is! int ||
        value['directory'] is! String ||
        value['intent'] is! String ||
        value['before'] is! String ||
        value['after'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['intent'] as String)) {
      throw invalid;
    }
    final key = (value['id'] as String, value['type'] as int);
    final change = byIdentity[key];
    if (change == null || change[3] != value['directory'] || !seen.add(key)) {
      throw invalid;
    }
    final before = jsonDecode(value['before'] as String);
    final after = jsonDecode(value['after'] as String);
    if (before is! Map<String, dynamic> ||
        after is! Map<String, dynamic> ||
        before['id'] != key.$1 ||
        after['id'] != key.$1 ||
        before['directory'] != change[2] ||
        after['directory'] != change[3] ||
        before['metadata'] is! String ||
        before['metadata'] != after['metadata']) {
      throw invalid;
    }
    final metadata = jsonDecode(before['metadata'] as String);
    if (metadata is! Map<String, dynamic> || metadata['type'] != key.$2) {
      throw invalid;
    }
    receipts.add(Map.unmodifiable(value));
  }
  return LocalStorageRelocationState(
    source: source,
    destination: destination,
    references: List.unmodifiable(changes),
    cleanups: List.unmodifiable(receipts),
    committed: committed,
  );
}

class LocalStorageRelocationState {
  const LocalStorageRelocationState({
    required this.source,
    required this.destination,
    required this.references,
    required this.cleanups,
    required this.committed,
  });
  final String source;
  final String destination;
  final List<List<Object?>> references;
  final List<Map<String, dynamic>> cleanups;
  final bool committed;
}
