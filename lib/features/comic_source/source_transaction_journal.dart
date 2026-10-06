import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import 'package:venera_next/foundation/sqlite_connection.dart';

import 'source_data_journal.dart';
import 'source_mutation_failure.dart';

typedef SourceTransactionObserver = FutureOr<void> Function(String phase);

/// One source mutation owns script, configuration and data intents. Settings
/// intents are recorded synchronously at the settings queue head; data intents
/// precede each actual staged write. Recovery runs before application stores open.
class SourceTransactionJournal {
  SourceTransactionJournal._(this.root, this._db, this._lock, this._observer);

  static const directoryName = '.source-transactions';
  static final _held = <String>{};
  static final _ids = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static final _keys = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$');
  static const _fields = {
    'explore_pages',
    'categories',
    'favorites',
    'searchSources',
  };

  final String root;
  final Database _db;
  final RandomAccessFile _lock;
  final SourceTransactionObserver? _observer;
  Map<String, dynamic>? _intent;
  bool _closed = false;
  bool _finished = false;

  Directory get directory =>
      Directory(p.join(root, directoryName, _intent!['id'] as String));
  String get recoveryPath => p.join(root, directoryName);

  static Future<SourceTransactionJournal?> _open(
    String dataPath, {
    required bool create,
    SourceTransactionObserver? observer,
  }) async {
    final data = Directory(p.normalize(p.absolute(dataPath)));
    if (!data.existsSync() && !create) return null;
    if (create) data.createSync(recursive: true);
    final root = p.normalize(data.resolveSymbolicLinksSync());
    final directory = Directory(p.join(root, directoryName));
    SourceDataJournal.checkPath(
      root,
      directory.path,
      FileSystemEntityType.directory,
    );
    if (!directory.existsSync() && !create) return null;
    directory.createSync();
    final lockFile = File(p.join(directory.path, 'owner.lock'));
    SourceDataJournal.checkPath(root, lockFile.path, FileSystemEntityType.file);
    if (!_held.add(lockFile.path)) {
      throw StateError('Source transaction still has a live owner');
    }
    RandomAccessFile? lock;
    Database? db;
    try {
      lock = await lockFile.open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      if (await lock.length() != 0) {
        throw FileSystemException(
          'Source transaction lock contains unknown data',
          lockFile.path,
        );
      }
      final database = p.join(directory.path, 'transactions.sqlite');
      for (final suffix in ['', '-journal', '-wal', '-shm']) {
        SourceDataJournal.checkPath(
          root,
          database + suffix,
          FileSystemEntityType.file,
        );
      }
      db = openSqliteDatabase(database);
      db.execute('PRAGMA synchronous = FULL; PRAGMA secure_delete = ON;');
      final version = db.select('PRAGMA user_version;').single.values.first;
      if (version != 0 && version != 1) {
        throw const FormatException('Unsupported source transaction journal');
      }
      db.execute('''
        CREATE TABLE IF NOT EXISTS mutations (
          id TEXT PRIMARY KEY, payload TEXT NOT NULL, digest TEXT NOT NULL
        );
        PRAGMA user_version = 1;
      ''');
      return SourceTransactionJournal._(root, db, lock, observer);
    } catch (error, stack) {
      final failures = <SourceMutationError>[
        (stage: 'open source transaction', error: error, stack: stack),
      ];
      try {
        db?.dispose();
      } catch (error, stack) {
        failures.add((
          stage: 'close source transaction database',
          error: error,
          stack: stack,
        ));
      }
      try {
        await lock?.close();
      } catch (error, stack) {
        failures.add((
          stage: 'close source transaction lock',
          error: error,
          stack: stack,
        ));
      } finally {
        _held.remove(lockFile.path);
      }
      if (failures.length == 1) Error.throwWithStackTrace(error, stack);
      throw SourceMutationFailure(
        state: SourceMutationState.recoveryRequired,
        failures: failures,
        recoveryPath: directory.path,
      );
    }
  }

