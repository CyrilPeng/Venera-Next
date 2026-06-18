import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/ext.dart';
import 'package:webdav_client/webdav_client.dart' hide File;
import 'package:venera/utils/translations.dart';

import 'io.dart';

enum _DataSyncTask { upload, download }

class DataSyncStatusSnapshot {
  const DataSyncStatusSnapshot({
    required this.isEnabled,
    required this.isUploading,
    required this.isDownloading,
    required this.lastSyncTime,
    required this.lastError,
  });

  final bool isEnabled;
  final bool isUploading;
  final bool isDownloading;
  final int lastSyncTime;
  final String? lastError;

  bool get isSyncing => isUploading || isDownloading;

  bool get shouldShow => isEnabled || isSyncing;

  String get title => isSyncing ? 'Syncing Data' : 'Sync Data';

  String get formattedLastSyncTime => _formatTime(lastSyncTime);

  static String _formatTime(int timestamp) {
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp);
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${twoDigits(time.month)}-${twoDigits(time.day)} '
        '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
  }
}

class DataSync with ChangeNotifier {
  DataSync._() {
    if (isEnabled) {
      unawaited(downloadData());
    }
    LocalFavoritesManager().addListener(onDataChanged);
    ComicSourceManager().addListener(onDataChanged);
    if (App.isDesktop && !debugDisableWindowCloseHandler) {
      Future.delayed(const Duration(seconds: 1), () {
        var controller = WindowFrame.of(App.rootContext);
        controller.addCloseListener(_handleWindowClose);
      });
    }
  }

  void onDataChanged() {
    if (isEnabled) {
      unawaited(uploadData());
    }
  }

  bool _handleWindowClose() {
    if (_isUploading) {
      _showWindowCloseDialog();
      return false;
    }
    return true;
  }

  void _showWindowCloseDialog() async {
    showLoadingDialog(
      App.rootContext,
      cancelButtonText: "Shut Down".tl,
      onCancel: () => exit(0),
      barrierDismissible: false,
      message: "Uploading data...".tl,
    );
    await _waitForUploadBeforeClose();
    exit(0);
  }

  Future<void> _waitForUploadBeforeClose() async {
    return _waitForTask(_DataSyncTask.upload);
  }

  Future<void> waitForDownload() async {
    return _waitForTask(_DataSyncTask.download);
  }

  Future<void> _waitForTask(_DataSyncTask task) async {
    while (true) {
      Future<Res<bool>>? taskFuture;
      if (_pendingTaskType == task) {
        taskFuture = _pendingTask;
      } else if (_activeTaskType == task) {
        taskFuture = _activeTask;
      }
      if (taskFuture == null) {
        return;
      }
      await taskFuture;
    }
  }

  static DataSync? instance;

  factory DataSync() => instance ?? (instance = DataSync._());

  @visibleForTesting
  static Future<Res<bool>> Function()? debugUploadOverride;

  @visibleForTesting
  static Future<Res<bool>> Function()? debugDownloadOverride;

  @visibleForTesting
  static bool debugDisableWindowCloseHandler = false;

  @visibleForTesting
  Future<void> debugWaitForUploadBeforeClose() {
    return _waitForUploadBeforeClose();
  }

  @visibleForTesting
  static void resetForTesting() {
    instance?.dispose();
    instance = null;
    debugUploadOverride = null;
    debugDownloadOverride = null;
    debugDisableWindowCloseHandler = false;
  }

  bool _isDownloading = false;

  bool get isDownloading => _isDownloading;

  bool _isUploading = false;

  bool get isUploading => _isUploading;

  Future<Res<bool>>? _activeTask;

  Future<Res<bool>>? _pendingTask;

  _DataSyncTask? _activeTaskType;

  _DataSyncTask? _pendingTaskType;

  String? _lastError;

  String? get lastError => _lastError;

  @override
  void dispose() {
    LocalFavoritesManager().removeListener(onDataChanged);
    ComicSourceManager().removeListener(onDataChanged);
    super.dispose();
  }

  DataSyncStatusSnapshot get statusSnapshot => DataSyncStatusSnapshot(
    isEnabled: isEnabled,
    isUploading: _isUploading,
    isDownloading: _isDownloading,
    lastSyncTime: (appdata.settings['lastSyncTime'] as int?) ?? 0,
    lastError: _lastError,
  );

  bool get isEnabled {
    var config = appdata.settings['webdav'];
    var autoSync = appdata.implicitData['webdavAutoSync'] ?? false;
    return autoSync && config is List && config.isNotEmpty;
  }

  List<String>? _validateConfig() {
    var config = appdata.settings['webdav'];
    if (config is! List) {
      return null;
    }
    if (config.isEmpty) {
      return [];
    }
    if (config.length != 3 || config.whereType<String>().length != 3) {
      return null;
    }
    return List.from(config);
  }

  Future<Res<bool>> uploadData() async {
    if (_activeTaskType == _DataSyncTask.download) {
      return const Res(true);
    }
    if (_activeTask != null) {
      return _schedulePendingTask(_DataSyncTask.upload, _uploadDataNow);
    }
    return _startTask(_DataSyncTask.upload, _uploadDataNow);
  }

  Future<Res<bool>> downloadData() async {
    if (_activeTask != null) {
      return _schedulePendingTask(_DataSyncTask.download, _downloadDataNow);
    }
    return _startTask(_DataSyncTask.download, _downloadDataNow);
  }

