import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/search/search_filter.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/preferences.dart';

void main() {
  test(
    'display defaults retain their legacy keys, values and storage types',
    () {
      const legacy = {
        'comicDisplayMode': 'detailed',
        'comicTileScale': 1.0,
        'showFavoriteStatusOnTile': true,
        'showHistoryStatusOnTile': false,
        'showUpdateStatusOnTile': true,
        'autoAddLanguageFilter': 'none',
        'initialPage': '0',
        'comicListDisplayMode': 'paging',
      };
      final defaults = applicationPreferenceDefaults;
      for (final entry in legacy.entries) {
        expect(defaults[entry.key], entry.value);
        expect(defaults[entry.key].runtimeType, entry.value.runtimeType);
      }
    },
  );

  test(
    'startup page accepts legacy integers and parseable strings in range',
    () {
      final preference = DiscoveryPreferences.initialPage;
      for (final (raw, page) in <(Object, String)>[
        (0, '0'),
        (1, '1'),
        (2, '2'),
        (3, '3'),
        ('0', '0'),
        ('1', '1'),
        ('2', '2'),
        ('3', '3'),
        (' 2 ', '2'),
        ('+3', '3'),
        ('01', '1'),
        ('0x2', '2'),
        ('-0', '0'),
      ]) {
        expect(int.tryParse(raw.toString()), int.parse(page));
        final normalized = preference.normalize(raw);
        expect(normalized, page, reason: '$raw');
        expect(jsonDecode(jsonEncode(normalized)), isA<String>());
        expect(preference.normalize(jsonDecode(jsonEncode(normalized))), page);
      }
    },
  );

  test('startup page rejects bad indices before they reach the page list', () {
    for (final raw in [
      null,
      -1,
      4,
      999,
      '-1',
      '4',
      '999',
      '1.0',
      1.0,
      true,
      false,
      '',
      'unknown',
      [],
      {},
      double.nan,
      double.infinity,
    ]) {
      expect(
        DiscoveryPreferences.initialPage.normalize(raw),
        '0',
        reason: '$raw',
      );
    }
  });

  test(
    'continuous aliases preserve old editor spelling without broad case folding',
    () {
      final preference = DiscoveryPreferences.comicListDisplayMode;
      for (final raw in ['continuous', 'Continuous']) {
        expect(preference.normalize(raw), 'Continuous');
        expect(preference.normalize(jsonDecode(jsonEncode(raw))), 'Continuous');
      }
      for (final raw in [
        null,
        'paging',
        'CONTINUOUS',
        'unknown',
        1,
        false,
        [],
        {},
      ]) {
        expect(preference.normalize(raw), 'paging');
      }
      expect(DiscoveryPreferences.comicDisplayMode.normalize('brief'), 'brief');
      for (final raw in [
        null,
        'detailed',
        'Brief',
        'unknown',
        1,
        false,
        [],
        {},
      ]) {
        expect(
          DiscoveryPreferences.comicDisplayMode.normalize(raw),
          'detailed',
        );
      }
    },
  );

  test(
    'scale rejects nonfinite and wrong types, bounds values without step rounding',
    () {
      final preference = DiscoveryPreferences.comicTileScale;
      for (final raw in [
        null,
        '1.2',
        true,
        [],
        {},
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(preference.normalize(raw), 1.0);
      }
      for (final (raw, expected) in [
        (-1, 0.5),
        (0, 0.5),
        (2, 1.5),
        (0.5, 0.5),
        (1.5, 1.5),
        (1.013, 1.013),
      ]) {
        expect(preference.normalize(raw), expected);
        expect(preference.normalize(jsonDecode(jsonEncode(raw))), expected);
      }
    },
  );

  test(
    'status flags preserve explicit booleans and use individual defaults',
    () {
      for (final (preference, fallback) in [
        (DiscoveryPreferences.showFavoriteStatusOnTile, true),
        (DiscoveryPreferences.showHistoryStatusOnTile, false),
        (DiscoveryPreferences.showUpdateStatusOnTile, true),
      ]) {
        expect(preference.normalize(true), isTrue);
        expect(preference.normalize(false), isFalse);
        for (final raw in [null, 0, 1, 'true', 'false', [], {}]) {
          expect(preference.normalize(raw), fallback);
        }
      }
    },
  );

  test(
    'normalized language filters keep source restrictions and explicit tags',
    () {
      for (final raw in [
        null,
        'none',
        'chinese',
        'english',
        'japanese',
        'unknown',
        true,
        [],
        {},
      ]) {
        final setting = DiscoveryPreferences.autoAddLanguageFilter.normalize(
          raw,
        );
        for (final source in ['nhentai', 'ehentai', 'custom']) {
          final expected =
              source != 'custom' &&
                  ['chinese', 'english', 'japanese'].contains(raw)
              ? 'query language:$raw'
              : 'query';
          expect(
            applySearchLanguageFilter(
              'query',
              sourceKey: source,
              setting: setting,
            ),
            expected,
          );
          expect(
            applySearchLanguageFilter(
              'query language:explicit',
              sourceKey: source,
              setting: setting,
            ),
            'query language:explicit',
          );
        }
      }
    },
  );

  test(
    'defaults preserve unconfigured search and explicit empty page lists',
    () {
      final defaults = applicationPreferenceDefaults;
      expect(defaults['searchSources'], isNull);
      expect(defaults['defaultSearchTarget'], isNull);
      for (final key in ['explore_pages', 'categories', 'favorites']) {
        expect(defaults[key], isEmpty);
      }
      (defaults['categories'] as List).add('changed');
      expect(applicationPreferenceDefaults['categories'], isEmpty);
    },
  );

  test(
    'null and empty search selections survive JSON round trips distinctly',
    () {
      final preference = DiscoveryPreferences.searchSources;
      expect(preference.normalize(null), isNull);
      for (final input in [
        null,
        <String>[],
        ['missing', '', 'missing', 'known'],
      ]) {
        final encoded = jsonEncode(preference.normalize(input));
        expect(jsonDecode(encoded), input);
        expect(preference.normalize(jsonDecode(encoded)), input);
      }
    },
  );

  test(
    'list views preserve identifiers and order without rewriting old data',
    () {
      final input = <Object?>[
        'unknown',
        '',
        'known',
        'unknown',
        7,
        null,
        {'future': true},
      ];
      final before = jsonEncode(input);
      for (final preference in <Preference<List<String>?>>[
        DiscoveryPreferences.explorePages,
        DiscoveryPreferences.categoryPages,
        DiscoveryPreferences.favoritePages,
        DiscoveryPreferences.searchSources,
      ]) {
        final view = preference.normalize(input)!;
        expect(view, ['unknown', '', 'known', 'unknown']);
        expect(() => view.add('mutated'), throwsUnsupportedError);
        expect(jsonEncode(input), before);
      }
      final snapshot = DiscoveryPreferences.explorePages.normalize(input);
      input[0] = 'later';
      expect(snapshot.first, 'unknown');
    },
  );

  test(
    'wrong container types use defaults without losing nullable semantics',
    () {
      for (final raw in [
        42,
        false,
        'source',
        {'source': true},
      ]) {
        expect(DiscoveryPreferences.explorePages.normalize(raw), isEmpty);
        expect(DiscoveryPreferences.categoryPages.normalize(raw), isEmpty);
        expect(DiscoveryPreferences.favoritePages.normalize(raw), isEmpty);
        expect(DiscoveryPreferences.searchSources.normalize(raw), isNull);
      }
      expect(DiscoveryPreferences.searchSources.normalize([42, null]), isEmpty);
    },
  );

  test(
    'nullable target keeps arbitrary source keys and aggregated sentinel',
    () {
      final preference = DiscoveryPreferences.defaultSearchTarget;
      for (final value in [null, '', '_aggregated_', 'retired-source']) {
        expect(preference.normalize(value), value);
        expect(jsonDecode(jsonEncode(preference.normalize(value))), value);
      }
      for (final value in [42, false, [], {}]) {
        expect(preference.normalize(value), isNull);
      }
    },
  );
}
