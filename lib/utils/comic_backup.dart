import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/io.dart';
import 'package:webdav_client/webdav_client.dart' hide File;

/// WebDAV archive backup configuration for local comic CBZ files.
class BackupConfig {
  BackupConfig({
    required String url,
    required String user,
    required String pass,
    required String remotePath,
  }) : url = url.trim(),
       user = user.trim(),
       pass = pass.trim(),
       remotePath = _normalizedPath(remotePath);

  final String url;
  final String user;
  final String pass;
  final String remotePath;

  bool get isValid => url.trim().isNotEmpty;

  static BackupConfig fromSettings() {
    final config = appdata.settings['backupWebdav'];
    final path = appdata.settings['backupWebdavPath'];
    if (config is List && config.whereType<String>().length == 3) {
      final values = config.whereType<String>().toList();
      return BackupConfig(
        url: values[0].trim(),
        user: values[1].trim(),
        pass: values[2].trim(),
        remotePath: path is String ? path : '/venera_backup/',
      );
    }
    return BackupConfig(
      url: '',
      user: '',
      pass: '',
      remotePath: path is String ? path : '/venera_backup/',
    );
  }

  static Future<void> saveToSettings(BackupConfig config) async {
    if (!config.isValid && config.user.isEmpty && config.pass.isEmpty) {
      appdata.settings['backupWebdav'] = [];
    } else {
      appdata.settings['backupWebdav'] = [
        config.url.trim(),
        config.user.trim(),
        config.pass.trim(),
      ];
    }
    appdata.settings['backupWebdavPath'] = config.remotePath;
    await appdata.saveData(false);
  }

  String remoteFilePath(String fileName) => '$remotePath$fileName';

  static String _normalizedPath(String path) {
    var result = path.trim().replaceAll('\\', '/');
    if (result.isEmpty) result = '/venera_backup/';
    if (!result.startsWith('/')) result = '/$result';
    if (!result.endsWith('/')) result = '$result/';
    return result;
  }
}

/// A CBZ backup file stored on WebDAV.
class BackupFile {
  const BackupFile({
    required this.name,
    required this.size,
    required this.modified,
  });

  final String name;
  final int size;
  final DateTime modified;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackupFile &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          size == other.size &&
          modified == other.modified;

  @override
  int get hashCode => Object.hash(name, size, modified);
}

/// Abstraction over WebDAV operations to keep backup logic testable.
abstract class ComicBackupWebDavOps {
  Future<void> test(BackupConfig config);

  Future<List<BackupFile>> list(BackupConfig config);

  Future<bool> exists(BackupConfig config, String remotePath);

  Future<void> ensureDirectory(BackupConfig config);

  Future<void> uploadFile(
    BackupConfig config,
    String localPath,
    String remotePath,
  );

  Future<void> downloadFile(
    BackupConfig config,
    String remotePath,
    String localPath,
  );

  Future<void> deleteFile(BackupConfig config, String remotePath);
}

class _WebDavComicBackupOps implements ComicBackupWebDavOps {
  Client _client(BackupConfig config) {
    return newClient(
      config.url,
      user: config.user,
      password: config.pass,
      adapter: AppHttpClientAdapter(),
    );
  }

  @override
  Future<void> test(BackupConfig config) async {
    await _client(config).readDir(config.remotePath);
  }

  @override
  Future<List<BackupFile>> list(BackupConfig config) async {
    final entries = await _client(config).readDir(config.remotePath);
    return entries
        .where((entry) => entry.isDir != true && entry.name != null)
        .map(
          (entry) => BackupFile(
            name: entry.name!,
            size: entry.size ?? 0,
            modified: entry.mTime ?? DateTime.fromMillisecondsSinceEpoch(0),
          ),
        )
        .toList();
  }

  @override
  Future<bool> exists(BackupConfig config, String remotePath) async {
    final entries = await _client(config).readDir(config.remotePath);
    final name = remotePath.split('/').last;
    return entries.any((entry) => entry.name == name);
  }

  @override
  Future<void> ensureDirectory(BackupConfig config) async {
    await _client(config).mkdirAll(config.remotePath);
  }

  @override
  Future<void> uploadFile(
    BackupConfig config,
    String localPath,
    String remotePath,
  ) async {
    await _client(config).writeFromFile(localPath, remotePath);
  }

  @override
  Future<void> downloadFile(
    BackupConfig config,
    String remotePath,
    String localPath,
  ) async {
    await _client(config).read2File(remotePath, localPath);
  }

  @override
  Future<void> deleteFile(BackupConfig config, String remotePath) async {
    await _client(config).remove(remotePath);
  }
}

/// Aggregate result for backup and restore operations.
class BackupResult {
  const BackupResult({
    required this.success,
    required this.skipped,
    required this.failed,
    this.errors = const [],
  });

  final int success;
  final int skipped;
  final int failed;
  final List<String> errors;
}

/// Manager for WebDAV comic archive backup and restore operations.
class ComicBackupManager {
  const ComicBackupManager._();

  static ComicBackupWebDavOps ops = _WebDavComicBackupOps();

  static void resetOps() {
    ops = _WebDavComicBackupOps();
  }

  static Future<void> Function(LocalComic comic, String outputPath)?
  exportComic;