  static Future<SourceTransactionJournal> begin({
    required String dataPath,
    required File script,
    required List<int>? before,
    required List<int>? after,
    SourceTransactionObserver? observer,
  }) async {
    final journal = (await _open(dataPath, create: true, observer: observer))!;
    try {
      for (final row in journal._db.select(
        'SELECT * FROM mutations ORDER BY rowid',
      )) {
        journal._load(
          row['id'] as String,
          row['payload'] as String,
          row['digest'] as String,
        );
        if (journal._intent!['phase'] != 'committed') {
          throw StateError('An earlier source transaction requires recovery');
        }
        await journal.recoverCurrent();
      }
      final absoluteScript = p.normalize(script.absolute.path);
      final relative = p.relative(
        absoluteScript,
        from: p.isWithin(journal.root, absoluteScript)
            ? journal.root
            : p.normalize(p.absolute(dataPath)),
      );
      journal._checkTarget(relative, 'script');
      if (!_sameBytes(journal._read(relative), before)) {
        throw FileSystemException(
          'Source script changed before transaction preparation',
          script.path,
        );
      }
      final id = const Uuid().v4();
      final ownedDirectory = Directory(p.join(journal.root, directoryName, id));
      SourceDataJournal.checkPath(
        journal.root,
        ownedDirectory.path,
        FileSystemEntityType.directory,
      );
      if (ownedDirectory.existsSync()) {
        throw FileSystemException(
          'Source transaction directory already exists',
          ownedDirectory.path,
        );
      }
      final manifest = utf8.encode(
        jsonEncode({
          'version': 2,
          'id': id,
          'root': journal.root,
          'script': relative,
          'before': _hash(before),
          'after': _hash(after),
        }),
      );
      journal._finished = false;
      journal._intent = {
        'version': 1,
        'id': id,
        'root': journal.root,
        'phase': 'preparing',
        'key': null,
        'entries': <Map<String, dynamic>>[
          {
            'path': relative,
            'kind': 'script',
            'before': _encode(before),
            'after': [_encode(after)],
          },
        ],
        'owned': <String, dynamic>{
          if (before != null) 'original.js': _encode(before),
          'manifest.json': _encode(manifest),
        },
      };
      journal._save();
      await journal._event('recorded');
      SourceDataJournal.checkPath(
        journal.root,
        journal.directory.path,
        FileSystemEntityType.directory,
      );
      if (journal.directory.existsSync()) {
        throw FileSystemException(
          'Source transaction directory already exists',
          journal.directory.path,
        );
      }
      await journal.directory.create();
      for (final entry in journal._owned.entries) {
        await File(
          p.join(journal.directory.path, entry.key),
        ).writeAsBytes(_decode(entry.value)!, flush: true);
      }
      await journal._event('prepared');
      return journal;
    } catch (error, stack) {
      try {
        await journal.close();
      } catch (close, closeStack) {
        throw SourceMutationFailure(
          state: SourceMutationState.recoveryRequired,
          recoveryPath: journal.recoveryPath,
          failures: [
            (stage: 'prepare source transaction', error: error, stack: stack),
            (
              stage: 'release failed transaction',
              error: close,
              stack: closeStack,
            ),
          ],
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  List<Map<String, dynamic>> get _entries =>
      (_intent!['entries'] as List).cast<Map<String, dynamic>>();
  Map<String, dynamic> get _owned => _intent!['owned'] as Map<String, dynamic>;

  void _save() {
    _checkActive();
    final payload = jsonEncode(_intent);
    _db.execute('INSERT OR REPLACE INTO mutations VALUES (?, ?, ?)', [
      _intent!['id'],
      payload,
      sha256.convert(utf8.encode(payload)).toString(),
    ]);
  }

  void _checkActive() {
    if (_closed || _finished) {
      throw StateError('Source transaction is closed or resolved');
    }
  }

  void bindKey(String key) {
    if (!['preparing', 'applying'].contains(_intent!['phase'])) {
      throw StateError('Source transaction identity is sealed');
    }
    if (!_keys.hasMatch(key) ||
        (_intent!['key'] != null && _intent!['key'] != key)) {
      throw StateError('Source transaction identity changed');
    }
    _intent!['key'] = key;
    _save();
  }

  /// Called before appdata publishes its settings draft or starts file writes.
  /// Delta contains only the fields changed by this source and its origin key.
  void recordSettings(
    Map<String, String> contents,
    Map<String, dynamic> delta,
  ) {
    if (_intent!['phase'] != 'preparing') {
      throw StateError('Source settings already committed');
    }
    _checkDelta(delta);
    final entries = _entries;
    for (final entry in contents.entries) {
      if (!['appdata.json', 'syncdata.json'].contains(entry.key)) {
        throw ArgumentError('Unexpected source settings file');
      }
      final primary = _read(entry.key);
      final after = utf8.encode(entry.value);
      final afterSettings = (jsonDecode(entry.value) as Map)['settings'] as Map;
      final fileDelta = {
        'fields': {
          for (final field in (delta['fields'] as Map).entries)
            if (afterSettings.containsKey(field.key)) field.key: field.value,
        },
        'origin': afterSettings.containsKey('comicSourceOrigins')
            ? delta['origin']
            : null,
      };
      final paths = {
        entry.key: ('settings', after),
        '${entry.key}.bak': ('backup', primary),
        '${entry.key}.tmp': ('temporary', after),
      };
      for (final planned in paths.entries) {
        if (entries.any((e) => e['path'] == planned.key)) {
          throw StateError('Source settings intent was recorded twice');
        }
        final before = _read(planned.key);
        final backup = planned.value.$1 == 'backup';
        final expected = backup ? (primary ?? before) : planned.value.$2;
        entries.add({
          'path': planned.key,
          'kind': planned.value.$1,
          'before': _encode(before),
          // Live rollback may copy the newly published primary into .bak,
          // including when the initial primary did not exist. The last value
          // is the initial forward outcome; earlier values authorize rollback.
          'after': [if (backup) _encode(after), _encode(expected)],
          'delta': jsonDecode(
            jsonEncode(_diskDelta(before, expected, fileDelta)),
          ),
        });
      }
    }
    _intent!['entries'] = entries;
    _save();
  }

  // Defaults in memory and omitted fields in syncdata are not disk snapshots.
  // Recover each file's actual field presence, including its older backup.
  static Map<String, dynamic> _diskDelta(
    List<int>? before,
    List<int>? after,
    Map<String, dynamic> delta,
  ) {
    Map<String, dynamic>? settings(List<int>? bytes) {
      if (bytes == null) return {};
      try {
        return (jsonDecode(utf8.decode(bytes)) as Map)['settings']
            as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }

    final old = settings(before);
    final next = settings(after);
    if (old == null || next == null) {
      return {...delta, 'exactOnly': true};
    }
    Map<String, dynamic> change(String field) => {
      'before': old[field],
      'after': next[field],
      'beforePresent': old.containsKey(field),
      'afterPresent': next.containsKey(field),
    };
    return {
      'fields': <String, dynamic>{
        for (final field in (delta['fields'] as Map).keys)
          field: {
            ...change(field as String),
            'known': [
              (delta['fields'] as Map)[field]['before'],
              (delta['fields'] as Map)[field]['after'],
            ],
          },
      },
      'origin': delta['origin'] == null
          ? null
          : {
              ...change('comicSourceOrigins'),
              'key': (delta['origin'] as Map)['key'],
              'known': [
                (delta['origin'] as Map)['before'],
                (delta['origin'] as Map)['after'],
              ],
            },
    };
  }

  /// An applying intent can complete forward after a process interruption.
  /// The live owner may explicitly abort before any data write was applied.
  void recordData(String path, String key, String contents) {
    if (!p.equals(Directory(path).resolveSymbolicLinksSync(), root)) {
      throw StateError('Source transaction data directory changed');
    }
    bindKey(key);
    if (!['preparing', 'applying'].contains(_intent!['phase'])) {
      throw StateError('Source transaction no longer accepts data');
    }
    final relative = p.join('comic_source', '$key.data');
    final entries = _entries;
    final existing = entries
        .where((entry) => entry['path'] == relative)
        .firstOrNull;
    if (existing == null) {
      entries.add({
        'path': relative,
        'kind': 'data',
        'before': _encode(_read(relative)),
        'after': [_encode(utf8.encode(contents))],
      });
    } else {
      (existing['after'] as List).add(_encode(utf8.encode(contents)));
    }
    _intent!['entries'] = entries;
    _intent!['phase'] = 'applying';
    _save();
  }

  void decideRollback() {
    if (_intent!['phase'] == 'committed') {
      throw StateError('Committed source cannot roll back');
    }
    _intent!['phase'] = 'rollback';
    _save();
  }

  void commit() {
    if (_intent!['phase'] == 'rollback') {
      throw StateError('Aborted source cannot commit');
    }
    _intent!['phase'] = 'committed';
    _save();
  }

  Future<void> _event(String phase) async => _observer?.call(phase);

  void _load(String id, String payload, String digest) {
    if (digest != sha256.convert(utf8.encode(payload)).toString()) {
      throw const FormatException('Source transaction digest mismatch');
    }
    _intent = jsonDecode(payload) as Map<String, dynamic>;
    _finished = false;
    _validate(id);
  }

  Future<void> verifyScript({required bool expected}) async {
    final entry = _entries.singleWhere((e) => e['kind'] == 'script');
    final desired = expected
        ? (entry['after'] as List).single
        : entry['before'];
    if (!_sameBytes(_read(entry['path'] as String), _decode(desired))) {
      throw FileSystemException(
        'Source script changed during transaction',
        entry['path'] as String,
      );
    }
  }

  Future<void> writeScript() async {
    _checkActive();
    if (_intent!['phase'] != 'preparing') {
      throw StateError('Source script is already sealed');
    }
    await _recoverEntry(
      _entries.singleWhere((e) => e['kind'] == 'script'),
      forward: true,
    );
  }

  Future<void> restoreScript() async {
    decideRollback();
    await _recoverEntry(
      _entries.singleWhere((e) => e['kind'] == 'script'),
      forward: false,
    );
  }

  /// Transfers may clean already committed evidence, but cannot restore disk
  /// under initialized settings/sources and leave their in-memory values stale.
  static Future<void> checkReadyForTransfer(String dataPath) async {
    final journal = await _open(dataPath, create: false);
    if (journal == null) return;
    try {
      for (final row in journal._db.select(
        'SELECT * FROM mutations ORDER BY rowid',
      )) {
        journal._load(
          row['id'] as String,
          row['payload'] as String,
          row['digest'] as String,
        );
        if (journal._intent!['phase'] != 'committed') {
          throw StateError(
            'Recover source transactions before transferring application data',
          );
        }
        await journal.recoverCurrent();
      }
    } finally {
      await journal.close();
    }
  }

  static Future<void> recover(
    String dataPath, {
    SourceTransactionObserver? observer,
  }) async {
    final journal = await _open(dataPath, create: false, observer: observer);
    if (journal == null) return;
    final failures = <SourceMutationError>[];
    try {
      for (final row in journal._db.select(
        'SELECT * FROM mutations ORDER BY rowid',
      )) {
        try {
          journal._load(
            row['id'] as String,
            row['payload'] as String,
            row['digest'] as String,
          );
          await journal.recoverCurrent();
        } catch (error, stack) {
          failures.add((
            stage: 'recover source transaction ${row['id']}',
            error: error,
            stack: stack,
          ));
        }
      }
    } finally {
      try {
        await journal.close();
      } catch (error, stack) {
        failures.add((
          stage: 'release source transaction recovery',
          error: error,
          stack: stack,
        ));
      }
    }
    if (failures.isNotEmpty) {
      throw SourceMutationFailure(
        state: SourceMutationState.recoveryRequired,
        recoveryPath: journal.recoveryPath,
        failures: failures,
      );
    }
  }

  /// Live callers must also own the settings persistence queue. This method
  /// never calls application writers or changes an already committed decision.
  Future<void> recoverCurrent() async {
    _checkActive();
    _validate(_intent!['id']);
    await _validateOwned();
    if (_intent!['phase'] != 'committed') {
      final forward = _intent!['phase'] == 'applying';
      final failures = <SourceMutationError>[];
      for (final entry in forward ? _entries : _entries.reversed) {
        try {
          await _recoverEntry(entry, forward: forward);
          await _event('restored:${entry['path']}');
        } catch (error, stack) {
          failures.add((
            stage: 'restore ${entry['path']}',
            error: error,
            stack: stack,
          ));
        }
      }
      if (failures.isNotEmpty) {
        throw SourceMutationFailure(
          state: SourceMutationState.recoveryRequired,
          recoveryPath: directory.path,
          failures: failures,
        );
      }
      // Recovery can itself be interrupted. Seal the resolved outcome before
      // deleting its evidence; later recovery must only continue cleanup.
      _intent!['phase'] = 'committed';
      _save();
      await _event('resolved');
    }
    await cleanup();
  }

  Future<void> _recoverEntry(
    Map<String, dynamic> entry, {
    required bool forward,
  }) async {
    final relative = entry['path'] as String;
    final kind = entry['kind'] as String;
    final before = _decode(entry['before']);
    final afters = (entry['after'] as List).map(_decode).toList();
    final current = _read(relative);
    final desired = forward && kind != 'temporary' ? afters.last : before;
    if (_sameBytes(current, desired)) return;
    if (kind == 'script' || kind == 'data') {
      if (!_sameBytes(current, before) &&
          !afters.any((value) => _sameBytes(current, value))) {
        throw FileSystemException(
          'Source transaction preserves later file contents',
          p.join(root, relative),
        );
      }
      await _replace(relative, desired, expected: current);
      return;
    }
    if (kind == 'temporary') {
      if (current != null && !afters.any((value) => _prefix(current, value))) {
        throw FileSystemException(
          'Source settings staging contains unknown contents',
          relative,
        );
      }
      await _replace(relative, before, expected: current);
      return;
    }
    if (!forward && afters.any((value) => _sameBytes(current, value))) {
      await _replace(relative, before, expected: current);
      return;
    }
    if (current == null || (forward && _sameBytes(current, before))) {
      await _replace(relative, desired, expected: current);
      return;
    }
    if (kind == 'backup' && afters.any((value) => _prefix(current, value))) {
      await _replace(relative, desired, expected: current);
      return;
    }
    if ((entry['delta'] as Map)['exactOnly'] == true) {
      throw FileSystemException(
        'Source transaction cannot merge invalid prior settings',
        relative,
      );
    }
    Map<String, dynamic> document;
    try {
      document = jsonDecode(utf8.decode(current)) as Map<String, dynamic>;
      if (document['settings'] is! Map) {
        throw const FormatException('Missing settings');
      }
    } catch (_) {
      if (kind == 'backup' && afters.any((value) => _prefix(current, value))) {
        await _replace(relative, desired, expected: current);
        return;
      }
      throw FileSystemException(
        'Source transaction preserves unknown settings contents',
        relative,
      );
    }
    final original = jsonEncode(document);
    final conflicts = applySettingsDelta(
      document['settings'] as Map<String, dynamic>,
      entry['delta'] as Map<String, dynamic>,
      forward: forward,
    );
    if (jsonEncode(document) != original) {
      await _replace(
        relative,
        utf8.encode(jsonEncode(document)),
        expected: current,
      );
    }
    if (conflicts.isNotEmpty) {
      throw StateError(
        'Source transaction preserves newer settings: ${conflicts.join(', ')}',
      );
    }
  }

  /// Preserve unrelated fields and unrelated source origins. Exact before/after
  /// values are the only authority to modify a field during recovery.
  static List<String> applySettingsDelta(
    Map<String, dynamic> settings,
    Map<String, dynamic> delta, {
    required bool forward,
  }) {
    final conflicts = <String>[];
    final from = forward ? 'before' : 'after';
    final to = forward ? 'after' : 'before';
    bool matches(String field, Map change, String side) =>
        settings.containsKey(field) == (change['${side}Present'] ?? true) &&
        _sameJson(settings[field], change[side]);
    void assign(String field, Map change) {
      if (change['${to}Present'] == false) {
        settings.remove(field);
      } else {
        settings[field] = _copy(change[to]);
      }
    }

    for (final entry in (delta['fields'] as Map<String, dynamic>).entries) {
      final change = entry.value as Map;
      if (matches(entry.key, change, to)) continue;
      // A live rollback persists the former in-memory default and also copies
      // the published source settings to .bak. Both values were registered
      // before the initial publication, even if absent from older disk files.
      if (matches(entry.key, change, from) ||
          (!forward &&
              settings.containsKey(entry.key) &&
              (change['known'] as List? ?? const []).any(
                (value) => _sameJson(settings[entry.key], value),
              ))) {
        assign(entry.key, change);
      } else {
        conflicts.add(entry.key);
      }
    }
    final origin = delta['origin'] as Map?;
    if (origin != null) {
      final current = settings['comicSourceOrigins'];
      if (matches('comicSourceOrigins', origin, from)) {
        assign('comicSourceOrigins', origin);
      } else if (!matches('comicSourceOrigins', origin, to)) {
        if (current != null && current is! Map) {
          conflicts.add('comicSourceOrigins');
          return conflicts;
        }
        final previous = origin[from] is Map ? origin[from] as Map : const {};
        final desired = origin[to] is Map ? origin[to] as Map : const {};
        final values = current is Map
            ? Map<String, dynamic>.from(current)
            : <String, dynamic>{};
        final key = origin['key'] as String;
        bool matches(Map value) =>
            values.containsKey(key) == value.containsKey(key) &&
            _sameJson(values[key], value[key]);
        if (matches(previous) ||
            (!forward &&
                (origin['known'] as List? ?? const []).any(
                  (value) => matches(value is Map ? value : const {}),
                ))) {
          if (desired.containsKey(key)) {
            values[key] = _copy(desired[key]);
          } else {
            values.remove(key);
          }
          if (values.isEmpty && desired.isEmpty) {
            assign('comicSourceOrigins', origin);
          } else {
            settings['comicSourceOrigins'] = values;
          }
        } else if (!matches(desired)) {
          conflicts.add('comicSourceOrigins/$key');
        }
      }
    }
    return conflicts;
  }

  Future<void> _replace(
    String relative,
    List<int>? contents, {
    required List<int>? expected,
  }) async {
    final target = File(p.join(root, relative));
    _checkTarget(
      relative,
      _entries.singleWhere((e) => e['path'] == relative)['kind'] as String,
    );
    if (contents == null) {
      if (target.existsSync()) await target.delete();
      return;
    }
    final name = 'work-${const Uuid().v4()}';
    _owned[name] = _encode(contents);
    _save();
    SourceDataJournal.checkPath(
      root,
      directory.path,
      FileSystemEntityType.directory,
    );
    await directory.create();
    final temporary = File(p.join(directory.path, name));
    SourceDataJournal.checkPath(
      root,
      temporary.path,
      FileSystemEntityType.file,
    );
    if (temporary.existsSync()) {
      throw FileSystemException(
        'Source recovery staging already exists',
        temporary.path,
      );
    }
    await temporary.writeAsBytes(contents, flush: true);
    await _event('recovery-written:$relative');
    await target.parent.create(recursive: true);
    _checkActive();
    _checkTarget(
      relative,
      _entries.singleWhere((e) => e['path'] == relative)['kind'] as String,
    );
    if (!_sameBytes(_read(relative), expected)) {
      throw FileSystemException(
        'Source recovery target changed before replacement',
        target.path,
      );
    }
    await temporary.rename(target.path);
  }

  Future<void> _validateOwned() async {
    SourceDataJournal.checkPath(
      root,
      directory.path,
      FileSystemEntityType.directory,
    );
    for (final entry in _owned.entries) {
      final file = File(p.join(directory.path, entry.key));
      SourceDataJournal.checkPath(root, file.path, FileSystemEntityType.file);
      if (file.existsSync() &&
          !_prefix(await file.readAsBytes(), _decode(entry.value))) {
        throw FileSystemException(
          'Source transaction staging was changed',
          file.path,
        );
      }
    }
  }

  /// Only call after a committed decision, or after recoverCurrent resolved all
  /// rollback/forward effects. Unknown files keep the row and directory intact.
  Future<void> cleanup() async {
    _checkActive();
    if (_intent!['phase'] != 'committed') {
      throw StateError('Source transaction is not resolved');
    }
    await _validateOwned();
    for (final name in _owned.keys) {
      final file = File(p.join(directory.path, name));
      if (file.existsSync()) await file.delete();
    }
    await _event('cleanup-files');
    if (directory.existsSync()) await directory.delete();
    _db.execute('DELETE FROM mutations WHERE id = ?', [_intent!['id']]);
    _finished = true;
  }

  List<int>? _read(String relative) {
    final target = File(p.join(root, relative));
    SourceDataJournal.checkPath(root, target.path, FileSystemEntityType.file);
    return target.existsSync() ? target.readAsBytesSync() : null;
  }

  void _checkTarget(
    String relative,
    String kind, {
    bool checkFilesystem = true,
  }) {
    final source = p.dirname(relative) == 'comic_source';
    final name = p.basename(relative);
    final valid = switch (kind) {
      'script' => source && name.endsWith('.js'),
      'data' =>
        source &&
            name.endsWith('.data') &&
            _keys.hasMatch(name.substring(0, name.length - 5)),
      'settings' || 'backup' || 'temporary' => [
        'appdata.json',
        'syncdata.json',
        'appdata.json.bak',
        'syncdata.json.bak',
        'appdata.json.tmp',
        'syncdata.json.tmp',
      ].contains(relative),
      _ => false,
    };
    if (!valid || p.isAbsolute(relative)) {
      throw const FormatException('Invalid source transaction target');
    }
    if (checkFilesystem) {
      SourceDataJournal.checkPath(
        root,
        p.join(root, relative),
        FileSystemEntityType.file,
      );
    }
  }

  void _checkDelta(Map<String, dynamic> delta) {
    final fields = delta['fields'] as Map<String, dynamic>;
    if (fields.keys.any((key) => !_fields.contains(key))) {
      throw const FormatException('Unexpected source settings field');
    }
    for (final change in fields.values) {
      if (change is! Map ||
          !change.containsKey('before') ||
          !change.containsKey('after')) {
        throw const FormatException('Invalid source settings change');
      }
    }
    final origin = delta['origin'] as Map?;
    if (origin != null &&
        (origin['key'] is! String ||
            !_keys.hasMatch(origin['key'] as String) ||
            !origin.containsKey('before') ||
            !origin.containsKey('after'))) {
      throw const FormatException('Invalid source origin change');
    }
  }

  void _validate(Object? id) {
    if (_intent!['version'] != 1 ||
        _intent!['root'] != root ||
        id is! String ||
        !_ids.hasMatch(id) ||
        _intent!['id'] != id ||
        ![
          'preparing',
          'applying',
          'rollback',
          'committed',
        ].contains(_intent!['phase'])) {
      throw const FormatException('Invalid source transaction identity');
    }
    final paths = <String>{};
    for (final entry in _entries) {
      _checkTarget(
        entry['path'] as String,
        entry['kind'] as String,
        checkFilesystem: false,
      );
      if (!paths.add(entry['path'] as String) ||
          (entry['after'] as List).isEmpty) {
        throw const FormatException('Invalid source transaction resource list');
      }
      _decode(entry['before']);
      (entry['after'] as List).forEach(_decode);
      if (['settings', 'backup', 'temporary'].contains(entry['kind'])) {
        _checkDelta(entry['delta'] as Map<String, dynamic>);
      }
      if (entry['kind'] == 'data' &&
          entry['path'] != p.join('comic_source', '${_intent!['key']}.data')) {
        throw const FormatException('Source data identity mismatch');
      }
    }
    if (_entries.where((e) => e['kind'] == 'script').length != 1) {
      throw const FormatException('Missing source transaction script');
    }
    for (final entry in _owned.entries) {
      if (!['original.js', 'manifest.json'].contains(entry.key) &&
          !(entry.key.startsWith('work-') &&
              _ids.hasMatch(entry.key.substring(5)))) {
        throw const FormatException('Invalid source transaction staging name');
      }
      if (_decode(entry.value) == null) {
        throw const FormatException('Missing staging contents');
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final failures = <SourceMutationError>[];
    try {
      _db.dispose();
    } catch (error, stack) {
      failures.add((
        stage: 'close source transaction database',
        error: error,
        stack: stack,
      ));
    }
    try {
      await _lock.close();
    } catch (error, stack) {
      failures.add((
        stage: 'close source transaction lock',
        error: error,
        stack: stack,
      ));
    } finally {
      _held.remove(_lock.path);
    }
    if (failures.isNotEmpty) {
      throw SourceMutationFailure(
        state: SourceMutationState.recoveryRequired,
        failures: failures,
        recoveryPath: recoveryPath,
      );
    }
  }

  static String? _encode(List<int>? value) =>
      value == null ? null : base64Encode(value);
  static List<int>? _decode(Object? value) =>
      value == null ? null : base64Decode(value as String);
  static String? _hash(List<int>? value) =>
      value == null ? null : sha256.convert(value).toString();
  static bool _sameBytes(List<int>? a, List<int>? b) => _hash(a) == _hash(b);
  static bool _prefix(List<int> actual, List<int>? expected) {
    if (expected == null || actual.length > expected.length) return false;
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i]) return false;
    }
    return true;
  }

  static bool _sameJson(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
  static Object? _copy(Object? value) => jsonDecode(jsonEncode(value));
}
