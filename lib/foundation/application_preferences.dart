import 'preferences.dart';

abstract final class NetworkPreferences {
  static const proxy = StringPreference('proxy', 'system');
  static const enableDnsOverrides = BoolPreference('enableDnsOverrides', false);
  static const dnsOverrides = StringMapPreference('dnsOverrides');
  static const sni = BoolPreference('sni', true);
  static const ignoreBadCertificate = BoolPreference(
    'ignoreBadCertificate',
    false,
  );
  static const downloadThreads = NumericPreference(
    'downloadThreads',
    5,
    min: 1,
    max: 16,
    step: 1,
    integer: true,
  );
  static const all = <Preference<Object>>[
    proxy,
    enableDnsOverrides,
    dnsOverrides,
    sni,
    ignoreBadCertificate,
    downloadThreads,
  ];
}

abstract final class AppearancePreferences {
  static const themeMode = ChoicePreference('theme_mode', 'system', [
    'system',
    'light',
    'dark',
  ]);
  // Yellow and cyan are supported by existing saved configurations even though
  // the current selector does not offer them.
  static const color = ChoicePreference('color', 'system', [
    'system',
    'red',
    'pink',
    'purple',
    'green',
    'orange',
    'blue',
    'yellow',
    'cyan',
  ]);
  static const all = <Preference<Object>>[themeMode, color];
}

Map<String, Object?> get applicationPreferenceDefaults => {
  for (final preference in [
    ...NetworkPreferences.all,
    ...AppearancePreferences.all,
  ])
    preference.key: preference.storageDefault,
};