  static Future<LocalComic> Function(String filePath)? importComic;

  static Future<void> Function(LocalComic comic)? registerImportedComic;

  static BackupConfig get config => BackupConfig.fromSettings();

  static Future<Res<bool>> testConnection(BackupConfig config) async {
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV archive configuration');
    }
    try {
      await ops.test(config);
      return const Res(true);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  static Future<Res<List<BackupFile>>> listBackups() async {
    final config = BackupConfig.fromSettings();
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV archive configuration');
    }
    try {
      final files = await ops.list(config);
      final cbzFiles =
          files
              .where((file) => file.name.toLowerCase().endsWith('.cbz'))
              .toList()
            ..sort((a, b) => b.modified.compareTo(a.modified));
      return Res(cbzFiles);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  static Future<BackupResult> backup(
    List<LocalComic> comics, {
    void Function(int current, int total, String currentTitle)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final config = BackupConfig.fromSettings();
    if (!config.isValid) {
      return const BackupResult(
        success: 0,
        skipped: 0,
        failed: 1,
        errors: ['Invalid WebDAV archive configuration'],
      );
    }
    var success = 0;
    var skipped = 0;
    var failed = 0;
    final errors = <String>[];
    try {
      await ops.ensureDirectory(config);
    } catch (e) {
      return BackupResult(
        success: 0,
        skipped: 0,
        failed: comics.length,
        errors: [e.toString()],
      );
    }
    // 批量获取远端已有文件，避免逐本 PROPFIND
    final remoteFileNames = <String>{};
    var listSuccess = false;
    try {
      final remoteFiles = await ops.list(config);
      for (final f in remoteFiles) {
        remoteFileNames.add(f.name);
      }
      listSuccess = true;
    } catch (_) {
      // 列表失败忽略，后续退化为逐本检查
    }
    for (var i = 0; i < comics.length; i++) {
      if (isCancelled?.call() == true) break;
      final comic = comics[i];
      onProgress?.call(i + 1, comics.length, comic.title);
      final fileName = backupFileName(comic);
      final remotePath = config.remoteFilePath(fileName);
      final localPath = FilePath.join(
        App.cachePath,
        'comic_backup_${DateTime.now().microsecondsSinceEpoch}_$fileName',
      );
      final localFile = File(localPath);
      try {
        final exists = listSuccess
            ? remoteFileNames.contains(fileName)
            : await ops.exists(config, remotePath);
        if (exists) {
          skipped++;
          continue;
        }
        final exporter = exportComic;
        if (exporter != null) {
          await exporter(comic, localPath);
        } else {
          await CBZ.export(comic, localPath);
        }
        await ops.uploadFile(config, localPath, remotePath);
        success++;
      } catch (e) {
        failed++;
        errors.add('${comic.title}: $e');
      } finally {
        await localFile.deleteIgnoreError();
      }
    }
    return BackupResult(
      success: success,
      skipped: skipped,
      failed: failed,
      errors: errors,
    );
  }

  static Future<BackupResult> restore(
    List<BackupFile> files, {
    void Function(int current, int total, String currentTitle)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final config = BackupConfig.fromSettings();
    if (!config.isValid) {
      return const BackupResult(
        success: 0,
        skipped: 0,
        failed: 1,
        errors: ['Invalid WebDAV archive configuration'],
      );
    }
    var success = 0;
    var failed = 0;
    final errors = <String>[];
    for (var i = 0; i < files.length; i++) {
      if (isCancelled?.call() == true) break;
      final backup = files[i];
      onProgress?.call(i + 1, files.length, backup.name);
      final remotePath = config.remoteFilePath(backup.name);
      final localPath = FilePath.join(
        App.cachePath,
        'comic_restore_${DateTime.now().microsecondsSinceEpoch}_${backup.name}',
      );
      final localFile = File(localPath);
      try {
        await ops.downloadFile(config, remotePath, localPath);
        late LocalComic comic;
        final importer = importComic;
        if (importer != null) {
          comic = await importer(localPath);
        } else {
          comic = await CBZ.import(localFile);
        }
        final register = registerImportedComic;
        if (register != null) {
          await register(comic);
        } else {
          LocalManager().add(
            comic,
            LocalManager().findValidId(comic.comicType),
          );
        }
        success++;
      } catch (e) {
        failed++;
        errors.add('${backup.name}: $e');
      } finally {
        await localFile.deleteIgnoreError();
      }
    }
    return BackupResult(
      success: success,
      skipped: 0,
      failed: failed,
      errors: errors,
    );
  }

  static Future<Res<bool>> deleteBackup(BackupFile file) async {
    final config = BackupConfig.fromSettings();
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV archive configuration');
    }
    try {
      await ops.deleteFile(config, config.remoteFilePath(file.name));
      return const Res(true);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  static String backupFileName(LocalComic comic) {
    final name = sanitizeFileName(
      comic.title,
      maxLength: maxSanitizedFileNameLength,
    );
    final now = DateTime.now();
    final timestamp =
        '${now.year}-${_twoDigits(now.month)}-${_twoDigits(now.day)}';
    return '${name}_$timestamp.cbz';
  }

  static String _twoDigits(int value) => value.toString().padLeft(2, '0');
}
