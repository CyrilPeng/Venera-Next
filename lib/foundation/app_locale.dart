import 'dart:ui';

import 'app_language.dart';
import 'appdata.dart';
import 'application_preferences.dart';
import 'global_preference_store.dart';

/// Resolve the current preference on every read, including after a settings change.
AppLanguage get appLanguage => resolveAppLanguage(
  GlobalPreferenceStore(appdata.settings).read(AppPreferences.language),
  PlatformDispatcher.instance.locales,
);

Locale get appLocale => appLanguage.locale;

Locale resolveAppLocale(String preference, List<Locale> systemLocales) =>
    resolveAppLanguage(preference, systemLocales).locale;

AppLanguage resolveAppLanguage(String preference, List<Locale> systemLocales) {
  for (final language in AppLanguage.values) {
    if (language.preference == preference) return language;
  }

  for (final locale in systemLocales) {
    if (locale.languageCode == 'zh') {
      // Script takes priority over region: zh-Hans-US is simplified Chinese.
      // Older locale identifiers may only provide a region, such as zh-HK.
      final traditional = switch (locale.scriptCode) {
        'Hant' => true,
        'Hans' => false,
        _ => const ['TW', 'HK', 'MO'].contains(locale.countryCode),
      };
      return traditional
          ? AppLanguage.traditionalChinese
          : AppLanguage.simplifiedChinese;
    }
    for (final language in AppLanguage.values) {
      if (language.locale.languageCode == locale.languageCode) return language;
    }
  }
  return AppLanguage.english;
}
