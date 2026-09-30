import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/application_configuration.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/global_preference_store.dart';

void main() {
  test(
    'network configuration filters malformed DNS and snapshots its values',
    () {
      final values = <String, Object?>{
        'proxy': 'user:pass@localhost:7897',
        'enableDnsOverrides': true,
        'dnsOverrides': <Object, Object>{
          'example.test': '127.0.0.1',
          42: 'invalid',
          'bad': false,
        },
        'downloadThreads': 99,
      };
      final config = NetworkConfiguration.read((key) => values[key]);
      expect(config.proxy, 'user:pass@localhost:7897');
      expect(config.effectiveDnsOverrides, {
        'example.test': ['127.0.0.1'],
      });
      expect(config.downloadThreads, 16);
      (values['dnsOverrides'] as Map)['example.test'] = '127.0.0.2';
      expect(config.dnsOverrides['example.test'], '127.0.0.1');
      expect(
        () => config.dnsOverrides['new'] = 'address',
        throwsUnsupportedError,
      );
    },
  );

  test(
    'invalid network values retain secure TLS and disabled DNS defaults',
    () {
      final config = NetworkConfiguration.read((_) => 'invalid');
      expect(config.sni, isTrue);
      expect(config.ignoreBadCertificate, isFalse);
      expect(config.effectiveDnsOverrides, isEmpty);
      expect(config.downloadThreads, 5);
      final disabled = NetworkConfiguration.read(
        (key) => {'sni': false, 'ignoreBadCertificate': true}[key],
      );
      expect(disabled.sni, isFalse);
      expect(disabled.ignoreBadCertificate, isTrue);
    },
  );

  test('appearance keeps legacy colors and rejects unsupported values', () {
    for (final color in ['yellow', 'cyan', 'blue']) {
      expect(
        AppearanceConfiguration.read(
          (key) => key == 'color' ? color : 'dark',
        ).color,
        color,
      );
    }
    final invalid = AppearanceConfiguration.read((_) => 42);
    expect(invalid.color, 'system');
    expect(invalid.themeMode, 'system');
  });

  test(
    'global bindings preserve device exclusions and existing stored keys',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'venera-config-test-',
      );
      App.dataPath = directory.path;
      final previousHistory = List<String>.from(appdata.searchHistory);
      final previous =
          jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map;
      addTearDown(() async {
        await appdata.saveData(false);
        previous.forEach((key, value) => appdata.settings[key] = value);
        appdata.searchHistory = previousHistory;
        directory.deleteSync(recursive: true);
      });
      final store = GlobalPreferenceStore(appdata.settings);
      store.bind(NetworkPreferences.proxy).write('direct');
      store.bind(NetworkPreferences.downloadThreads).write(8);
      store.bind(AppearancePreferences.themeMode).write('dark');
      expect(appdata.settings['proxy'], 'direct');
      expect(appdata.settings['downloadThreads'], 8);
      expect(store.appearance.themeMode, 'dark');
      expect(
        appdata.toJson()['settings']['deviceSpecificSettings'],
        previous['deviceSpecificSettings'],
      );
      final imported = Map<String, dynamic>.from(
        appdata.toJson()['settings'] as Map,
      );
      imported['proxy'] = 'remote-proxy';
      appdata.syncData({'settings': imported, 'searchHistory': <String>[]});
      await appdata.saveData(false);
      expect(store.network.proxy, 'direct');
    },
  );
}
