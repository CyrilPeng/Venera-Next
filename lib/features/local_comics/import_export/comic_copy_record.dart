import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/foundation/file_system.dart';

/// A copy's intent precedes its first payload write. Completion is a second,
/// immutable record bound to that exact intent and the copied directory tree.
/// Neither a directory name nor the presence of images proves completion.
class ComicCopyRecord {
  ComicCopyRecord._(this.directory, this._intent, this.metadata);

  static const intentName = '.venera-copy-intent.json';
  static const completionName = '.venera-copy-complete.json';
  static const registrationName = '.venera-copy-registered.json';
  static const _names = {intentName, completionName, registrationName};

  final Directory directory;
  final String _intent;
  final String? metadata;

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

  static ComicCopyRecord prepare(
    Directory directory, {
    required String source,
    String? metadata,
  }) {
    // The caller has just reserved this directory. Refuse an unexpected marker
    // instead of overwriting another operation's recovery information.
    if (exists(Directory(directory.path))) {
      throw FileSystemException(
        'Copy recovery record already exists',
        directory.path,
      );
    }
    final intent = jsonEncode({
      'version': 1,
      'id': const Uuid().v4(),
      'source': source,
      'metadata': metadata,
    });
    final record = ComicCopyRecord._(directory, intent, metadata);
    record._intentFile.writeAsStringSync(intent, flush: true);
    record._checkIntent();
    return record;
  }

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
        value['version'] != 1 ||
        value['id'] is! String ||
        !Uuid.isValidUUID(fromString: value['id'] as String) ||
        value['source'] is! String ||
        (value['metadata'] != null && value['metadata'] is! String)) {
      throw const FormatException('Invalid comic copy intent');
    }
    return ComicCopyRecord._(directory, text, value['metadata'] as String?);
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

  Future<Map<String, String>> _tree() async {
    final entries = <String, String>{};
    Future<void> visit(Directory current, List<String> parent) async {
      final children = current.listSync(followLinks: false)
        ..sort((a, b) => a.name.compareTo(b.name));
      for (final entry in children) {
        if (parent.isEmpty && _names.contains(entry.name)) continue;
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
