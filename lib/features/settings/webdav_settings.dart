import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/features/webdav_library/webdav_library.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

import 'webdav_connection_fields.dart';

class BackupWebdavSetting extends StatefulWidget {
  const BackupWebdavSetting({super.key, this.testConnection});
  final Future<Res<bool>> Function(BackupConfig)? testConnection;

  @override
  State<BackupWebdavSetting> createState() => _BackupWebdavSettingState();
}

class _BackupWebdavSettingState extends SettingsSaveState<BackupWebdavSetting> {
  late final WebDavConnectionControllers _connectionControllers;
  bool syncEnabled = false;
  bool get busy => savingSettings || hasSettingsSaveError;
  String? _result;
  int _request = 0;

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
    syncEnabled = BackupConfig.syncEnabled;
  }

  @override
  void didUpdateWidget(BackupWebdavSetting oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.testConnection != widget.testConnection) _request++;
  }

  @override
  void dispose() {
    _connectionControllers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return protectSettings(
      PopUpWidgetScaffold(
        onBack: leaveSettings,
        title: "Comic Archive Backup".tl,
        body: SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: 12),
              settingsSaveStatus,
              if (_result != null) Text(_result!),
              WebDavConnectionFields(
                controllers: _connectionControllers,
                enabled: !busy,
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
                  onChanged: busy
                      ? null
                      : (v) {
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
                    child: OutlinedButton(
                      onPressed: busy ? null : testConnection,
                      child: Text("Test Connection".tl),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: busy ? null : save,
                      child: Text("Continue".tl),
                    ),
                  ),
                ],
              ),
            ],
          ).paddingHorizontal(16),
        ),
      ),
    );
  }

  BackupConfig get currentConfig => BackupConfig(
    url: _connectionControllers.url.text,
    user: _connectionControllers.user.text,
    pass: _connectionControllers.password.text,
    remotePath: _connectionControllers.remotePath.text,
  );

  Future<void> testConnection() => _submit(testOnly: true);

  Future<void> save() => _submit(testOnly: false);

  Future<void> _submit({required bool testOnly}) async {
    if (!acceptsSettingsChanges || busy) return;
    final config = currentConfig;
    final sync = syncEnabled;
    final check =
        widget.testConnection ?? ComicBackupManager.instance.testConnection;
    final request = _request;
    Future<Res<bool>>? checked;
    Res<bool>? result;
    _result = null;
    await saveSetting(
      'backup-webdav',
      () async {
        if (request != _request) return;
        if (testOnly ||
            config.isValid ||
            config.user.isNotEmpty ||
            config.pass.isNotEmpty) {
          checked ??= Future<Res<bool>>.sync(() => check(config)).catchError(
            (Object error, StackTrace stack) =>
                Res<bool>.fromException(error, stack),
          );
          result = await checked!;
          if (result!.error) return;
        }
        if (testOnly || request != _request) return;
        await BackupConfig.saveToSettings(config, syncEnabled: sync);
      },
      isCurrent: () => request == _request,
      onSaved: () {
        _result = result?.error == true
            ? result!.errorMessage!.tl
            : testOnly
            ? 'Connection successful'.tl
            : 'Saved'.tl;
        if (!testOnly && result?.error != true) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && request == _request) unawaited(leaveSettings());
          });
        }
      },
    );
  }
}

class WebDavComicLibrarySetting extends StatefulWidget {
  const WebDavComicLibrarySetting(this.services, {super.key});

  final WebDavLibraryServices services;

  @override
  State<WebDavComicLibrarySetting> createState() =>
      _WebDavComicLibrarySettingState();
}

