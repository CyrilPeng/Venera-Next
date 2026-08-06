import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/features/settings/webdav_connection_fields.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/features/webdav_library/webdav_library.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

class AppSettings extends StatefulWidget {
  const AppSettings({super.key});

  @override
  State<AppSettings> createState() => _AppSettingsState();
}

class _AppSettingsState extends State<AppSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("App".tl)),
        SettingPartTitle(title: "Data".tl, icon: Icons.storage),
        ListTile(
          title: Text("Storage Path for local comics".tl),
          subtitle: Text(LocalManager().path, softWrap: false),
          trailing: IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: LocalManager().path));
              context.showMessage(message: "Path copied to clipboard".tl);
            },
          ),
        ).toSliver(),
        CallbackSetting(
          title: "Set New Storage Path".tl,
          actionTitle: "Set".tl,
          callback: () async {
            String? result;
            if (App.isAndroid) {
              var picker = DirectoryPicker();
              result = (await picker.pickDirectory())?.path;
            } else if (App.isIOS) {
              result = await selectDirectoryIOS();
            } else {
              result = await selectDirectory();
            }
            if (result == null) return;
            var loadingDialog = showLoadingDialog(
              App.rootContext,
              barrierDismissible: false,
              allowCancel: false,
            );
            var res = await LocalManager().setNewPath(result);
            loadingDialog.close();
            if (res != null) {
              context.showMessage(message: res);
            } else {
              context.showMessage(message: "Path set successfully".tl);
              setState(() {});
            }
          },
        ).toSliver(),
        ListTile(
          title: Text("Cache Size".tl),
          subtitle: Text(bytesToReadableString(CacheManager().currentSize)),
        ).toSliver(),
        CallbackSetting(
          title: "Clear Cache".tl,
          actionTitle: "Clear".tl,
          callback: () async {
            var loadingDialog = showLoadingDialog(
              App.rootContext,
              barrierDismissible: false,
              allowCancel: false,
            );
            await CacheManager().clear();
            loadingDialog.close();
            context.showMessage(message: "Cache cleared".tl);
            setState(() {});
          },
        ).toSliver(),
        CallbackSetting(
          title: "Cache Limit".tl,
          subtitle: "${appdata.settings['cacheSize']} MB",
          callback: () {
            showInputDialog(
              context: context,
              title: "Set Cache Limit".tl,
              hintText: "Size in MB".tl,
              inputValidator: RegExp(r"^\d+$"),
              onConfirm: (value) {
                appdata.settings['cacheSize'] = int.parse(value);
                appdata.saveData();
                setState(() {});
                CacheManager().setLimitSize(appdata.settings['cacheSize']);
                return null;
              },
            );
          },
          actionTitle: 'Set'.tl,
        ).toSliver(),
        SliderSetting(
          title: "Auto Clear History".tl,
          settingsIndex: "historyRetentionDays",
          interval: 7,
          min: 0,
          max: 182,
          onChanged: () {
            final retentionDays =
                (appdata.settings['historyRetentionDays'] as num).round();
            HistoryManager().clearExpiredHistory(retentionDays);
          },
        ).toSliver(),
        CallbackSetting(
          title: "Export App Data".tl,
          callback: () async {
            var controller = showLoadingDialog(context);
            var file = await exportAppData(false);
            await saveFile(filename: "data.venera", file: file);
            controller.close();
          },
          actionTitle: 'Export'.tl,
        ).toSliver(),
        CallbackSetting(
          title: "Import App Data".tl,
          callback: () async {
            var controller = showLoadingDialog(context);
            var file = await selectFile(ext: ['venera', 'picadata']);
            if (file != null) {
              var cacheFile = File(
                FilePath.join(App.cachePath, "import_data_temp"),
              );
              await file.saveTo(cacheFile.path);
              try {
                if (file.name.endsWith('picadata')) {
                  await importPicaData(cacheFile);
                } else {
                  await importAppData(cacheFile);
                }
              } catch (e, s) {
                Log.error("Import data", e.toString(), s);
                context.showMessage(message: "Failed to import data".tl);
              } finally {
                cacheFile.deleteIgnoreError();
                App.forceRebuild();
              }
            }
            controller.close();
          },
          actionTitle: 'Import'.tl,
        ).toSliver(),
        CallbackSetting(
          title: "Data Sync".tl,
          callback: () async {
            showPopUpWidget(context, const _WebdavSetting());
          },
          actionTitle: 'Set'.tl,
        ).toSliver(),
        CallbackSetting(
          title: "Comic Archive Backup".tl,
          subtitle: "This is only used for CBZ archive backup and restore.".tl,
          callback: () async {
            showPopUpWidget(context, const _BackupWebdavSetting());
          },
          actionTitle: 'Set'.tl,
        ).toSliver(),
        CallbackSetting(
          title: "WebDAV Comic Library".tl,
          subtitle:
              "Online reading uses directory image structure only; CBZ is kept for archive backup and restore."
                  .tl,
          callback: () async {
            showPopUpWidget(context, const _WebDavComicLibrarySetting());
          },
          actionTitle: 'Set'.tl,
        ).toSliver(),
        SettingPartTitle(title: "User".tl, icon: Icons.person_outline),
        SelectSetting(
          title: "Language".tl,
          settingKey: "language",
          optionTranslation: const {
            "system": "System",
            "zh-CN": "简体中文",
            "zh-TW": "繁體中文",
            "en-US": "English",
          },
          onChanged: () {
            App.forceRebuild();
          },
        ).toSliver(),
        if (!App.isLinux)
          SwitchSetting(
            title: "Authorization Required".tl,
            settingKey: "authorizationRequired",
            onChanged: () async {
              var current = appdata.settings['authorizationRequired'];
              if (current) {
                final auth = LocalAuthentication();
                final bool canAuthenticateWithBiometrics =
                    await auth.canCheckBiometrics;
                final bool canAuthenticate =
                    canAuthenticateWithBiometrics ||
                    await auth.isDeviceSupported();
                if (!canAuthenticate) {
                  context.showMessage(message: "Biometrics not supported".tl);
                  setState(() {
                    appdata.settings['authorizationRequired'] = false;
                  });
                  appdata.saveData();
                  return;
                }
              }
            },
          ).toSliver(),
      ],
    );
  }
}

