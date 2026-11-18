import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/app_data_sync_fields.dart';
import 'package:venera_next/foundation/keyword_filter.dart';
import 'package:venera_next/foundation/reader_preference_settings.dart';

class _Settings implements ReaderPreferenceSettings {
  _Settings(this.values);
  final Map<String, Object?> values;
  @override
  Object? operator [](String key) => values[key];
  @override
  void operator []=(String key, Object? value) => values[key] = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

KeywordMatch? _title(String title, KeywordRule rule) =>
    KeywordFilter.rules([rule]).comicMatch(title: title, description: '');

void main() {
  final misses = List.generate(
    120,
    (i) => KeywordRule(
      'missing-rule-$i',
      mode: KeywordMatchMode.values[i % 3],
      caseSensitive: i.isEven,
    ),
  );
  test('large snapshots keep rule priority over field and tag order', () {
    final first = KeywordRule('bl', mode: KeywordMatchMode.exactTag);
    final duplicate = KeywordRule('BL', mode: KeywordMatchMode.exactTag);
    final filter = KeywordFilter.rules([
      ...misses,
      first,
      const KeywordRule('TITLE'),
      duplicate,
    ]);
    final match = filter.comicMatch(
      title: 'TITLE',
      subtitle: 'TITLE',
      description: 'TITLE',
      tags: ['unrelated', 'genre:BL:other', 'BL'],
    )!;
    expect(match.rule, same(first));
    expect(match.field, KeywordMatchField.tag);
    expect(match.text, 'genre:BL:other');
    expect((match.start, match.end), (6, 8));
    expect(
      filter.comicMatch(title: '', description: '', tags: ['genre:other:BL']),
      isNull,
    );
  });

  test(
    'large snapshots preserve literal, Unicode and empty keyword offsets',
    () {
      var sample = 0;
      for (final (rule, title, tags, field, start, end) in [
        (
          const KeywordRule('a+b'),
          'x a+b y',
          <String>[],
          KeywordMatchField.title,
          2,
          5,
        ),
        (
          const KeywordRule('k'),
          '😀K',
          <String>[],
          KeywordMatchField.title,
          2,
          3,
        ),
        (
          const KeywordRule.legacy('\uD83D'),
          '😀',
          <String>[],
          KeywordMatchField.title,
          0,
          1,
        ),
        (
          const KeywordRule('bl', mode: KeywordMatchMode.wholeWord),
          'black and BL',
          ['BL'],
          KeywordMatchField.title,
          10,
          12,
        ),
        (
          const KeywordRule(
            'BL',
            mode: KeywordMatchMode.exactTag,
            caseSensitive: true,
          ),
          'BL',
          ['x:BL:other', 'BL'],
          KeywordMatchField.tag,
          2,
          4,
        ),
        (
          const KeywordRule('İ', mode: KeywordMatchMode.exactTag),
          'İ',
          ['i'],
          KeywordMatchField.tag,
          0,
          1,
        ),
        (
          const KeywordRule('', mode: KeywordMatchMode.wholeWord),
          'whole word',
          ['x:'],
          KeywordMatchField.tag,
          2,
          2,
        ),
        (
          const KeywordRule.legacy(''),
          'any',
          <String>[],
          KeywordMatchField.title,
          0,
          0,
        ),
        (
          const KeywordRule(
            'ns:BL:other',
            mode: KeywordMatchMode.exactTag,
            caseSensitive: true,
          ),
          'ns:BL:other',
          ['ns:BL:other'],
          KeywordMatchField.tag,
          0,
          11,
        ),
      ]) {
        final match = KeywordFilter.rules([
          ...misses,
          rule,
        ]).comicMatch(title: title, description: '', tags: tags);
        expect(match, isNotNull, reason: 'Unicode sample $sample');
        final actual = match!;
        expect(actual.rule, same(rule));
        expect((actual.field, actual.start, actual.end), (field, start, end));
        sample++;
      }
      final whole = KeywordFilter.rules([
        ...misses,
        const KeywordRule('bl', mode: KeywordMatchMode.wholeWord),
      ]);
      expect(
        whole.comicMatch(title: 'black blé BL漫画', description: ''),
        isNull,
      );
      final dotted = KeywordFilter.rules([
        ...misses,
        const KeywordRule('İ', mode: KeywordMatchMode.exactTag),
      ]);
      // Dart's original tag policy folds İ to i, not to i plus a combining dot.
      expect(
        dotted.comicMatch(title: '', description: '', tags: ['i\u0307']),
        isNull,
      );
    },
  );

  test('sync exclusions keep keyword lists and their options together', () {
    for (final (words, options) in [
      ('blockedWords', 'blockedWordRules'),
      ('blockedCommentWords', 'blockedCommentWordRules'),
    ]) {
      expect(splitAppDataFields(words), [words, options]);
      expect(splitAppDataFields(options), [options, words]);
      expect(splitAppDataFields('$words, $options'), [words, options]);
    }
    expect(splitAppDataFields('other, other'), ['other', 'other']);
  });
  const whole = KeywordRule('bl', mode: KeywordMatchMode.wholeWord);
  for (final (text, matches) in <(String, bool)>[
    ('BL', true),
    ('[BL] Short stories', true),
    ('artist.bl.part01.zip', true),
    ('BL_stories', true),
    ('BL-stories', true),
    ('😀BL😀', true),
    ('black and white', false),
    ('able', false),
    ('2bl', false),
    ('bl2', false),
    ('ébl', false),
    ('blé', false),
    ('bl\u0301', false),
    ('𐐀bl', false),
    ('BL漫画', false),
    ('中文 BL 故事', true),
    ('black.bl.zip', true),
  ]) {
    test('whole word boundaries: $text', () {
      expect(_title(text, whole) != null, matches);
    });
  }

  test(
    'a rejected first occurrence does not hide a later independent word',
    () {
      final match = _title('black and BL', whole)!;
      expect(match.start, 10);
      expect(match.end, 12);
      expect(match.text.substring(match.start, match.end), 'BL');
      expect(match.field, KeywordMatchField.title);
    },
  );

  test('literal punctuation never becomes regular expression syntax', () {
    for (final keyword in ['[BL]', 'a+b', 'a.b', r'\d+', '(cat|dog)']) {
      final rule = KeywordRule(keyword);
      final match = _title('prefix $keyword suffix', rule)!;
      expect(match.text.substring(match.start, match.end), keyword);
    }
    expect(_title('axb', const KeywordRule('a.b')), isNull);
    expect(_title('1234', const KeywordRule(r'\d+')), isNull);
    expect(_title('dog', const KeywordRule('(cat|dog)')), isNull);
  });

  test('case sensitivity is per rule and offsets use original text', () {
    const sensitive = KeywordRule(
      'bl',
      mode: KeywordMatchMode.wholeWord,
      caseSensitive: true,
    );
    expect(_title('[BL]', sensitive), isNull);
    expect(_title('[bl]', sensitive), isNotNull);
    final match = _title('😀ÄBC story', const KeywordRule('äbc'))!;
    expect(match.start, 2);
    expect(match.end, 5);
    expect(match.text.substring(match.start, match.end), 'ÄBC');
  });

  test(
    'contains supports Chinese phrases without pretending to segment them',
    () {
      expect(_title('校园恋爱故事', const KeywordRule('校园')), isNotNull);
      expect(
        _title(
          '校园恋爱故事',
          const KeywordRule('校园', mode: KeywordMatchMode.wholeWord),
        ),
        isNull,
      );
    },
  );

  test('tag-only rules never match the title, subtitle or description', () {
    final filter = KeywordFilter.rules([
      const KeywordRule('bl', mode: KeywordMatchMode.exactTag),
    ]);
    expect(
      filter.comicMatch(
        title: 'BL',
        subtitle: 'BL',
        description: 'BL',
        tags: ['black'],
      ),
      isNull,
    );
    for (final tag in ['BL', 'genre:BL', 'genre:BL:other']) {
      final match = filter.comicMatch(
        title: 'Visible title',
        description: '',
        tags: [tag],
      )!;
      expect(match.field, KeywordMatchField.tag);
      expect(match.text.substring(match.start, match.end), 'BL');
    }
    expect(
      filter.comicMatch(title: 'BL', description: '', tags: ['genre:other:BL']),
      isNull,
    );
  });

  test(
    'text modes retain exact tag matching and report the actual hit field',
    () {
      final filter = KeywordFilter.rules([whole]);
      for (final (field, subtitle, description, tags) in [
        (KeywordMatchField.subtitle, '[BL] Artist', '', <String>[]),
        (KeywordMatchField.description, null, '[BL] Story', <String>[]),
        (KeywordMatchField.tag, null, '', ['genre:BL']),
      ]) {
        expect(
          filter
              .comicMatch(
                title: 'black and white',
                subtitle: subtitle,
                description: description,
                tags: tags,
              )
              ?.field,
          field,
        );
      }
      expect(
        filter.comicMatch(title: '', description: '', tags: ['BL stories']),
        isNull,
      );
    },
  );

  test('old and new rules survive JSON without changing legacy behavior', () {
    final values = <String, Object?>{
      'blockedWords': ['bl', ' BL ', '', 'bl'],
      'blockedCommentWords': ['BL'],
      'blockedWordRules': <String, String>{},
      'blockedCommentWordRules': <String, String>{},
    };
    final raw = jsonEncode(values);
    final settings = _Settings(
      Map<String, Object?>.from(jsonDecode(raw) as Map),
    );
    final old = KeywordFilter.fromSettings(settings);
    expect(old.firstComicMatch(title: 'black', description: ''), 'bl');
    expect(old.rules.map((rule) => rule.keyword), ['bl', ' BL ', '', 'bl']);
    expect(
      old.rules.every((rule) => rule.isLegacy && rule.caseSensitive),
      isTrue,
    );
    expect(
      KeywordFilter.fromSettings(
        settings,
        comments: true,
      ).blocksComment('black'),
      isTrue,
    );
    expect(jsonEncode(settings.values), raw);

    settings['blockedWords'] = ['bl'];
    settings['blockedWordRules'] = {
      'bl': whole.storageOptions,
      'orphan': 'contains:insensitive',
    };
    final roundTrip = _Settings(
      Map<String, Object?>.from(jsonDecode(jsonEncode(settings.values)) as Map),
    );
    final updated = KeywordFilter.fromSettings(roundTrip);
    expect(updated.firstComicMatch(title: 'black', description: ''), isNull);
    expect(updated.firstComicMatch(title: '[BL]', description: ''), 'bl');
    expect(updated.firstComicMatch(title: 'orphan', description: ''), isNull);
    expect(old.firstComicMatch(title: 'black', description: ''), 'bl');
  });

  test(
    'invalid or unknown options fall back to the original policy on read',
    () {
      for (final value in [
        null,
        false,
        <String, Object?>{'bl': 1},
        {'bl': 'unknown:insensitive'},
        {'bl': 'wholeWord:unknown'},
        {'bl': 'wholeWord:insensitive:extra'},
      ]) {
        final settings = _Settings({
          'blockedWords': ['bl'],
          'blockedWordRules': value,
        });
        final raw = jsonEncode(settings.values);
        final filter = KeywordFilter.fromSettings(settings);
        expect(filter.firstComicMatch(title: 'black', description: ''), 'bl');
        expect(filter.firstComicMatch(title: 'BLACK', description: ''), isNull);
        expect(jsonEncode(settings.values), raw);
      }
    },
  );

  test('comment options support independent words with the old fallback', () {
    final settings = _Settings({
      'blockedCommentWords': ['bl'],
      'blockedCommentWordRules': {'bl': whole.storageOptions},
    });
    final filter = KeywordFilter.fromSettings(settings, comments: true);
    expect(filter.blocksComment('black'), isFalse);
    expect(filter.blocksComment('[BL] comment'), isTrue);
    settings['blockedCommentWordRules'] = {'bl': 'exactTag:sensitive'};
    expect(
      KeywordFilter.fromSettings(
        settings,
        comments: true,
      ).blocksComment('BLACK'),
      isTrue,
    );
  });

  test('option defaults are detached and rule snapshots are immutable', () {
    final first = applicationPreferenceDefaults;
    (first[KeywordPreferences.comicRules.key] as Map)['bl'] =
        whole.storageOptions;
    expect(
      applicationPreferenceDefaults[KeywordPreferences.comicRules.key],
      isEmpty,
    );
    final rules = [whole];
    final filter = KeywordFilter.rules(rules);
    rules.clear();
    expect(filter.firstComicMatch(title: '[BL]', description: ''), 'bl');
    expect(() => filter.rules.clear(), throwsUnsupportedError);
  });
}
