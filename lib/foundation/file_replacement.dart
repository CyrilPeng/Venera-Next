import 'dart:io';

/// A file replacement owned by a caller that has stopped all readers/writers.
/// Backups survive failed restoration; cleanup happens only after success.
class FileReplacement {
  FileReplacement(String targetPath, String backupPath)
    : target = File(targetPath),
      backupFile = File(backupPath);

  final File target;
  final File backupFile;
  bool _prepared = false;
  bool _hadOriginal = false;

  void backup() {
    if (_prepared) throw StateError('File replacement is already prepared');
    if (backupFile.existsSync()) {
      throw StateError('File replacement backup already exists');
    }
    _hadOriginal = target.existsSync();
    if (_hadOriginal) target.renameSync(backupFile.path);
    _prepared = true;
  }

  void restore() {
    if (!_prepared) throw StateError('File replacement has no backup state');
    if (_hadOriginal && !backupFile.existsSync()) {
      throw StateError(
        'File replacement backup is missing: ${backupFile.path}',
      );
    }
    if (target.existsSync()) target.deleteSync();
    if (_hadOriginal) backupFile.renameSync(target.path);
    _prepared = false;
  }

  void commit() {
    if (!_prepared) throw StateError('File replacement is not prepared');
    if (backupFile.existsSync()) backupFile.deleteSync();
    _prepared = false;
  }
}