class _WebdavSetting extends StatefulWidget {
  const _WebdavSetting();

  @override
  State<_WebdavSetting> createState() => _WebdavSettingState();
}

class _WebdavSettingState extends State<_WebdavSetting> {
  String url = "";
  String user = "";
  String pass = "";
  String disableSync = "";

  bool autoSync = true;

  bool isTesting = false;
  bool upload = true;

  @override
  void initState() {
    super.initState();
    if (appdata.settings['webdav'] is! List) {
      appdata.settings['webdav'] = [];
    }
    if (appdata.settings['disableSyncFields'].trim().isNotEmpty) {
      disableSync = appdata.settings['disableSyncFields'];
    }
    var configs = appdata.settings['webdav'] as List;
    if (configs.whereType<String>().length != 3) {
      return;
    }
    url = configs[0];
    user = configs[1];
    pass = configs[2];
    autoSync = appdata.implicitData['webdavAutoSync'] ?? true;
  }

  void onAutoSyncChanged(bool value) {
    setState(() {
      autoSync = value;
      appdata.implicitData['webdavAutoSync'] = value;
      appdata.writeImplicitData();
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Webdav",
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: "URL",
                hintText: "A valid WebDav directory URL".tl,
                border: OutlineInputBorder(),
              ),
              controller: TextEditingController(text: url),
              onChanged: (value) => url = value,
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: "Username".tl,
                border: const OutlineInputBorder(),
              ),
              controller: TextEditingController(text: user),
              onChanged: (value) => user = value,
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: "Password".tl,
                border: const OutlineInputBorder(),
              ),
              controller: TextEditingController(text: pass),
              onChanged: (value) => pass = value,
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: "Skip Setting Fields (Optional)".tl,
                hintText: "field0, field1, field2, ...",
                hintStyle: TextStyle(color: Theme.of(context).hintColor),
                border: OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(Icons.help_outline),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: Text("Skip Setting Fields".tl),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "When sync data, skip certain setting fields, which means these won't be uploaded / override."
                                  .tl,
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    "See source code for available fields.".tl,
                                  ),
                                ),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: IconButton(
                                    icon: const Icon(Icons.open_in_new),
                                    onPressed: () {
                                      launchUrlString(
                                        "https://github.com/CyrilPeng/venera-next/blob/main/lib/foundation/appdata.dart#L138",
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              controller: TextEditingController(text: disableSync),
              onChanged: (value) => disableSync = value,
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: Icon(Icons.sync),
              title: Text("Auto Sync Data".tl),
              contentPadding: EdgeInsets.zero,
              trailing: Switch(value: autoSync, onChanged: onAutoSyncChanged),
            ),
            const SizedBox(height: 12),
            RadioGroup<bool>(
              groupValue: upload,
              onChanged: (value) {
                setState(() {
                  upload = value ?? upload;
                });
              },
              child: Row(
                children: [
                  Text("Operation".tl),
                  Radio<bool>(value: true),
                  Text("Upload".tl),
                  Radio<bool>(value: false),
                  Text("Download".tl),
                ],
              ),
            ),
            const SizedBox(height: 16),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              child: autoSync
                  ? Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              "Once the operation is successful, app will automatically sync data with the server."
                                  .tl,
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Button.outlined(
                    isLoading: isTesting,
                    onPressed: testConnection,
                    child: Text("Test Connection".tl),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Center(
              child: Button.filled(
                isLoading: isTesting,
                onPressed: () async {
                  var oldConfig = appdata.settings['webdav'];
                  var oldAutoSync = appdata.implicitData['webdavAutoSync'];

                  if (url.trim().isEmpty &&
                      user.trim().isEmpty &&
                      pass.trim().isEmpty) {
                    appdata.settings['webdav'] = [];
                    appdata.implicitData['webdavAutoSync'] = false;
                    appdata.writeImplicitData();
                    appdata.saveData();
                    context.showMessage(message: "Saved".tl);
                    App.rootPop();
                    return;
                  }

                  appdata.settings['webdav'] = [url, user, pass];
                  appdata.settings['disableSyncFields'] = disableSync;
                  appdata.implicitData['webdavAutoSync'] = autoSync;
                  appdata.writeImplicitData();

                  if (!autoSync) {
                    appdata.saveData();
                    context.showMessage(message: "Saved".tl);
                    App.rootPop();
                    return;
                  }

                  setState(() {
                    isTesting = true;
                  });
                  var testResult = upload
                      ? await DataSync().uploadData()
                      : await DataSync().downloadData();
                  if (testResult.error) {
                    setState(() {
                      isTesting = false;
                    });
                    appdata.settings['webdav'] = oldConfig;
                    appdata.implicitData['webdavAutoSync'] = oldAutoSync;
                    appdata.writeImplicitData();
                    appdata.saveData();
                    context.showMessage(message: testResult.errorMessage!);
                    context.showMessage(message: "Saved Failed".tl);
                  } else {
                    appdata.saveData();
                    context.showMessage(message: "Saved".tl);
                    App.rootPop();
                  }
                },
                child: Text("Continue".tl),
              ),
            ),
          ],
        ).paddingHorizontal(16),
      ),
    );
  }

  BackupConfig get currentConfig =>
      BackupConfig(url: url, user: user, pass: pass, remotePath: '/');

  Future<void> testConnection() async {
    if (isTesting) return;
    setState(() {
      isTesting = true;
    });
    final result = await ComicBackupManager.testConnection(currentConfig);
    if (!mounted) return;
    setState(() {
      isTesting = false;
    });
    if (result.error) {
      context.showMessage(message: result.errorMessage!.tl);
    } else {
      context.showMessage(message: "Connection successful".tl);
    }
  }
}

