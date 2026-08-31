import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/features/bangumi/bangumi_api.dart';
import 'package:venera_next/features/bangumi/bangumi_service.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

Future<void> _saveBangumiSettings() => appdata.saveData();

class BangumiSettingsPage extends StatefulWidget {
  const BangumiSettingsPage({
    super.key,
    this.service,
    this.saveSettings = _saveBangumiSettings,
    this.launchTokenPage = _launchTokenPage,
    this.onConnectionChanged,
  });

  final BangumiService? service;
  final Future<void> Function() saveSettings;
  final Future<bool> Function(Uri uri) launchTokenPage;
  final VoidCallback? onConnectionChanged;

  static Future<bool> _launchTokenPage(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  @override
  State<BangumiSettingsPage> createState() => _BangumiSettingsPageState();
}

class _BangumiSettingsPageState extends State<BangumiSettingsPage> {
  late final TextEditingController _tokenController;
  late bool _autoSyncEnabled;
  bool _isConnecting = false;
  bool _isSavingAutoSync = false;
  late bool _connectionInvalid;
  String? _errorMessage;

  BangumiService get _service => widget.service ?? BangumiService();

  @override
  void initState() {
    super.initState();
    _tokenController = TextEditingController(
      text: _settingString('bangumiAccessToken'),
    );
    _autoSyncEnabled = _settingBool('bangumiAutoSyncEnabled', true);
    _connectionInvalid = _service.isAuthenticationPaused;
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final username = _settingString('bangumiUsername');
    return PopUpWidgetScaffold(
      title: 'Bangumi',
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 12),
            TextField(
              key: const Key('bangumi-token-field'),
              controller: _tokenController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Bangumi Access Token'.tl,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Button.outlined(
                    key: const Key('bangumi-apply-token'),
                    onPressed: _applyForToken,
                    child: Text('Apply for Access Token'.tl),
                  ),
                ),
              ],
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
                      'Your Access Token and Bangumi bindings are included in WebDAV app data sync.'
                          .tl,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Automatically sync after completing a chapter'.tl),
              value: _autoSyncEnabled,
              onChanged: _isSavingAutoSync ? null : _setAutoSyncEnabled,
            ),
            if (_connectionInvalid && _errorMessage == null) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Bangumi connection is invalid. Please check your Access Token.'
                      .tl,
                ),
              ),
            ],
            if (_errorMessage != null) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(_errorMessage!),
              ),
            ],
            if (username.isNotEmpty && !_connectionInvalid) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Text('${'Connected as'.tl}: '),
                    Expanded(
                      child: Text(username, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Button.filled(
                    key: const Key('bangumi-connect'),
                    isLoading: _isConnecting,
                    onPressed: _connect,
                    child: Text(
                      username.isEmpty ? 'Connect'.tl : 'Verify connection'.tl,
                    ),
                  ),
                ),
              ],
            ),
            if (username.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Button.outlined(
                      key: const Key('bangumi-disconnect'),
                      isLoading: _isConnecting,
                      onPressed: _disconnect,
                      child: Text('Disconnect'.tl),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ).paddingHorizontal(16),
      ),
    );
  }

  Future<void> _connect() async {
    if (_isConnecting) return;
    if (_tokenController.text.trim().isEmpty) {
      setState(() => _errorMessage = 'Access Token cannot be empty'.tl);
      return;
    }
    setState(() => _isConnecting = true);
    try {
      await _service.connect(_tokenController.text.trim());
      widget.onConnectionChanged?.call();
      if (mounted) {
        setState(() {
          _connectionInvalid = false;
          _errorMessage = null;
        });
      }
    } catch (error) {
      if (!mounted) return;
      if (error is BangumiApiException &&
          (error.statusCode == 401 || error.statusCode == 403)) {
        setState(() {
          _connectionInvalid = true;
          _errorMessage =
              'Bangumi connection is invalid. Please check your Access Token.'
                  .tl;
        });
      } else {
        setState(() {
          _errorMessage = '${'Failed to connect to Bangumi'.tl}: $error';
        });
      }
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  Future<void> _applyForToken() async {
    try {
      final launched = await widget.launchTokenPage(
        Uri.parse('https://next.bgm.tv/demo/access-token'),
      );
      if (!launched && mounted) {
        setState(() => _errorMessage = 'Failed to open Access Token page'.tl);
      } else if (launched && mounted) {
        setState(() => _errorMessage = null);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _errorMessage = 'Failed to open Access Token page'.tl);
      }
    }
  }

  Future<void> _setAutoSyncEnabled(bool value) async {
    if (_isSavingAutoSync) return;
    final previous = _autoSyncEnabled;
    setState(() {
      _autoSyncEnabled = value;
      _isSavingAutoSync = true;
    });
    appdata.settings['bangumiAutoSyncEnabled'] = value;
    try {
      await widget.saveSettings();
      if (mounted) setState(() => _errorMessage = null);
    } catch (error) {
      appdata.settings['bangumiAutoSyncEnabled'] = previous;
      if (mounted) {
        setState(() {
          _autoSyncEnabled = previous;
          _errorMessage = '${'Failed to save Bangumi settings'.tl}: $error';
        });
      }
    } finally {
      if (mounted) setState(() => _isSavingAutoSync = false);
    }
  }

  String _settingString(String key) {
    final value = appdata.settings[key];
    return value is String ? value : '';
  }

  bool _settingBool(String key, bool fallback) {
    final value = appdata.settings[key];
    return value is bool ? value : fallback;
  }

  Future<void> _disconnect() async {
    if (_isConnecting) return;
    setState(() => _isConnecting = true);
    try {
      await _service.disconnect();
      widget.onConnectionChanged?.call();
      if (!mounted) return;
      _tokenController.clear();
      setState(() {
        _connectionInvalid = false;
        _errorMessage = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = '${'Failed to disconnect from Bangumi'.tl}: $error';
        });
      }
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }
}
