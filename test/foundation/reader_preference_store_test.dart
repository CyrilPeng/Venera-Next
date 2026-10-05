import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/reader_preferences.dart';
import 'package:venera_next/foundation/reader_preference_store.dart';

void main() {
  final settings = appdata.settings;
  late Map previous;
  setUp(() {
    previous = jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map;
    settings['deviceId'] = 'typed-preference-test';
    settings['deviceSpecificSettings'] = <String, dynamic>{};
    settings['comicSpecificSettings'] = <String, dynamic>{};
  });
  tearDown(() => previous.forEach((key, value) => settings[key] = value));

  test('active writes follow scope switches without recreating the store', () {
    final store = ReaderPreferenceStore(
      settings: settings,
      comicId: 'comic',
      sourceKey: 'source',
    );
    store.write(ReaderPreferences.readerBrightness, 40);
    expect(settings['readerBrightness'], 40);
    settings.setEnabledDeviceSpecificSettings(true);
    store.write(ReaderPreferences.readerBrightness, 60);
    expect(settings['readerBrightness'], 40);
    expect(settings.getDeviceReaderSetting('readerBrightness'), 60);
    settings.setEnabledComicSpecificSettings('comic', 'source', true);
    store.write(ReaderPreferences.readerBrightness, 80);
    expect(store.read(ReaderPreferences.readerBrightness), 80);
    expect(settings.getDeviceReaderSetting('readerBrightness'), 60);
    settings.setEnabledComicSpecificSettings('comic', 'source', false);
    expect(store.read(ReaderPreferences.readerBrightness), 60);
  });

  test('explicit scope writes are isolated and preserve unknown fields', () {
    settings['futureReaderOption'] = {'value': 'keep'};
    final global = ReaderPreferenceStore(
      settings: settings,
      scope: ReaderPreferenceScope.global,
    );
    final device = ReaderPreferenceStore(
      settings: settings,
      scope: ReaderPreferenceScope.device,
    );
    global.write(ReaderPreferences.readerSideMargin, 5);
    device.write(ReaderPreferences.readerSideMargin, 20);
    expect(global.read(ReaderPreferences.readerSideMargin), 5);
    settings.setEnabledDeviceSpecificSettings(true);
    expect(device.read(ReaderPreferences.readerSideMargin), 20);
    expect(settings['futureReaderOption'], {'value': 'keep'});
    expect(
      () => ReaderPreferenceStore(
        settings: settings,
        scope: ReaderPreferenceScope.comic,
      ),
      throwsArgumentError,
    );
  });

  test('writes validate choices and clamp finite numeric ranges', () {
    final store = ReaderPreferenceStore(
      settings: settings,
      scope: ReaderPreferenceScope.global,
    );
    store.write(ReaderPreferences.readerSideMargin, 999);
    store.write(ReaderPreferences.autoScrollSpeed, double.nan);
    store.write(ReaderPreferences.autoScrollStyle, 'invalid');
    expect(settings['readerSideMargin'], 30);
    expect(settings['readerSideMargin'], isA<int>());
    expect(settings['autoScrollSpeed'], 80);
    expect(settings['autoScrollStyle'], 'smooth');
    store.write(ReaderPreferences.readerScrollSpeed, 1.5);
    expect(settings['readerScrollSpeed'], 1.5);
  });

  test(
    'turning off comments clears the chapter-end option in the same scope',
    () {
      settings['showChapterComments'] = true;
      settings['showChapterCommentsAtEnd'] = true;
      settings.setEnabledDeviceSpecificSettings(true);
      settings.setEnabledComicSpecificSettings('comic', 'source', true);
      final comic = ReaderPreferenceStore(
        settings: settings,
        comicId: 'comic',
        sourceKey: 'source',
      );
      comic.write(ReaderPreferences.showChapterComments, false);
      expect(comic.read(ReaderPreferences.showChapterCommentsAtEnd), isFalse);
      expect(
        settings.getDeviceReaderSetting('showChapterCommentsAtEnd'),
        isTrue,
      );
      final device = ReaderPreferenceStore(settings: settings);
      device.write(ReaderPreferences.showChapterComments, false);
      expect(device.read(ReaderPreferences.showChapterCommentsAtEnd), isFalse);
      expect(settings['showChapterCommentsAtEnd'], isTrue);
      comic.write(ReaderPreferences.showChapterComments, true);
      expect(comic.read(ReaderPreferences.showChapterCommentsAtEnd), isFalse);
    },
  );

  test('default schema retains null long-press migration and slider steps', () {
    final defaults = ReaderPreferences.storageDefaults;
    expect(defaults['longPressAction'], isNull);
    expect(defaults['readerMode'], 'waterfallTopToBottom');
    expect(defaults['autoScrollSpeed'], 80);
    expect(ReaderPreferences.eInkRefreshDuration.step, 100);
    expect(ReaderPreferences.autoScrollSpeed.step, 10);
    expect(ReaderPreferences.readerScrollSpeed.step, 0.1);
    settings['longPressAction'] = null;
    settings['enableLongPressToZoom'] = false;
    expect(
      ReaderPreferenceStore(
        settings: settings,
      ).read(ReaderPreferences.longPressAction),
      'none',
    );
  });
}
