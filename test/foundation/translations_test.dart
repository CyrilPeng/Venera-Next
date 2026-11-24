import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app_language.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousLanguage = appdata.settings['language'];

  setUpAll(AppTranslation.init);
  setUp(() => appdata.settings['language'] = 'en-US');
  tearDown(() => appdata.settings['language'] = previousLanguage);

  test('bundled dictionaries cover the registered non-English languages', () {
    expect(AppTranslation.translations.keys.toSet(), {
      for (final language in AppLanguage.values)
        if (language != AppLanguage.english) language.translationKey,
    });
  });

  test('switching languages translates overwrite confirmation and fallback', () {
    const confirmation =
        'Local changes will be overwritten by the downloaded backup. Continue?';
    for (final (language, expected) in [
      ('zh-CN', '下载备份会覆盖本地修改，是否继续？'),
      ('zh-TW', '下載的備份將覆寫本機修改，是否繼續？'),
      ('en-US', confirmation),
      ('zh-CN', '下载备份会覆盖本地修改，是否继续？'),
    ]) {
      appdata.settings['language'] = language;
      expect(confirmation.tl, expected);
      expect('An unknown translation key'.tl, 'An unknown translation key');
    }
  });

  test('parameters replace complete tokens once and cover repeated uses', () {
    expect(
      '@a and @amount: @a / @unknown'.tlParams({'a': '@amount', 'amount': 10}),
      '@amount and 10: @amount / @unknown',
    );
    for (final language in AppLanguage.values) {
      appdata.settings['language'] = language.preference;
      expect('Page @page'.tlParams({'page': 12}), isNot(contains('@page')));
      expect('Page @page'.tlParams({'page': 12}), contains('12'));
    }
  });
}