class _BackupWebdavSetting extends StatefulWidget {
  const _BackupWebdavSetting();

  @override
  State<_BackupWebdavSetting> createState() => _BackupWebdavSettingState();
}

class _BackupWebdavSettingState extends State<_BackupWebdavSetting> {
  late final WebDavConnectionControllers _connectionControllers;
  bool syncEnabled = false;
  bool isTesting = false;

  @override
  void initState() {
    super.initState();
    final config = BackupConfig.fromSettings();
    _connectionControllers = WebDavConnectionControllers(
      url: config.url,
      user: config.user,
      password: config.pass,
      remotePath: config.remotePath,
    );
    syncEnabled = appdata.settings['backupWebdavSyncEnabled'] == true;
  }

  @override
  void dispose() {
    _connectionControllers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Comic Archive Backup".tl,
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 12),
            WebDavConnectionFields(
              controllers: _connectionControllers,
              remotePathHint: '/venera_backup/',
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "This is only used for CBZ archive backup and restore."
                          .tl,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: Icon(Icons.sync),
              title: Text("Sync archive config".tl),
              subtitle: Text(
                "Sync archive WebDAV URL, username, password and remote path with app data."
                    .tl,
              ),
              trailing: Switch(
                value: syncEnabled,
                onChanged: (v) {
                  setState(() {
                    syncEnabled = v;
                  });
                },
              ),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Button.outlined(
                    isLoading: isTesting,
                    onPressed: testConnection,
                    child: Text("Test Connection".tl),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Button.filled(
                    isLoading: isTesting,
                    onPressed: save,
                    child: Text("Continue".tl),
                  ),
                ),
              ],
            ),
          ],
        ).paddingHorizontal(16),
      ),
    );
  }

  BackupConfig get currentConfig => BackupConfig(
    url: _connectionControllers.url.text,
    user: _connectionControllers.user.text,
    pass: _connectionControllers.password.text,
    remotePath: _connectionControllers.remotePath.text,
  );

  Future<void> testConnection() async {
    if (isTesting) return;
    setState(() {
      isTesting = true;
    });
    final result = await ComicBackupManager.testConnection(currentConfig);
    if (!mounted) return;
    setState(() {
      isTesting = false;
    });
    if (result.error) {
      context.showMessage(message: result.errorMessage!.tl);
    } else {
      context.showMessage(message: "Connection successful".tl);
    }
  }

  Future<void> save() async {
    if (isTesting) return;
    appdata.settings['backupWebdavSyncEnabled'] = syncEnabled;
    final config = currentConfig;
    if (!config.isValid && config.user.trim().isEmpty && config.pass.isEmpty) {
      await BackupConfig.saveToSettings(config);
      if (!mounted) return;
      context.showMessage(message: "Saved".tl);
      App.rootPop();
      return;
    }
    setState(() {
      isTesting = true;
    });
    final result = await ComicBackupManager.testConnection(config);
    if (!mounted) return;
    setState(() {
      isTesting = false;
    });
    if (result.error) {
      context.showMessage(message: result.errorMessage!);
      context.showMessage(message: "Saved Failed".tl);
    } else {
      await BackupConfig.saveToSettings(config);
      if (!mounted) return;
      context.showMessage(message: "Saved".tl);
      App.rootPop();
    }
  }
}

