import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/foundation/file_system.dart';

enum ComicCopyRecoveryKind { complete, resumable, unverified }

/// A copy's intent precedes its first payload write. Completion is a second,
/// immutable record bound to that exact intent and the copied directory tree.
/// Neither a directory name nor the presence of images proves completion.
class ComicCopyRecord {
  ComicCopyRecord._(
    this.directory,
    this._intent,
    this.metadata, [
    this._sourceTree,
  ]);

  static const intentName = '.venera-copy-intent.json';
  static const completionName = '.venera-copy-complete.json';
  static const registrationName = '.venera-copy-registered.json';
  static const stagingName = '.venera-copy-staging';
  static const _names = {
    intentName,
    completionName,
    registrationName,
    stagingName,
  };

  final Directory directory;
  final String _intent;
  final String? metadata;
  final Map<String, String>? _sourceTree;

  bool get canResume => _sourceTree != null;
  bool get hasCompletion =>
      _completionFile.existsSync() ||
      Directory(_completionFile.path).existsSync();

  String get intentDigest => sha256.convert(utf8.encode(_intent)).toString();

  void checkUnchanged() => _checkIntent();

  File get _intentFile => File(FilePath.join(directory.path, intentName));
  File get _completionFile =>
      File(FilePath.join(directory.path, completionName));
  File get _registrationFile =>
      File(FilePath.join(directory.path, registrationName));

  static bool exists(Directory directory, {bool recursive = false}) => directory
      .listSync(recursive: recursive)
      .any((entry) => _names.contains(entry.name.toLowerCase()));

  /// Capture the source before writing payload. A later recovery can prove
  /// which files are missing without guessing from the available images.
  static Future<ComicCopyRecord> prepare(
    Directory directory, {
    required Directory source,
    String? metadata,
  }) async {
    final sourcePath = _resolved(source);
    final tree = await _readTree(source, skipRecords: false);
    if (_resolved(source) != sourcePath || directory.listSync().isNotEmpty) {
      throw StateError('Copy source or reserved output changed');
    }
    final intent = jsonEncode({
      'version': 2,
      'id': const Uuid().v4(),
      'source': sourcePath,
      'metadata': metadata,
      'tree': tree,
    });
    final record = _fromIntent(directory, intent);
    record._intentFile.writeAsStringSync(intent, flush: true);
    record._checkIntent();
    return record;
  }

  static String _resolved(Directory directory) => directory is AndroidDirectory
      ? directory.path
      : directory.resolveSymbolicLinksSync();

