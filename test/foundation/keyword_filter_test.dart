import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/keyword_filter.dart';

void main() {
  test('keywords retain defaults and valid legacy strings across JSON', () {
    for (final preference in KeywordPreferences.all) {
      final raw = ['a', ' A ', '', 'a', '标签'];
      final view = preference.normalize(jsonDecode(jsonEncode(raw)));
      expect(view, raw);
      expect(() => view.add('new'), throwsUnsupportedError);
      expect(applicationPreferenceDefaults[preference.key], isEmpty);
      final first = applicationPreferenceDefaults;
      (first[preference.key] as List).add('change');
      expect(applicationPreferenceDefaults[preference.key], isEmpty);
    }
  });
  test('malformed values filter only strings without changing storage', () {
    for (final preference in KeywordPreferences.all) {
      for (final raw in [
        null,
        'x',
        1,
        true,
        {},
        [false, 'word', null, 12, '', 'word'],
      ]) {
        final before = jsonEncode(raw);
        expect(
          preference.normalize(raw),
          raw is List ? ['word', '', 'word'] : [],
        );
        expect(jsonEncode(raw), before);
      }
    }
  });
  test(
    'comment matching preserves lowercase, whitespace and empty substring semantics',
    () {
      expect(KeywordFilter(['ÄBC']).blocksComment('prefix äbc suffix'), isTrue);
      expect(KeywordFilter([' A ']).blocksComment('a'), isFalse);
      expect(KeywordFilter([' A ']).blocksComment('x a y'), isTrue);
      expect(KeywordFilter(['']).blocksComment(''), isTrue);
      expect(KeywordFilter([]).blocksComment('anything'), isFalse);
    },
  );
  test('filter snapshot cannot be changed by a caller while in use', () {
    final words = ['first'];
    final filter = KeywordFilter(words);
    words[0] = 'later';
    expect(filter.blocksComment('FIRST'), isTrue);
    expect(filter.blocksComment('later'), isFalse);
    expect(() => filter.words.clear(), throwsUnsupportedError);
  });
}
