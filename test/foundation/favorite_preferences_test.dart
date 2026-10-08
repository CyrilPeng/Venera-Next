import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/application_preferences.dart';

void main() {
  test('favorite defaults keep legacy keys and JSON value types', () {
    const legacy = {
      'favoritesDisplayMode': 'list',
      'favoritesGalleryColumns': 0,
      'localFavoritesFirst': true,
      'autoCloseFavoritePanel': false,
      'newFavoriteAddTo': 'end',
      'moveFavoriteAfterRead': 'none',
      'quickFavorite': null,
      'onClickFavorite': 'viewDetail',
      'readLaterFolder': null,
      'followUpdatesFolder': null,
    };
    final defaults = applicationPreferenceDefaults;
    expect(
      FavoritePreferences.all.map((p) => p.key).toSet(),
      legacy.keys.toSet(),
    );
    for (final p in FavoritePreferences.all) {
      expect(defaults[p.key], legacy[p.key]);
      expect(defaults[p.key].runtimeType, legacy[p.key].runtimeType);
      expect(
        p.normalize(jsonDecode(jsonEncode(defaults[p.key]))),
        p.defaultValue,
      );
    }
  });
  test('gallery preserves rounded zero sentinel and finite count bounds', () {
    final p = FavoritePreferences.galleryColumns;
    for (final (value, expected) in <(Object?, int)>[
      (null, 0),
      ('4', 0),
      (true, 0),
      ([], 0),
      ({}, 0),
      (double.nan, 0),
      (double.infinity, 0),
      (double.negativeInfinity, 0),
      (-100, 2),
      (-0.5, 2),
      (-0.49, 0),
      (-0.0, 0),
      (0.49, 0),
      (0.5, 2),
      (1.49, 2),
      (2.5, 3),
      (3.49, 3),
      (3.5, 4),
      (6.6, 6),
      (1e100, 6),
    ]) {
      expect(p.normalize(value), expected, reason: '$value');
    }
  });
  test('gallery valid finite samples match original round then clamp rule', () {
    for (var tenth = -100; tenth <= 100; tenth++) {
      final value = tenth / 10;
      final rounded = value.round();
      final expected = rounded == 0 ? 0 : rounded.clamp(2, 6);
      final result = FavoritePreferences.galleryColumns.normalize(value);
      expect(result, expected, reason: '$value');
      expect(
        FavoritePreferences.galleryColumns.normalize(
          jsonDecode(jsonEncode(result)),
        ),
        result,
      );
    }
  });
  test('favorite flags reject string and numeric truthiness', () {
    for (final p in [
      FavoritePreferences.localFavoritesFirst,
      FavoritePreferences.autoCloseFavoritePanel,
    ]) {
      for (final value in [null, 'true', 'false', 0, 1, [], {}]) {
        expect(p.normalize(value), p.defaultValue);
      }
      expect(p.normalize(true), isTrue);
      expect(p.normalize(false), isFalse);
    }
  });
  test(
    'choices preserve supported strings and reject unknown or wrong types',
    () {
      for (final p in [
        FavoritePreferences.displayMode,
        FavoritePreferences.newFavoriteAddTo,
        FavoritePreferences.moveFavoriteAfterRead,
        FavoritePreferences.onClickFavorite,
      ]) {
        for (final value in [null, 'unknown', true, 1, [], {}]) {
          expect(p.normalize(value), p.defaultValue);
        }
        for (final value in p.choices) {
          expect(p.normalize(jsonDecode(jsonEncode(value))), value);
          expect(p.normalize(' $value'), p.defaultValue);
        }
      }
    },
  );
  test('nullable folder preferences keep unknown, empty and Unicode names', () {
    for (final p in [
      FavoritePreferences.quickFavorite,
      FavoritePreferences.readLaterFolder,
      FavoritePreferences.followUpdatesFolder,
    ]) {
      for (final value in ['', ' 收藏 ', 'not-in-current-database']) {
        expect(p.normalize(jsonDecode(jsonEncode(value))), value);
      }
      for (final value in [null, false, 12, [], {}]) {
        expect(p.normalize(value), isNull);
      }
    }
  });
}
