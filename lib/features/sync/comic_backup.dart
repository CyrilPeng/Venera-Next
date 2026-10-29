import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:venera_next/features/sync/comic_archive_batch.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/log_redaction.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
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
    client.c.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'PUT') options.headers['If-None-Match'] = '*';
          handler.next(options);
        },
      ),
    );
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
    this.items = const [],
  });

  final int success;
  final int skipped;
  final int failed;
  final List<String> errors;

  /// Original operation/cleanup diagnostics behind the displayed messages.
  final List<BackupFailure> failures;
  final List<ArchiveItem> items;

  int get cancelled =>
      items.where((item) => item.state == ArchiveItemState.cancelled).length;
  int get notStarted =>
      items.where((item) => item.state == ArchiveItemState.pending).length;

  factory BackupResult.fromBatch(ComicArchiveBatch batch) => BackupResult(
    success: batch.count(ArchiveItemState.success),
    skipped: batch.count(ArchiveItemState.skipped),
    failed: batch.count(ArchiveItemState.failed),
    items: batch.items,
    errors: [
      for (final item in batch.items)
        if (item.error != null) '${item.title}: ${item.error}',
    ],
    failures: [
      for (final item in batch.items)
        if (item.error != null) (error: item.error!, stack: item.stack!),
    ],
  );
}

/// Manager for WebDAV comic archive backup and restore operations.
class ComicBackupManager {
  ComicBackupManager({
    ComicBackupWebDavOps? operations,
    BackupConfig Function() readConfig = BackupConfig.fromSettings,
    Future<void> Function(LocalComic comic, String outputPath) exportComic =
        CBZ.export,
    Future<LocalComic> Function(
          File file, {
          Future<void> Function(LocalComic comic)? registerComic,
        })
        importComic =
        CBZ.import,
    Future<void> Function(LocalComic comic)? registerImportedComic,
  }) : _operations = operations ?? WebDavComicBackupOps(),
       _readConfig = readConfig,
       _exportComic = exportComic,
       _importComic = importComic,
       _registerImportedComic = registerImportedComic;

  static final instance = ComicBackupManager();

  final ComicBackupWebDavOps _operations;
  final BackupConfig Function() _readConfig;
  final Future<void> Function(LocalComic comic, String outputPath) _exportComic;
  final Future<LocalComic> Function(
    File file, {
    Future<void> Function(LocalComic comic)? registerComic,
  })
  _importComic;
  final Future<void> Function(LocalComic comic)? _registerImportedComic;