  Future<Res<bool>> _schedulePendingTask(
    _DataSyncTask task,
    Future<Res<bool>> Function() run,
  ) {
    if (_pendingTask != null) {
      return Future.value(const Res(true));
    }
    var activeTask = _activeTask!;
    _pendingTaskType = task;
    var pendingTask = activeTask.then(
      (_) {
        _pendingTask = null;
        _pendingTaskType = null;
        return _startTask(task, run);
      },
      onError: (_) {
        _pendingTask = null;
        _pendingTaskType = null;
        return _startTask(task, run);
      },
    );
    _pendingTask = pendingTask;
    return pendingTask;
  }

  Future<Res<bool>> _startTask(
    _DataSyncTask task,
    Future<Res<bool>> Function() run,
  ) {
    late Future<Res<bool>> activeTask;
    activeTask = _runTask(task, run).whenComplete(() {
      if (identical(_activeTask, activeTask)) {
        _activeTask = null;
      }
    });
    _activeTask = activeTask;
    return activeTask;
  }

  Future<Res<bool>> _runTask(
    _DataSyncTask task,
    Future<Res<bool>> Function() run,
  ) async {
    _activeTaskType = task;
    _isUploading = task == _DataSyncTask.upload;
    _isDownloading = task == _DataSyncTask.download;
    _lastError = null;
    notifyListeners();
    try {
      final result = await run();
      if (result.error) {
        _lastError = result.errorMessage;
      }
      return result;
    } catch (e, s) {
      Log.error(_taskLogTag(task), e, s);
      _lastError = e.toString();
      return Res.error(e.toString());
    } finally {
      _activeTaskType = null;
      _isUploading = false;
      _isDownloading = false;
      notifyListeners();
    }
  }

  String _taskLogTag(_DataSyncTask task) {
    return task == _DataSyncTask.upload ? 'Upload Data' : 'Data Sync';
  }

  Future<Res<bool>> _uploadDataNow() async {
    var debugUpload = debugUploadOverride;
    if (debugUpload != null) {
      return debugUpload();
    }
    var config = _validateConfig();
    if (config == null) {
      _lastError = 'Invalid WebDAV configuration';
      return const Res.error('Invalid WebDAV configuration');
    }
    if (config.isEmpty) {
      return const Res(true);
    }
    String url = config[0];
    String user = config[1];
    String pass = config[2];

    var client = newClient(
      url,
      user: user,
      password: pass,
      adapter: AppHttpClientAdapter(),
    );

    try {
      appdata.settings['dataVersion']++;
      await appdata.saveData(false);
      var data = await exportAppData(
        appdata.settings['disableSyncFields'].toString().isNotEmpty,
      );
      var time = (DateTime.now().millisecondsSinceEpoch ~/ 86400000).toString();
      var filename = time;
      filename += '-';
      filename += appdata.settings['dataVersion'].toString();
      filename += '.venera';
      var files = await client.readDir('/');
      files = files.where((e) => e.name!.endsWith('.venera')).toList();
      var old = files.firstWhereOrNull((e) => e.name!.startsWith("$time-"));
      if (old != null) {
        await client.remove(old.name!);
      }
      if (files.length >= 10) {
        files.sort((a, b) => a.name!.compareTo(b.name!));
        await client.remove(files.first.name!);
      }
      await client.write(filename, await data.readAsBytes());
      data.deleteIgnoreError();
      appdata.settings['lastSyncTime'] = DateTime.now().millisecondsSinceEpoch;
      await appdata.saveData(false);
      Log.info("Upload Data", "Data uploaded successfully");
      return const Res(true);
    } catch (e, s) {
      Log.error("Upload Data", e, s);
      _lastError = e.toString();
      return Res.error(e.toString());
    }
  }

  Future<Res<bool>> _downloadDataNow() async {
    var debugDownload = debugDownloadOverride;
    if (debugDownload != null) {
      return debugDownload();
    }
    var config = _validateConfig();
    if (config == null) {
      _lastError = 'Invalid WebDAV configuration';
      return const Res.error('Invalid WebDAV configuration');
    }
    if (config.isEmpty) {
      return const Res(true);
    }
    String url = config[0];
    String user = config[1];
    String pass = config[2];

    var client = newClient(
      url,
      user: user,
      password: pass,
      adapter: AppHttpClientAdapter(),
    );

    try {
      var files = await client.readDir('/');
      files.sort((a, b) => b.name!.compareTo(a.name!));
      var file = files.firstWhereOrNull((e) => e.name!.endsWith('.venera'));
      if (file == null) {
        throw 'No data file found';
      }
      var version = file.name!.split('-').elementAtOrNull(1)?.split('.').first;
      if (version != null && int.tryParse(version) != null) {
        var currentVersion = appdata.settings['dataVersion'];
        if (currentVersion != null && int.parse(version) <= currentVersion) {
          Log.info("Data Sync", 'No new data to download');
          return const Res(true);
        }
      }
      Log.info("Data Sync", "Downloading data from WebDAV server");
      var localFile = File(FilePath.join(App.cachePath, file.name!));
      await client.read2File(file.name!, localFile.path);
      await importAppData(localFile, true);
      await localFile.delete();
      HistoryManager().notifyChanges();
      LocalFavoritesManager().notifyChanges();
      ImageFavoriteManager().notifyChanges();
      appdata.settings['lastSyncTime'] = DateTime.now().millisecondsSinceEpoch;
      await appdata.saveData(false);
      Log.info("Data Sync", "Data downloaded successfully");
      return const Res(true);
    } catch (e, s) {
      Log.error("Data Sync", e, s);
      _lastError = e.toString();
      return Res.error(e.toString());
    }
  }
}