  static Map<String, String> _parseTree(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid copy source manifest');
    }
    final result = <String, String>{};
    for (final entry in value.entries) {
      final segments = jsonDecode(entry.key);
      if (segments is! List ||
          segments.isEmpty ||
          segments.any(
            (part) =>
                part is! String ||
                part.isEmpty ||
                part == '.' ||
                part == '..' ||
                RegExp(r'[\\/\x00-\x1f]').hasMatch(part) ||
                (Platform.isWindows &&
                    (RegExp(r'[:<>"|?*]').hasMatch(part) ||
                        part.endsWith('.') ||
                        part.endsWith(' '))) ||
                _names.contains(part.toLowerCase()),
          ) ||
          jsonEncode(segments) != entry.key ||
          (entry.value != 'directory' &&
              (entry.value is! String ||
                  !RegExp(
                    r'^[0-9a-f]{64}$',
                  ).hasMatch(entry.value as String)))) {
        throw const FormatException('Invalid copy source entry');
      }
      if (segments.length > 1 &&
          value[jsonEncode(segments.sublist(0, segments.length - 1))] !=
              'directory') {
        throw const FormatException('Missing copy source parent');
      }
      result[entry.key] = entry.value as String;
    }
    return Map.unmodifiable(result);
  }

  /// A snapshot for explicitly recovering old, unmarked directories. It makes
  /// no claim that the available pages represent a complete original comic.
  static Future<String> unverifiedDigest(Directory directory) async => sha256
      .convert(
        utf8.encode(jsonEncode(await _readTree(directory, skipRecords: false))),
      )
      .toString();

  Future<void> verifyResumable() async {
    _checkIntent();
    final expected = _sourceTree;
    if (expected == null || hasCompletion) {
      throw StateError('Copy has no resumable source manifest');
    }
    final sourcePath =
        (jsonDecode(_intent) as Map<String, dynamic>)['source'] as String;
    final source = Directory(sourcePath);
    final outputPath = _resolved(directory);
    if (_resolved(source) != sourcePath ||
        path.equals(sourcePath, outputPath) ||
        path.isWithin(sourcePath, outputPath) ||
        path.isWithin(outputPath, sourcePath)) {
      throw StateError('Copy source location changed or overlaps output');
    }
    if (!_sameTree(await _readTree(source, skipRecords: false), expected)) {
      throw StateError('Copy source changed; reimport from the current source');
    }
    final actual = await _tree();
    if (actual.entries.any((entry) => expected[entry.key] != entry.value)) {
      throw StateError(
        'Copied files changed; keep them and reimport the source',
      );
    }
    _checkIntent();
  }

  /// Existing payload is never overwritten. Native atomic renames leave
  /// only an intent-owned staging file on interruption. Providers without atomic
  /// rename may also leave conflicting payload, which remains untouched.
  Future<void> resume() async {
    final outputRoot = _resolved(directory);
    await verifyResumable();
    final sourcePath =
        (jsonDecode(_intent) as Map<String, dynamic>)['source'] as String;
    final entries = _sourceTree!.entries.toList()
      ..sort((a, b) {
        final depth = (jsonDecode(a.key) as List).length.compareTo(
          (jsonDecode(b.key) as List).length,
        );
        return depth == 0 ? a.key.compareTo(b.key) : depth;
      });
    for (final entry in entries) {
      _checkIntent();
      final parts = (jsonDecode(entry.key) as List).cast<String>();
      final target = path.joinAll([directory.path, ...parts]);
      void checkOutputParent() {
        if (_resolved(directory) != outputRoot ||
            !path.equals(
              _resolved(Directory(path.dirname(target))),
              path.joinAll([outputRoot, ...parts.take(parts.length - 1)]),
            )) {
          throw StateError('Copy output location changed while resuming');
        }
      }

      checkOutputParent();
      if (File(target).existsSync() || Directory(target).existsSync()) continue;
      if (entry.value == 'directory') {
        Directory(target).createSync();
      } else {
        final bytes = await readFileBytesChecked(
          File(path.joinAll([sourcePath, ...parts])),
          requireNonEmpty: isComicImageFileName(parts.last),
          synchronousIO: true,
        );
        if (sha256.convert(bytes).toString() != entry.value) {
          throw StateError('Copy source changed while resuming');
        }
        final staging = File(FilePath.join(directory.path, stagingName));
        // Recheck links/types before opening the only replaceable control file.
        final stagingEntries = directory
            .listSync(followLinks: false)
            .where((entry) => entry.name.toLowerCase() == stagingName);
        if (stagingEntries.any(
          (entry) => entry is! File || entry.name != stagingName,
        )) {
          throw StateError('Unexpected copy staging entry');
        }
        staging.writeAsBytesSync(bytes, flush: true);
        if (sha256
                .convert(
                  await readFileBytesChecked(staging, synchronousIO: true),
                )
                .toString() !=
            entry.value) {
          throw StateError('Incomplete copy staging write');
        }
        _checkIntent();
        checkOutputParent();
        if (File(target).existsSync() || Directory(target).existsSync()) {
          throw StateError('Copy target appeared while resuming');
        }
        staging.renameSync(target);
      }
    }
    final staging = File(FilePath.join(directory.path, stagingName));
    if (staging.existsSync()) staging.deleteSync();
    await complete();
  }

  static bool _sameTree(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length &&
      a.entries.every((entry) => b[entry.key] == entry.value);

  static ComicCopyRecord read(Directory directory) {
    final receiptPath = FilePath.join(directory.path, registrationName);
    if (File(receiptPath).existsSync() || Directory(receiptPath).existsSync()) {
      throw StateError('Copy cleanup receipt cannot authorize registration');
    }
    final text = File(
      FilePath.join(directory.path, intentName),
    ).readAsStringSync();
    return _fromIntent(directory, text);
  }

  static ComicCopyRecord _fromIntent(Directory directory, String text) {
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic> ||
        (value['version'] != 1 && value['version'] != 2) ||
        value['id'] is! String ||
        !Uuid.isValidUUID(fromString: value['id'] as String) ||
        value['source'] is! String ||
        (value['metadata'] != null && value['metadata'] is! String)) {
      throw const FormatException('Invalid comic copy intent');
    }
    return ComicCopyRecord._(
      directory,
      text,
      value['metadata'] as String?,
      value['version'] == 2 ? _parseTree(value['tree']) : null,
    );
  }

  /// Cleanup may already have removed intent/completion. Its durable receipt
  /// retains the exact intent, but must never authorize a new registration.
  static ComicCopyRecord readForCleanup(Directory directory) {
    final receipt = File(FilePath.join(directory.path, registrationName));
    if (!receipt.existsSync()) return read(directory);
    final value = jsonDecode(receipt.readAsStringSync());
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value['intent'] is! String ||
        value['registration'] is! String) {
      throw const FormatException('Invalid comic copy registration receipt');
    }
    return _fromIntent(directory, value['intent'] as String);
  }

  String _registrationReceipt(String registration) => jsonEncode({
    'version': 1,
    'intent': _intent,
    'registration': registration,
  });

  /// The registration snapshot comes from the actual current database row.
  bool hasRegistration(String registration) {
    if (!_registrationFile.existsSync() &&
        !Directory(_registrationFile.path).existsSync()) {
      return false;
    }
    if (_registrationFile.readAsStringSync() !=
        _registrationReceipt(registration)) {
      throw FileSystemException(
        'Copy cleanup registration has changed',
        directory.path,
      );
    }
    return true;
  }

  void _checkIntent() {
    if (_intentFile.readAsStringSync() != _intent) {
      throw FileSystemException('Comic copy intent changed', directory.path);
    }
  }

  Future<void> complete() async {
    _checkIntent();
    if (_completionFile.existsSync() ||
        Directory(_completionFile.path).existsSync()) {
      throw FileSystemException(
        'Copy completion already exists',
        directory.path,
      );
    }
    final tree = await _tree();
    if (_sourceTree != null && !_sameTree(tree, _sourceTree)) {
      throw StateError('Copy does not match the original source manifest');
    }
    _checkIntent();
    final completion = jsonEncode({
      'version': 1,
      'intent': intentDigest,
      'tree': tree,
    });
    _completionFile.writeAsStringSync(completion, flush: true);
    if (_completionFile.readAsStringSync() != completion) {
      throw FileSystemException(
        'Incomplete copy completion record',
        directory.path,
      );
    }
  }

  /// Reads actual payload bytes again. A damaged/missing completion, changed
  /// file, added file, or removed directory cannot authorize registration.
  Future<void> verifyComplete() async {
    _checkIntent();
    final value = jsonDecode(_completionFile.readAsStringSync());
    final tree = await _tree();
    _checkIntent();
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value['intent'] != intentDigest ||
        (_sourceTree != null && !_sameTree(tree, _sourceTree)) ||
        jsonEncode(value['tree']) != jsonEncode(tree)) {
      throw FileSystemException(
        'Comic copy is incomplete or has changed',
        directory.path,
      );
    }
  }

  void _checkCompletion() {
    final completion = jsonDecode(_completionFile.readAsStringSync());
    if (completion is! Map<String, dynamic> ||
        completion['version'] != 1 ||
        completion['intent'] != intentDigest) {
      throw FileSystemException(
        'Copy completion belongs to another intent',
        directory.path,
      );
    }
  }

  /// The caller has verified this exact database registration. Persist a
  /// cleanup receipt before removing either original record; a later retry
  /// must supply the same registration and never touches comic payload.
  void removeAfterRegistration(String registration) {
    if (!hasRegistration(registration)) {
      _checkIntent();
      _checkCompletion();
      final receipt = _registrationReceipt(registration);
      _registrationFile.writeAsStringSync(receipt, flush: true);
      if (!hasRegistration(registration)) {
        throw FileSystemException(
          'Copy cleanup receipt was not written',
          directory.path,
        );
      }
    }
    // Check both originals before deleting either one. An unexpected directory
    // or changed record is a conflict, never something to remove recursively.
    final hasIntent =
        _intentFile.existsSync() || Directory(_intentFile.path).existsSync();
    final hasCompletion =
        _completionFile.existsSync() ||
        Directory(_completionFile.path).existsSync();
    if (hasIntent) _checkIntent();
    if (hasCompletion) _checkCompletion();
    if (hasCompletion) _completionFile.deleteSync();
    if (hasIntent) {
      _checkIntent();
      _intentFile.deleteSync();
    }
    if (hasRegistration(registration)) _registrationFile.deleteSync();
  }

  Future<Map<String, String>> _tree() =>
      _readTree(directory, skipRecords: true);

  static Future<Map<String, String>> _readTree(
    Directory directory, {
    required bool skipRecords,
  }) async {
    final entries = <String, String>{};
    Future<void> visit(Directory current, List<String> parent) async {
      final children = current.listSync(followLinks: false)
        ..sort((a, b) => a.name.compareTo(b.name));
      for (final entry in children) {
        if (_names.contains(entry.name.toLowerCase())) {
          if (skipRecords && parent.isEmpty && entry is File) continue;
          throw FileSystemException(
            'Unexpected copy control entry',
            entry.path,
          );
        }
        final segments = [...parent, entry.name];
        final key = jsonEncode(segments);
        if (entry is Directory) {
          entries[key] = 'directory';
          await visit(entry, segments);
        } else if (entry is File) {
          final bytes = await readFileBytesChecked(
            entry,
            requireNonEmpty: isComicImageFileName(entry.name),
            synchronousIO: true,
          );
          entries[key] = sha256.convert(bytes).toString();
        } else {
          throw FileSystemException(
            'Unexpected link in copied output',
            entry.path,
          );
        }
      }
    }

    await visit(Directory(directory.path), const []);
    return entries;
  }
}
