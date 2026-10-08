import 'package:venera_next/foundation/proxy_configuration.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

final _networkSettings = GlobalPreferenceStore(appdata.settings);

class NetworkSettings extends StatefulWidget {
  const NetworkSettings({super.key});

  @override
  State<NetworkSettings> createState() => _NetworkSettingsState();
}

class _NetworkSettingsState extends State<NetworkSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Network".tl)),
        PopupWindowSetting(
          title: "Proxy".tl,
          builder: () => const _ProxySettingView(),
        ).toSliver(),
        PopupWindowSetting(
          title: "DNS Overrides".tl,
          builder: () => const _DNSOverrides(),
        ).toSliver(),
        SliderSetting.preference(
          title: "Download Threads".tl,
          preference: NetworkPreferences.downloadThreads,
        ).toSliver(),
      ],
    );
  }
}

class _ProxySettingView extends StatefulWidget {
  const _ProxySettingView();

  @override
  State<_ProxySettingView> createState() => _ProxySettingViewState();
}

class _ProxySettingViewState extends SettingsSaveState<_ProxySettingView> {
  late ProxyConfiguration configuration;
  int _selection = 0;

  Future<bool> _saveProxy(String value) => saveSetting(
    'proxy',
    () => appdata.updateSettings((draft) {
      GlobalPreferenceStore(draft).write(NetworkPreferences.proxy, value);
    }),
  );

