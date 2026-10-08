import 'dart:ui';

import 'appdata.dart';
import 'application_preferences.dart';
import 'global_preference_store.dart';

/// Resolve the current preference on every read, including after a settings change.
Locale get appLocale => resolveAppLocale(
  GlobalPreferenceStore(appdata.settings).read(AppPreferences.language),
  PlatformDispatcher.instance.locales,
);

Locale resolveAppLocale(String preference, List<Locale> systemLocales) {
  final selected = switch (preference) {
    'zh-CN' => const Locale('zh', 'CN'),
    'zh-TW' => const Locale('zh', 'TW'),
    'en-US' => const Locale('en'),
    _ => null,
  };
  if (selected != null) return selected;

  for (final locale in systemLocales) {
    if (locale.languageCode == 'zh') {
      // Script takes priority over region: zh-Hans-US is simplified Chinese.
      // Older locale identifiers may only provide a region, such as zh-HK.
      final traditional = switch (locale.scriptCode) {
        'Hant' => true,
        'Hans' => false,
        _ => const ['TW', 'HK', 'MO'].contains(locale.countryCode),
      };
      return Locale('zh', traditional ? 'TW' : 'CN');
    }
    if (locale.languageCode == 'en') return const Locale('en');
  }
  return const Locale('en');
}
