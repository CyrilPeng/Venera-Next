import 'dart:ui';

/// Keep persisted choices, Flutter locales and translation identifiers together.
enum AppLanguage {
  simplifiedChinese('zh-CN', '简体中文', Locale('zh', 'CN'), 'zh_CN'),
  traditionalChinese('zh-TW', '繁體中文', Locale('zh', 'TW'), 'zh_TW'),
  english('en-US', 'English', Locale('en'), 'en_US'),
  german('de-DE', 'Deutsch', Locale('de', 'DE'), 'de_DE'),
  japanese('ja-JP', '日本語', Locale('ja', 'JP'), 'ja_JP');

  const AppLanguage(
    this.preference,
    this.label,
    this.locale,
    this.translationKey,
  );

  final String preference;
  final String label;
  final Locale locale;
  final String translationKey;

  static final preferenceIds = List<String>.unmodifiable([
    'system',
    for (final language in values) language.preference,
  ]);

  static final options = Map<String, String>.unmodifiable({
    'system': 'System',
    for (final language in values) language.preference: language.label,
  });

  static final supportedLocales = List<Locale>.unmodifiable(
    values.map((language) => language.locale),
  );
}
