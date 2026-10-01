import 'dart:io';
import 'package:path/path.dart' as p;

/// Directory replacement state owned by a caller that has stopped its users.
/// Recovery never deletes the target until the original backup is verified.
class DirectoryReplacement {
  DirectoryReplacement(String targetPath, String backupPath)
    : target = Directory(targetPath),
      backupDirectory = Directory(backupPath) {
    final targetAbsolute = p.normalize(p.absolute(targetPath));
    final backupAbsolute = p.normalize(p.absolute(backupPath));
    if (p.equals(targetAbsolute, backupAbsolute) ||
        p.isWithin(targetAbsolute, backupAbsolute) ||
        p.isWithin(backupAbsolute, targetAbsolute)) {
      throw ArgumentError('Replacement directories must not overlap');
    }
  }

  final Directory target;
  final Directory backupDirectory;
  bool _prepared = false;
  bool _hadOriginal = false;

  FileSystemEntityType _type(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false);

  void backup() {
    if (_prepared) {
      throw StateError('Directory replacement is already prepared');
    }
    if (_type(backupDirectory.path) != FileSystemEntityType.notFound) {
      throw StateError('Directory replacement backup already exists');
    }
    final type = _type(target.path);
    if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.notFound) {
      throw StateError('Directory replacement target is not a directory');
    }
    _hadOriginal = type == FileSystemEntityType.directory;
    if (_hadOriginal) target.renameSync(backupDirectory.path);
    _prepared = true;
  }

  void restore() {
    if (!_prepared) throw StateError('Directory replacement is not prepared');
    if (_hadOriginal &&
        _type(backupDirectory.path) != FileSystemEntityType.directory) {
      throw StateError('Directory replacement backup is missing or invalid');
    }
    final type = _type(target.path);
    if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.notFound) {
      throw StateError('Directory replacement target is not a directory');
    }
    if (type == FileSystemEntityType.directory) {
      target.deleteSync(recursive: true);
    }
    if (_hadOriginal) backupDirectory.renameSync(target.path);
    _prepared = false;
  }
}
