import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/tags_translation.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousLanguage = appdata.settings['language'];
  setUpAll(TagsTranslation.readData);
  tearDown(() => appdata.settings['language'] = previousLanguage);

  test('tag lookup follows repeated explicit switches without reloading', () {
    for (final (language, expected, conditional) in [
      ('zh-CN', '英语', '英语'),
      ('zh-TW', '英語', '英語'),
      ('en-US', '英语', 'language:english'),
      ('system', '英语', 'language:english'),
      ('zh-TW', '英語', '英語'),
      ('zh-CN', '英语', '英语'),
    ]) {
      appdata.settings['language'] = language;
      expect('language:english'.translateTagsToCN, expected);
      expect('language:english'.translateTagIfNeed, conditional);
      expect(TagsTranslation.languageTranslations['english'], expected);
      expect(TagsTranslation.translateTag('language:english'), expected);
      expect('an unknown tag'.translateTagIfNeed, 'an unknown tag');
    }
  });
}
