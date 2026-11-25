import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app_locale.dart';
import 'package:venera_next/foundation/app_language.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The persisted default remains 'system'.
  const defaultLanguage = 'system';

  setUp(() {
    appdata.settings['language'] = defaultLanguage;
  });

  tearDown(() {
    appdata.settings['language'] = defaultLanguage;
  });

  test('settings and Flutter locales use the same language registry', () {
    expect(AppPreferences.language.choices, AppLanguage.options.keys);
    expect(AppLanguage.supportedLocales, [
      const Locale('zh', 'CN'),
      const Locale('zh', 'TW'),
      const Locale('en'),
      const Locale('de', 'DE'),
      const Locale('ja', 'JP'),
    ]);
    for (final language in AppLanguage.values) {
      appdata.settings['language'] = language.preference;
      expect(appLanguage, language);
      expect(appLocale, language.locale);
    }
    expect(AppLanguage.english.translationKey, 'en_US');
  });

  group('appLocale explicit language setting', () {
    test('zh-CN selects simplified Chinese', () {
      appdata.settings['language'] = 'zh-CN';
      expect(appLocale, const Locale('zh', 'CN'));
    });

    test('zh-TW selects traditional Chinese', () {
      appdata.settings['language'] = 'zh-TW';
      expect(appLocale, const Locale('zh', 'TW'));
    });

    test('en-US selects English', () {
      appdata.settings['language'] = 'en-US';
      expect(appLocale, const Locale('en'));
    });

    test('explicit choice overrides the reported system locale', () {
      // The tester reports English first, so an unrelated bug could leak the
      // system value through; the explicit setting must win.
      appdata.settings['language'] = 'zh-TW';
      expect(appLocale, const Locale('zh', 'TW'));
      appdata.settings['language'] = 'zh-CN';
      expect(appLocale, const Locale('zh', 'CN'));
    });
  });

  group('appLocale system language under flutter_tester', () {
    test('malformed stored language follows system without rewriting it', () {
      for (final value in <Object?>[null, false, 1, [], {}]) {
        appdata.settings['language'] = value;
        expect(appLocale, const Locale('en'));
        expect(appdata.settings['language'], same(value));
      }
    });

    test('system resolves to the first supported reported language', () {
      appdata.settings['language'] = 'system';
      expect(appLocale, const Locale('en'));
    });

    test('unrecognized setting value falls back to system resolution', () {
      appdata.settings['language'] = 'fr-FR';
      expect(appLocale, const Locale('en'));
    });

    test(
      'restoring system resumes system resolution after an explicit choice',
      () {
        appdata.settings['language'] = 'zh-TW';
        expect(appLocale, const Locale('zh', 'TW'));

        appdata.settings['language'] = 'system';
        expect(appLocale, const Locale('en'));
      },
    );
  });

  group('production locale resolution', () {
    final cases = <({String name, List<Locale> system, Locale expected})>[
      (
        name: 'zh-Hans-US: script beats region',
        system: [
          const Locale.fromSubtags(
            languageCode: 'zh',
            countryCode: 'US',
            scriptCode: 'Hans',
          ),
        ],
        expected: const Locale('zh', 'CN'),
      ),
      (
        name: 'zh-Hans-CN: simplified',
        system: [
          const Locale.fromSubtags(
            languageCode: 'zh',
            countryCode: 'CN',
            scriptCode: 'Hans',
          ),
        ],
        expected: const Locale('zh', 'CN'),
      ),
      (
        name: 'zh-Hant: script only',
        system: [Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')],
        expected: const Locale('zh', 'TW'),
      ),
      (
        name: 'zh-Hant-CN: script beats region',
        system: [
          const Locale.fromSubtags(
            languageCode: 'zh',
            countryCode: 'CN',
            scriptCode: 'Hant',
          ),
        ],
        expected: const Locale('zh', 'TW'),
      ),
      (
        name: 'zh-TW: traditional region fallback',
        system: [const Locale('zh', 'TW')],
        expected: const Locale('zh', 'TW'),
      ),
      (
        name: 'zh-HK: traditional region fallback',
        system: [const Locale('zh', 'HK')],
        expected: const Locale('zh', 'TW'),
      ),
      (
        name: 'zh-MO: traditional region fallback',
        system: [const Locale('zh', 'MO')],
        expected: const Locale('zh', 'TW'),
      ),
      (
        name: 'zh-CN: simplified region',
        system: [const Locale('zh', 'CN')],
        expected: const Locale('zh', 'CN'),
      ),
      (
        name: 'zh-SG: simplified region',
        system: [const Locale('zh', 'SG')],
        expected: const Locale('zh', 'CN'),
      ),
      (
        name: 'zh without region: simplified',
        system: [const Locale('zh')],
        expected: const Locale('zh', 'CN'),
      ),
      (
        name: 'en-GB: English',
        system: [const Locale('en', 'GB')],
        expected: const Locale('en'),
      ),
      (
        name: 'unsupported language falls back to English',
        system: [const Locale('fr', 'FR')],
        expected: const Locale('en'),
      ),
      (
        name: 'empty reported list falls back to English',
        system: <Locale>[],
        expected: const Locale('en'),
      ),
      (
        name: 'first matching language wins: English before Chinese',
        system: [const Locale('en', 'US'), const Locale('zh', 'CN')],
        expected: const Locale('en'),
      ),
      (
        name: 'first matching language wins: Chinese before English',
        system: [const Locale('zh', 'HK'), const Locale('en', 'US')],
        expected: const Locale('zh', 'TW'),
      ),
      (
        name: 'de-AT: German regardless of region',
        system: [const Locale('de', 'AT')],
        expected: const Locale('de', 'DE'),
      ),
      (
        name: 'de-CH: German regardless of region',
        system: [const Locale('de', 'CH')],
        expected: const Locale('de', 'DE'),
      ),
      (
        name: 'German without region',
        system: [const Locale('de')],
        expected: const Locale('de', 'DE'),
      ),
      (
        name: 'ja-JP: Japanese',
        system: [const Locale('ja', 'JP')],
        expected: const Locale('ja', 'JP'),
      ),
      (
        name: 'Japanese without region',
        system: [const Locale('ja')],
        expected: const Locale('ja', 'JP'),
      ),
      (
        name: 'first supported match wins after unsupported language',
        system: [
          const Locale('fr', 'FR'),
          const Locale('ja', 'JP'),
          const Locale('de', 'DE'),
          const Locale('en'),
        ],
        expected: const Locale('ja', 'JP'),
      ),
      (
        name: 'German before Chinese and Japanese',
        system: [
          const Locale('de', 'AT'),
          const Locale('zh', 'TW'),
          const Locale('ja'),
        ],
        expected: const Locale('de', 'DE'),
      ),
    ];

    for (final testCase in cases) {
      test(testCase.name, () {
        expect(resolveAppLocale('system', testCase.system), testCase.expected);
      });
    }

    test('appLocale delegates to the production resolver', () {
      appdata.settings['language'] = 'system';
      expect(
        resolveAppLocale('system', PlatformDispatcher.instance.locales),
        appLocale,
      );
    });

    test(
      'explicit German and Japanese override a different system language',
      () {
        for (final language in [AppLanguage.german, AppLanguage.japanese]) {
          expect(
            resolveAppLanguage(language.preference, const [Locale('zh', 'CN')]),
            language,
          );
        }
      },
    );
  });
}