  @override
  void initState() {
    final proxy = _networkSettings.read(NetworkPreferences.proxy);
    configuration = ProxyConfiguration.parse(proxy);
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return protectSettings(
      PopUpWidgetScaffold(
        title: "Proxy".tl,
        onBack: leaveSettings,
        tailing: [settingsSaveStatus],
        body: SingleChildScrollView(
          child: RadioGroup<ProxyMode>(
            groupValue: configuration.mode,
            onChanged: (v) {
              if (!acceptsSettingsChanges) return;
              _selection++;
              setState(() {
                configuration = configuration.copyWith(mode: v);
              });
              if (configuration.mode != ProxyMode.manual) {
                _saveProxy(configuration.serialize());
              }
            },
            child: Column(
              children: [
                RadioListTile<ProxyMode>(
                  title: Text("Direct".tl),
                  value: ProxyMode.direct,
                ),
                RadioListTile<ProxyMode>(
                  title: Text("System".tl),
                  value: ProxyMode.system,
                ),
                RadioListTile(
                  title: Text("Manual".tl),
                  value: ProxyMode.manual,
                ),
                if (configuration.mode == ProxyMode.manual) buildManualProxy(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  var formKey = GlobalKey<FormState>();

  Widget buildManualProxy() {
    return Form(
      key: formKey,
      child: Column(
        children: [
          TextFormField(
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: "Host".tl,
            ),
            initialValue: configuration.host,
            onChanged: (v) {
              configuration = configuration.copyWith(host: v);
            },
            validator: (v) {
              if (v?.isEmpty ?? false) {
                return "Host cannot be empty".tl;
              }
              return null;
            },
          ),
          const SizedBox(height: 8),
          TextFormField(
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: "Port".tl,
            ),
            initialValue: configuration.port,
            onChanged: (v) {
              configuration = configuration.copyWith(port: v);
            },
            validator: (v) {
              if (v?.isEmpty ?? true) {
                return null;
              }
              if (int.tryParse(v!) == null) {
                return "Port must be a number".tl;
              }
              return null;
            },
          ),
          const SizedBox(height: 8),
          TextFormField(
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: "Username".tl,
            ),
            initialValue: configuration.username,
            onChanged: (v) {
              configuration = configuration.copyWith(username: v);
            },
            validator: (v) {
              if ((v?.isEmpty ?? false) && configuration.password.isNotEmpty) {
                return "Username cannot be empty".tl;
              }
              return null;
            },
          ),
          const SizedBox(height: 8),
          TextFormField(
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: "Password".tl,
            ),
            initialValue: configuration.password,
            onChanged: (v) {
              configuration = configuration.copyWith(password: v);
            },
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: savingSettings || !acceptsSettingsChanges
                ? null
                : () async {
                    if (formKey.currentState?.validate() ?? false) {
                      final route =
                          PopupIndicatorWidget.maybeOf(context)?.route ??
                          ModalRoute.of(context);
                      final selection = _selection;
                      final value = configuration.serialize();
                      final saved = await _saveProxy(value);
                      if (mounted &&
                          saved &&
                          selection == _selection &&
                          value == configuration.serialize()) {
                        await leaveSettings(route);
                      }
                    }
                  },
            child: Text("Save".tl),
          ),
        ],
      ),
    ).paddingHorizontal(16).paddingTop(16);
  }
}

class _DNSOverrides extends StatefulWidget {
  const _DNSOverrides();

  @override
  State<_DNSOverrides> createState() => __DNSOverridesState();
}

class __DNSOverridesState extends SettingsSaveState<_DNSOverrides> {
  var overrides = <(TextEditingController, TextEditingController)>[];

  void _saveOverrides() {
    final map = <String, String>{
      for (final entry in overrides) entry.$1.text: entry.$2.text,
    };
    final engine = JsEngine();
    saveSetting('dnsOverrides', () async {
      await appdata.updateSettings((draft) {
        GlobalPreferenceStore(
          draft,
        ).write(NetworkPreferences.dnsOverrides, map);
      });
      engine.resetDio();
    });
  }

  @override
  void initState() {
    for (var entry
        in _networkSettings.read(NetworkPreferences.dnsOverrides).entries) {
      overrides.add((
        TextEditingController(text: entry.key),
        TextEditingController(text: entry.value),
      ));
    }
    super.initState();
  }

  @override
  void dispose() {
    for (var entry in overrides) {
      entry.$1.dispose();
      entry.$2.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return protectSettings(
      PopUpWidgetScaffold(
        title: "DNS Overrides".tl,
        onBack: leaveSettings,
        tailing: [settingsSaveStatus],
        body: SingleChildScrollView(
          child: Column(
            children: [
              SwitchSetting.preference(
                title: "Enable DNS Overrides".tl,
                preference: NetworkPreferences.enableDnsOverrides,
              ),
              SwitchSetting.preference(
                title: "Server Name Indication",
                preference: NetworkPreferences.sni,
              ),
              const SizedBox(height: 8),
              Container(
                height: 1,
                margin: EdgeInsets.symmetric(horizontal: 8),
                color: context.colorScheme.outlineVariant,
              ),
              for (var i = 0; i < overrides.length; i++) buildOverride(i),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () {
                  if (!acceptsSettingsChanges) return;
                  setState(() {
                    overrides.add((
                      TextEditingController(),
                      TextEditingController(),
                    ));
                  });
                  _saveOverrides();
                },
                icon: const Icon(Icons.add),
                label: Text("Add".tl),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildOverride(int index) {
    var entry = overrides[index];
    return Container(
      key: ObjectKey(entry.$1),
      height: 48,
      margin: EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: context.colorScheme.outlineVariant),
          left: BorderSide(color: context.colorScheme.outlineVariant),
          right: BorderSide(color: context.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: "Domain".tl,
              ),
              controller: entry.$1,
              onChanged: (_) => _saveOverrides(),
            ).paddingHorizontal(8),
          ),
          Container(width: 1, color: context.colorScheme.outlineVariant),
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: "IP".tl,
              ),
              controller: entry.$2,
              onChanged: (_) => _saveOverrides(),
            ).paddingHorizontal(8),
          ),
          Container(width: 1, color: context.colorScheme.outlineVariant),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              if (!acceptsSettingsChanges) return;
              setState(() {
                overrides.remove(entry);
              });
              _saveOverrides();
              // The fields can still be mounted until the next frame.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                entry.$1.dispose();
                entry.$2.dispose();
              });
            },
          ),
        ],
      ),
    );
  }
}
