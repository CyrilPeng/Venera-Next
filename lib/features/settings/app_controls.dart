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