class _WebDavComicLibrarySetting extends StatefulWidget {
  const _WebDavComicLibrarySetting();

  @override
  State<_WebDavComicLibrarySetting> createState() =>
      _WebDavComicLibrarySettingState();
}

class _WebDavComicLibrarySettingState
    extends State<_WebDavComicLibrarySetting> {
  late final WebDavConnectionControllers _connectionControllers;
  bool isTesting = false;
  bool isSyncing = false;
  late bool autoSyncEnabled;
  late int syncIntervalMinutes;

  @override
  void initState() {
    super.initState();
    final config = WebDavLibraryConfig.fromSettings();
    _connectionControllers = WebDavConnectionControllers(
      url: config.url,
      user: config.user,
      password: config.pass,
      remotePath: config.remotePath,
    );
    WebDavLibrarySource.updateSyncStatusFromCache();
    autoSyncEnabled =
        appdata.settings['webdavComicLibraryAutoSync'] as bool? ?? true;
    syncIntervalMinutes =
        (appdata.settings['webdavComicLibrarySyncIntervalMinutes'] as num?)
            ?.round() ??
        360;
  }

  @override
  void dispose() {
    _connectionControllers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "WebDAV Comic Library".tl,
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 12),
            WebDavConnectionFields(
              controllers: _connectionControllers,
              remotePathHint: '/venera_comics/',
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Online reading uses directory image structure only; CBZ is kept for archive backup and restore."
                          .tl,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Automatic library updates'.tl),
              subtitle: Text(
                'Refresh the cached WebDAV library while the app is running.'
                    .tl,
              ),
              value: autoSyncEnabled,
              onChanged: (value) {
                setState(() {
                  autoSyncEnabled = value;
                });
              },
            ),
            if (autoSyncEnabled) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                initialValue: syncIntervalMinutes,
                decoration: InputDecoration(
                  labelText: 'Update interval'.tl,
                  border: const OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem(
                    value: 15,
                    child: Text('Every 15 minutes'.tl),
                  ),
                  DropdownMenuItem(value: 60, child: Text('Every hour'.tl)),
                  DropdownMenuItem(value: 360, child: Text('Every 6 hours'.tl)),
                  DropdownMenuItem(value: 1440, child: Text('Every day'.tl)),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      syncIntervalMinutes = value;
                    });
                  }
                },
              ),
            ],
            const SizedBox(height: 16),
            ValueListenableBuilder<WebDavLibrarySyncStatus>(
              valueListenable: WebDavLibrarySource.syncStatus,
              builder: (context, status, _) {
                final text = switch (status) {
                  WebDavLibrarySyncStatus(isSyncing: true, total: > 0) =>
                    'Updating WebDAV library: @current/@total'.tlParams({
                      'current': status.processed,
                      'total': status.total,
                    }),
                  WebDavLibrarySyncStatus(isSyncing: true) =>
                    'Updating WebDAV library'.tl,
                  WebDavLibrarySyncStatus(errorMessage: != null) =>
                    'Last sync failed'.tl,
                  WebDavLibrarySyncStatus(lastSuccessfulSync: > 0) =>
                    '${'Last synced'.tl}: '
                        '${status.formattedLastSuccessfulSync}',
                  _ => 'Not synced yet'.tl,
                };
                return Row(
                  children: [
                    Icon(
                      status.errorMessage == null
                          ? Icons.sync_outlined
                          : Icons.sync_problem_outlined,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(text)),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Button.outlined(
                    isLoading: isTesting,
                    onPressed: testConnection,
                    child: Text("Test Connection".tl),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (WebDavLibraryConfig.fromSettings().isValid) ...[
              Row(
                children: [
                  Expanded(
                    child: Button.outlined(
                      isLoading: isSyncing,
                      onPressed: syncNow,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.sync, size: 18),
                          const SizedBox(width: 8),
                          Text('Sync now'.tl),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  child: Button.filled(
                    isLoading: isTesting && !isSyncing,
                    onPressed: save,
                    child: Text('Save and sync'.tl),
                  ),
                ),
              ],
            ),
          ],
        ).paddingHorizontal(16),
      ),
    );
  }

  WebDavLibraryConfig get currentConfig => WebDavLibraryConfig(
    url: _connectionControllers.url.text,
    user: _connectionControllers.user.text,
    pass: _connectionControllers.password.text,
    remotePath: _connectionControllers.remotePath.text,
  );

  Future<void> testConnection() async {
    if (isTesting || isSyncing) return;
    setState(() {
      isTesting = true;
    });
    final result = await WebDavLibrarySource.testConnection(currentConfig);
    if (!mounted) return;
    setState(() {
      isTesting = false;
    });
    if (result.error) {
      context.showMessage(message: result.errorMessage!.tl);
    } else {
      context.showMessage(message: "Connection successful".tl);
    }
  }

  Future<void> save() async {
    if (isTesting || isSyncing) return;
    if (!await _persistConfiguration()) return;
    final config = WebDavLibraryConfig.fromSettings();
    if (config.isValid) {
      unawaited(WebDavLibrarySource.synchronize(force: true));
    }
    if (!mounted) return;
    context.showMessage(message: 'Saved'.tl);
    App.rootPop();
  }

  Future<void> syncNow() async {
    if (isTesting || isSyncing) return;
    if (!await _persistConfiguration()) return;
    if (!WebDavLibraryConfig.fromSettings().isValid) return;
    setState(() {
      isSyncing = true;
    });
    final result = await WebDavLibrarySource.synchronize(force: true);
    if (!mounted) return;
    setState(() {
      isSyncing = false;
    });
    if (result.error) {
      context.showMessage(message: result.errorMessage!);
    } else {
      context.showMessage(message: 'WebDAV library updated'.tl);
    }
  }

  Future<bool> _persistConfiguration() async {
    final config = currentConfig;
    appdata.settings['webdavComicLibraryAutoSync'] = autoSyncEnabled;
    appdata.settings['webdavComicLibrarySyncIntervalMinutes'] =
        syncIntervalMinutes;
    if (!config.isValid && config.user.isEmpty && config.pass.isEmpty) {
      await WebDavLibraryConfig.saveToSettings(config);
      _refreshWebDavLibrarySource(enabled: false);
      return true;
    }
    setState(() {
      isTesting = true;
    });
    final result = await WebDavLibrarySource.testConnection(config);
    if (!mounted) return false;
    setState(() {
      isTesting = false;
    });
    if (result.error) {
      context.showMessage(message: result.errorMessage!);
      context.showMessage(message: "Saved Failed".tl);
      return false;
    } else {
      await WebDavLibraryConfig.saveToSettings(config);
      _refreshWebDavLibrarySource(enabled: true);
      return true;
    }
  }

  void _refreshWebDavLibrarySource({required bool enabled}) {
    final manager = ComicSourceManager();
    manager.remove(WebDavLibrarySource.sourceKey);
    final pages = List<String>.from(appdata.settings['explore_pages']);
    pages.remove(WebDavLibrarySource.explorePageTitle);
    if (enabled) {
      manager.add(WebDavLibrarySource.create());
      pages.add(WebDavLibrarySource.explorePageTitle);
    }
    appdata.settings['explore_pages'] = pages;
    appdata.saveData(false);
  }
}