class _WebDavComicLibrarySettingState
    extends SettingsSaveState<WebDavComicLibrarySetting> {
  late WebDavConnectionControllers _connectionControllers;
  bool get busy => savingSettings || hasSettingsSaveError;
  String? _result;
  int _request = 0;
  bool isSyncing = false;
  late bool autoSyncEnabled;
  late int syncIntervalMinutes;

  @override
  void initState() {
    super.initState();
    _loadConfiguration();
  }

  @override
  void didUpdateWidget(WebDavComicLibrarySetting oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.services, widget.services)) {
      _request++;
      _connectionControllers.dispose();
      _result = null;
      _loadConfiguration();
    }
  }

  void _loadConfiguration() {
    final config = widget.services.settings.read().connection;
    _connectionControllers = WebDavConnectionControllers(
      url: config.url,
      user: config.user,
      password: config.pass,
      remotePath: config.remotePath,
    );
    widget.services.source.synchronizer.updateSyncStatusFromCache();
    final configuration = widget.services.settings.read();
    autoSyncEnabled = configuration.autoSync;
    syncIntervalMinutes = configuration.intervalMinutes;
  }

  @override
  void dispose() {
    _connectionControllers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return protectSettings(
      PopUpWidgetScaffold(
        onBack: leaveSettings,
        title: "WebDAV Comic Library".tl,
        body: SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: 12),
              settingsSaveStatus,
              if (isSyncing) Text('Updating WebDAV library'.tl),
              if (_result != null) Text(_result!),
              WebDavConnectionFields(
                controllers: _connectionControllers,
                enabled: !busy,
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
                onChanged: busy
                    ? null
                    : (value) {
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
                    if (![15, 60, 360, 1440].contains(syncIntervalMinutes))
                      DropdownMenuItem(
                        value: syncIntervalMinutes,
                        child: Text(
                          '@minutes min'.tlParams({
                            'minutes': '$syncIntervalMinutes',
                          }),
                        ),
                      ),
                    DropdownMenuItem(
                      value: 15,
                      child: Text('Every 15 minutes'.tl),
                    ),
                    DropdownMenuItem(value: 60, child: Text('Every hour'.tl)),
                    DropdownMenuItem(
                      value: 360,
                      child: Text('Every 6 hours'.tl),
                    ),
                    DropdownMenuItem(value: 1440, child: Text('Every day'.tl)),
                  ],
                  onChanged: busy
                      ? null
                      : (value) {
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
                valueListenable: widget.services.source.synchronizer.status,
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
                    child: OutlinedButton(
                      onPressed: busy ? null : testConnection,
                      child: Text("Test Connection".tl),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (widget.services.settings.read().connection.isValid) ...[
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: busy ? null : syncNow,
                        icon: const Icon(Icons.sync, size: 18),
                        label: Text('Sync now'.tl, textAlign: TextAlign.center),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: busy ? null : save,
                      child: Text('Save and sync'.tl),
                    ),
                  ),
                ],
              ),
            ],
          ).paddingHorizontal(16),
        ),
      ),
    );
  }

  WebDavLibraryConfig get currentConfig => WebDavLibraryConfig(
    url: _connectionControllers.url.text,
    user: _connectionControllers.user.text,
    pass: _connectionControllers.password.text,
    remotePath: _connectionControllers.remotePath.text,
  );

  Future<void> testConnection() => _submit(testOnly: true, closeAfter: false);

  Future<void> save() => _submit(testOnly: false, closeAfter: true);

  Future<void> syncNow() => _submit(testOnly: false, closeAfter: false);

  Future<void> _submit({
    required bool testOnly,
    required bool closeAfter,
  }) async {
    if (!acceptsSettingsChanges || busy) return;
    final services = widget.services;
    final config = currentConfig;
    final configuration = WebDavLibrarySettings(
      connection: config,
      autoSync: autoSyncEnabled,
      intervalMinutes: syncIntervalMinutes,
    );
    final request = _request;
    Future<Res<bool>>? checked;
    Res<bool>? connectionResult;
    Res<bool>? syncResult;
    _result = null;
    await saveSetting(
      'webdav-library',
      () async {
        if (request != _request) return;
        if (testOnly ||
            config.isValid ||
            config.user.isNotEmpty ||
            config.pass.isNotEmpty) {
          checked ??=
              Future<Res<bool>>.sync(
                () => services.source.testConnection(config),
              ).catchError(
                (Object error, StackTrace stack) =>
                    Res<bool>.fromException(error, stack),
              );
          connectionResult = await checked!;
          if (connectionResult!.error) return;
        }
        if (testOnly || request != _request) return;
        await services.settings.save(configuration);
        if (mounted &&
            request == _request &&
            acceptsSettingsChanges &&
            !services.source.isDisposed &&
            config.isValid &&
            services.settings.read().connection.connectionKey ==
                config.connectionKey &&
            NavigationAdmission.allows(context)) {
          setState(() => isSyncing = true);
          try {
            syncResult = await services.source.synchronizer.synchronize(
              force: true,
            );
          } catch (error, stack) {
            syncResult = Res<bool>.fromException(error, stack);
          } finally {
            if (mounted) setState(() => isSyncing = false);
          }
        }
      },
      isCurrent: () => request == _request,
      onSaved: () {
        _result = connectionResult?.error == true
            ? connectionResult!.errorMessage!.tl
            : syncResult?.error == true
            ? syncResult!.errorMessage!.tl
            : testOnly
            ? 'Connection successful'.tl
            : closeAfter
            ? 'Saved'.tl
            : 'WebDAV library updated'.tl;
        if (closeAfter &&
            connectionResult?.error != true &&
            syncResult?.error != true) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && request == _request) unawaited(leaveSettings());
          });
        }
      },
    );
  }
}
