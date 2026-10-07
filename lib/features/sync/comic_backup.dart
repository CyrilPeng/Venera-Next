import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/local_comics/import_export/cbz.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/network/webdav.dart';
import 'package:webdav_client/webdav_client.dart' hide File;

/// WebDAV archive backup configuration for local comic CBZ files.
class BackupConfig {
  BackupConfig({
    required String url,
    required String user,
    required String pass,
    required String remotePath,
  }) : endpoint = WebDavEndpoint(url: url, user: user, password: pass),
       remotePath = normalizeWebDavDirectoryPath(
         remotePath,
         fallback: '/venera_backup/',
       );

  final WebDavEndpoint endpoint;
  final String remotePath;

  String get url => endpoint.url;

  String get user => endpoint.user;

  String get pass => endpoint.password;

  bool get isValid => endpoint.isValid;

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

  static bool get syncEnabled =>
      appdata.settings['backupWebdavSyncEnabled'] == true;

  static Future<void> saveToSettings(
    BackupConfig config, {
    required bool syncEnabled,
  }) => appdata.updateSettings((draft) {
    draft['backupWebdav'] =
        !config.isValid && config.user.isEmpty && config.pass.isEmpty
        ? <String>[]
        : [config.url.trim(), config.user.trim(), config.pass.trim()];
    draft['backupWebdavPath'] = config.remotePath;
    draft['backupWebdavSyncEnabled'] = syncEnabled;
  }, sync: false);

  String remoteFilePath(String fileName) {
    return joinWebDavFilePath(remotePath, fileName);
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

class WebDavComicBackupOps implements ComicBackupWebDavOps {
  WebDavComicBackupOps({Client Function(BackupConfig)? createClient})
    : _createClient =
          createClient ?? ((config) => config.endpoint.createClient());

  final Client Function(BackupConfig) _createClient;

  Future<T> _request<T>(
    BackupConfig config,
    Future<T> Function(Client client) action,
  ) async {
    final client = _createClient(config);
    Object? cause;
    StackTrace? stack;
    try {
      return await action(client);
    } catch (error, trace) {
      cause = error;
      stack = trace;
      rethrow;
    } finally {
      // A failed SDK Future can precede native completion. Keep files borrowed
      // by this operation until its own client has actually finished releasing.
      await closeWebDavClient(client, cause: cause, stackTrace: stack);
    }
  }

  @override
  Future<void> test(BackupConfig config) => _request(config, (client) async {
    await client.readDir(config.remotePath);
  });

  @override
  Future<List<BackupFile>> list(BackupConfig config) =>
      _request(config, (client) async {
        final entries = await client.readDir(config.remotePath);
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
      });

  @override
  Future<bool> exists(BackupConfig config, String remotePath) =>
      _request(config, (client) async {
        final entries = await client.readDir(config.remotePath);
        final name = remotePath.split('/').last;
        return entries.any((entry) => entry.name == name);
      });

  @override
  Future<void> ensureDirectory(BackupConfig config) =>
      _request(config, (client) async {
        await client.mkdirAll(config.remotePath);
      });

  @override
  Future<void> uploadFile(
    BackupConfig config,
    String localPath,
    String remotePath,
  ) => _request(config, (client) async {
    await client.writeFromFile(localPath, remotePath);
  });

  @override
  Future<void> downloadFile(
    BackupConfig config,
    String remotePath,
    String localPath,
  ) => _request(config, (client) async {
    await client.read2File(remotePath, localPath);
  });

  @override
  Future<void> deleteFile(BackupConfig config, String remotePath) =>
      _request(config, (client) async {
        await client.remove(remotePath);
      });
}

/// Original diagnostics retained alongside the batch's display messages.
typedef BackupFailure = ({Object error, StackTrace stack});

/// Aggregate result for backup and restore operations.
class BackupResult {
  const BackupResult({
    required this.success,
    required this.skipped,
    required this.failed,
    this.errors = const [],
    this.failures = const [],
  });

  final int success;
  final int skipped;
  final int failed;
  final List<String> errors;

  /// Original operation/cleanup diagnostics behind the displayed messages.
  final List<BackupFailure> failures;
}

/// Manager for WebDAV comic archive backup and restore operations.
class ComicBackupManager {
  const ComicBackupManager._();

  static ComicBackupWebDavOps ops = WebDavComicBackupOps();

  static void resetOps() {
    ops = WebDavComicBackupOps();
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
    } catch (error, stack) {
      return Res.fromException(error, stack);
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
    } catch (error, stack) {
      return Res.fromException(error, stack);
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
    final failures = <BackupFailure>[];
    try {
      await ops.ensureDirectory(config);
    } catch (e, stack) {
      return BackupResult(
        success: 0,
        skipped: 0,
        failed: comics.length,
        errors: [e.toString()],
        failures: [(error: e, stack: stack)],
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
    } on WebDavClientCleanupFailure catch (error, stack) {
      // Ordinary listing failure can fall back to per-file checks, but a
      // resource-release failure must not disappear into a later success.
      return BackupResult(
        success: 0,
        skipped: 0,
        failed: comics.length,
        errors: [error.toString()],
        failures: [(error: error, stack: stack)],
      );
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
      } catch (e, stack) {
        failed++;
        errors.add('${comic.title}: $e');
        failures.add((error: e, stack: stack));
      } finally {
        await localFile.deleteIgnoreError();
      }
    }
    return BackupResult(
      success: success,
      skipped: skipped,
      failed: failed,
      errors: errors,
      failures: failures,
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
    final failures = <BackupFailure>[];
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
        Future<void> register(LocalComic comic) async {
          final callback = registerImportedComic;
          if (callback != null) {
            await callback(comic);
          } else {
            await LocalManager().add(
              comic,
              LocalManager().findValidId(comic.comicType),
            );
          }
        }

        final importer = importComic;
        if (importer != null) {
          await register(await importer(localPath));
        } else {
          await CBZ.import(localFile, registerComic: register);
        }
        success++;
      } catch (e, stack) {
        failed++;
        errors.add('${backup.name}: $e');
        failures.add((error: e, stack: stack));
      } finally {
        await localFile.deleteIgnoreError();
      }
    }
    return BackupResult(
      success: success,
      skipped: 0,
      failed: failed,
      errors: errors,
      failures: failures,
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
    } catch (error, stack) {
      return Res.fromException(error, stack);
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
