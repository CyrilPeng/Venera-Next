import 'package:venera_next/features/history/history_scope.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';

/// Preview while dragging; only the released choice authorizes cleanup.
class HistoryRetentionSetting extends StatefulWidget {
  const HistoryRetentionSetting({super.key});
  @override
  State<HistoryRetentionSetting> createState() =>
      _HistoryRetentionSettingState();
}

class _HistoryRetentionSettingState
    extends SettingsSaveState<HistoryRetentionSetting> {
  double? _preview;
  Object? _selection;

  @override
  void initState() {
    super.initState();
    appdata.settings.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _previewDays(double value) {
    if (!acceptsSettingsChanges || savingSettings || hasSettingsSaveError) {
      return;
    }
    setState(() => _preview = value);
  }

  Future<void> _save(double value) async {
    if (!acceptsSettingsChanges || savingSettings || hasSettingsSaveError) {
      return;
    }
    final manager = HistoryScope.read(context);
    final request = manager.createRetentionChange(value.round());
    _selection = request;
    await saveSetting(
      (
        AppPreferences.historyRetentionDays.key,
        manager,
        manager.connectionGeneration,
      ),
      request.run,
      isCurrent: () => identical(_selection, request),
      onSaved: () => _preview = null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final value =
        _preview ??
        GlobalPreferenceStore(
          appdata.settings,
        ).read(AppPreferences.historyRetentionDays).toDouble();
    final enabled =
        acceptsSettingsChanges && !savingSettings && !hasSettingsSaveError;
    return protectSettings(
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            title: Text('Auto Clear History'.tl, softWrap: true, maxLines: 2),
            trailing: Text(
              value.toString(),
              style: const TextStyle(fontSize: 12),
            ),
            subtitle: Slider(
              value: value.clamp(0, AppPreferences.historyRetentionEditorMax),
              min: 0,
              max: AppPreferences.historyRetentionEditorMax,
              divisions:
                  (AppPreferences.historyRetentionEditorMax /
                          AppPreferences.historyRetentionEditorStep)
                      .toInt(),
              onChanged: enabled ? _previewDays : null,
              onChangeEnd: enabled ? _save : null,
            ),
          ),
          if (hasSettingsSaveError)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: settingsSaveStatus,
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_refresh);
    super.dispose();
  }
}

class CacheLimitSetting extends StatelessWidget {
  const CacheLimitSetting({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appdata.settings,
    builder: (context, _) => CallbackSetting(
      title: 'Cache Limit'.tl,
      subtitle:
          '${GlobalPreferenceStore(appdata.settings).read(AppPreferences.cacheSize).toInt()} MB',
      actionTitle: 'Set'.tl,
      callback: () => showDialog<void>(
        context: context,
        builder: (_) => const _CacheLimitDialog(),
      ),
    ),
  );
}

class _CacheLimitDialog extends StatefulWidget {
  const _CacheLimitDialog();
  @override
  State<_CacheLimitDialog> createState() => _CacheLimitDialogState();
}

class _CacheLimitDialogState extends SettingsSaveState<_CacheLimitDialog> {
  late final _controller = TextEditingController(
    text: GlobalPreferenceStore(
      appdata.settings,
    ).read(AppPreferences.cacheSize).toInt().toString(),
  );
  String? _error;

  void _confirm() {
    if (!acceptsSettingsChanges || savingSettings || hasSettingsSaveError) {
      return;
    }
    final text = _controller.text;
    final value = int.tryParse(text);
    if (!RegExp(r'^\d+$').hasMatch(text) ||
        value == null ||
        value > AppPreferences.maxCacheSizeMb) {
      setState(() => _error = 'Invalid input'.tl);
      return;
    }
    saveSetting(
      AppPreferences.cacheSize.key,
      () => appdata.updateSettings((draft) {
        GlobalPreferenceStore(draft).write(AppPreferences.cacheSize, value);
      }),
      onSaved: () => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) leaveSettings();
      }),
    );
  }

  @override
  Widget build(BuildContext context) => protectSettings(
    ContentDialog(
      title: 'Set Cache Limit'.tl,
      content: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: TextField(
          controller: _controller,
          enabled: !savingSettings && !hasSettingsSaveError,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: 'Size in MB'.tl,
            errorText: _error,
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
      ),
      actions: [
        settingsSaveStatus,
        FilledButton(
          onPressed: savingSettings || hasSettingsSaveError ? null : _confirm,
          child: Text('Confirm'.tl),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

Future<bool> _supportsAuthorization() async {
  final auth = LocalAuthentication();
  return await auth.canCheckBiometrics || await auth.isDeviceSupported();
}

class AuthorizationRequiredSetting extends StatefulWidget {
  const AuthorizationRequiredSetting({
    super.key,
    this.checkSupport = _supportsAuthorization,
  });
  final Future<bool> Function() checkSupport;
  @override
  State<AuthorizationRequiredSetting> createState() =>
      _AuthorizationRequiredSettingState();
}

class _AuthorizationRequiredSettingState
    extends SettingsSaveState<AuthorizationRequiredSetting> {
  int _request = 0;
  bool? _preview;

  @override
  void initState() {
    super.initState();
    appdata.settings.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(AuthorizationRequiredSetting oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.checkSupport != widget.checkSupport) {
      _request++;
      _preview = null;
    }
  }

  Future<void> _change(bool value) async {
    if (!acceptsSettingsChanges) return;
    final request = ++_request;
    final checkSupport = widget.checkSupport;
    Future<bool>? checked;
    var supported = true;
    setState(() => _preview = value);
    await saveSetting(
      AppPreferences.authorizationRequired.key,
      () async {
        if (value) {
          // A retry reuses this request's completed read-only support check.
          checked ??= Future<bool>.sync(checkSupport).catchError((
            Object error,
            StackTrace stack,
          ) {
            Log.error('Authorization support', error, stack);
            return false;
          });
          supported = await checked!;
        }
        if (request != _request) return;
        await appdata.updateSettings((draft) {
          if (request != _request) return;
          GlobalPreferenceStore(
            draft,
          ).write(AppPreferences.authorizationRequired, value && supported);
        });
      },
      isCurrent: () => request == _request,
      onSaved: () {
        if (value && !supported) {
          context.showMessage(message: 'Biometrics not supported'.tl);
        }
      },
    );
    if (request == _request) _preview = null;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => protectSettings(
    Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          title: Text('Authorization Required'.tl),
          value:
              _preview ??
              GlobalPreferenceStore(
                appdata.settings,
              ).read(AppPreferences.authorizationRequired),
          onChanged: _change,
        ),
        settingsSaveStatus,
      ],
    ),
  );

  @override
  void dispose() {
    appdata.settings.removeListener(_refresh);
    super.dispose();
  }
}