  Future<Res<bool>> testConnection(BackupConfig config) async {
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV archive configuration');
    }
    try {
      await _operations.test(config);
      return const Res(true);
    } catch (error, stack) {
      return Res.fromException(error, stack);
    }
  }

  Future<Res<List<BackupFile>>> listBackups() async {
    final config = _readConfig();
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV archive configuration');
    }
    try {
      final files = await _operations.list(config);
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

  Future<BackupResult> backup(
    List<LocalComic> comics, {
    void Function(int current, int total, String currentTitle)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final batch = createBackupBatch(comics);
    try {
      await batch.run(onProgress: onProgress, isCancelled: isCancelled);
      return BackupResult.fromBatch(batch);
    } finally {
      batch.dispose();
    }
  }

  ComicArchiveBatch createBackupBatch(List<LocalComic> comics) {
    final targets = List<LocalComic>.of(comics);
    final config = _readConfig();
    final cachePath = App.cachePath;
    final date = DateTime.now();
    final items = [
      for (final comic in targets)
        ArchiveItem(
          title: comic.title,
          fileName: backupFileName(comic, date: date),
        ),
    ];
    final uploadedDigests = <int, Digest>{};
    Set<String>? remoteNames;
    var prepared = false;
    return ComicArchiveBatch(
      items: items,
      errorText: (error) => _safeError(error, config),
      action: (index, retry, cancelled) async {
        if (!config.isValid) {
          throw const ArchiveTransferFailure(
            'Invalid WebDAV archive configuration',
          );
        }
        if (!prepared) {
          await _operations.ensureDirectory(config);
          try {
            remoteNames = (await _operations.list(
              config,
            )).map((file) => file.name).toSet();
          } on WebDavClientCleanupFailure {
            rethrow;
          } catch (_) {
            remoteNames = null;
          }
          prepared = true;
        }
        if (cancelled()) return ArchiveItemState.cancelled;
        final item = items[index];
        final remotePath = config.remoteFilePath(item.fileName);
        // A retry must use fresh remote evidence, not the original listing.
        final exists = retry || remoteNames == null
            ? await _operations.exists(config, remotePath)
            : remoteNames!.contains(item.fileName);
        if (cancelled()) return ArchiveItemState.cancelled;
        if (exists && !retry) return ArchiveItemState.skipped;
        final workspace = await Directory(
          cachePath,
        ).createTemp('comic-backup-');
        try {
          if (exists) {
            final expected = uploadedDigests[index];
            if (expected == null) {
              throw const ArchiveTransferFailure(
                'Remote archive conflicts with this transfer. No file was overwritten.',
              );
            }
            final remote = File(FilePath.join(workspace.path, 'verify.cbz'));
            await _operations.downloadFile(config, remotePath, remote.path);
            if (await sha256.bind(remote.openRead()).first != expected) {
              throw const ArchiveTransferFailure(
                'Remote archive conflicts with this transfer. No file was overwritten.',
              );
            }
            return ArchiveItemState.success;
          }
          final local = File(FilePath.join(workspace.path, item.fileName));
          await _exportComic(targets[index], local.path);
          if (cancelled()) return ArchiveItemState.cancelled;
          uploadedDigests[index] = await sha256.bind(local.openRead()).first;
          if (cancelled()) return ArchiveItemState.cancelled;
          await _operations.uploadFile(config, local.path, remotePath);
          remoteNames?.add(item.fileName);
          return ArchiveItemState.success;
        } finally {
          await workspace.deleteIgnoreError(recursive: true);
        }
      },
    );
  }

  Future<BackupResult> restore(
    List<BackupFile> files, {
    void Function(int current, int total, String currentTitle)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final batch = createRestoreBatch(files);
    try {
      await batch.run(onProgress: onProgress, isCancelled: isCancelled);
      return BackupResult.fromBatch(batch);
    } finally {
      batch.dispose();
    }
  }

  ComicArchiveBatch createRestoreBatch(List<BackupFile> files) {
    final targets = List<BackupFile>.of(files);
    final config = _readConfig();
    final cachePath = App.cachePath;
    Future<void> Function(LocalComic)? register = _registerImportedComic;
    return ComicArchiveBatch(
      items: [
        for (final file in targets)
          ArchiveItem(title: file.name, fileName: file.name),
      ],
      errorText: (error) => _safeError(error, config),
      retryAllowed: (error) =>
          error is! PersistenceFailure ||
          error.commitState == PersistenceCommitState.notCommitted,
      action: (index, retry, cancelled) async {
        if (!config.isValid) {
          throw const ArchiveTransferFailure(
            'Invalid WebDAV archive configuration',
          );
        }
        register ??= _localRegistrar();
        final backup = targets[index];
        final workspace = await Directory(
          cachePath,
        ).createTemp('comic-restore-');
        var commit = PersistenceCommitState.notCommitted;
        try {
          final local = File(
            FilePath.join(workspace.path, sanitizeFileName(backup.name)),
          );
          await _operations.downloadFile(
            config,
            config.remoteFilePath(backup.name),
            local.path,
          );
          if (cancelled()) return ArchiveItemState.cancelled;
          await _importComic(
            local,
            registerComic: (comic) async {
              commit = PersistenceCommitState.unknown;
              try {
                await register!(comic);
                commit = PersistenceCommitState.committed;
              } on PersistenceFailure catch (error) {
                commit = error.commitState;
                rethrow;
              }
            },
          );
          return ArchiveItemState.success;
        } catch (error, stack) {
          if (commit != PersistenceCommitState.notCommitted &&
              error is! PersistenceFailure) {
            Error.throwWithStackTrace(
              PersistenceFailure(
                commitState: commit,
                cause: error,
                stackTrace: stack,
              ),
              stack,
            );
          }
          rethrow;
        } finally {
          await workspace.deleteIgnoreError(recursive: true);
        }
      },
    );
  }

  static String _safeError(Object error, BackupConfig config) {
    var text = redactLogText(error.toString());
    if (config.pass.length >= 4) {
      text = text.replaceAll(config.pass, logRedactionMask);
    }
    if (config.url.isNotEmpty) text = text.replaceAll(config.url, '[WebDAV]');
    return text;
  }

  static Future<void> Function(LocalComic) _localRegistrar() {
    final manager = LocalManager();
    return (comic) => manager.add(comic, manager.findValidId(comic.comicType));
  }

  Future<Res<bool>> deleteBackup(BackupFile file) async {
    final config = _readConfig();
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV archive configuration');
    }
    try {
      await _operations.deleteFile(config, config.remoteFilePath(file.name));
      return const Res(true);
    } catch (error, stack) {
      return Res.fromException(error, stack);
    }
  }

  static String backupFileName(LocalComic comic, {DateTime? date}) {
    final name = sanitizeFileName(
      comic.title,
      maxLength: maxSanitizedFileNameLength,
    );
    final now = date ?? DateTime.now();
    final timestamp =
        '${now.year}-${_twoDigits(now.month)}-${_twoDigits(now.day)}';
    return '${name}_$timestamp.cbz';
  }

  static String _twoDigits(int value) => value.toString().padLeft(2, '0');
}
