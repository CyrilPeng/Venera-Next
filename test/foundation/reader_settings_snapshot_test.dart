import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_layout.dart';
import 'package:venera_next/foundation/reader_settings.dart';

void main() {
  test('scope precedence skips nulls and disabled overrides', () {
    final global = {'readerSideMargin': 5, 'limitImageWidth': true};
    final device = {'enabled': true, 'readerSideMargin': 10};
    final comic = <String, Object?>{'enabled': true, 'readerSideMargin': 20};
    expect(
      ReaderSettings.resolve(
        global: global,
        device: device,
        comic: comic,
      ).readerSideMargin,
      20,
    );
    comic['readerSideMargin'] = null;
    expect(
      ReaderSettings.resolve(
        global: global,
        device: device,
        comic: comic,
      ).readerSideMargin,
      10,
    );
    device['enabled'] = false;
    expect(
      ReaderSettings.resolve(
        global: global,
        device: device,
        comic: comic,
      ).readerSideMargin,
      5,
    );
  });

  test(
    'manual comic mode and automatic device mode keep independent scopes',
    () {
      final global = {
        'autoReaderMode': true,
        'pagedReaderMode': 'galleryRightToLeft',
      };
      final comic = <String, Object?>{
        'enabled': false,
        'readerModeOverride': 'galleryTopToBottom',
      };
      expect(
        ReaderSettings.resolve(
          global: global,
          comic: comic,
          layout: ComicLayout.paged,
        ).readerMode,
        'galleryTopToBottom',
      );
      comic['readerModeOverride'] = 'default';
      expect(
        ReaderSettings.resolve(
          global: global,
          comic: comic,
          layout: ComicLayout.paged,
        ).readerMode,
        'galleryRightToLeft',
      );
    },
  );

  test('legacy long press action inherits at each enabled scope', () {
    final global = {'enableLongPressToZoom': true};
    final device = {'enabled': true, 'enableLongPressToZoom': false};
    final comic = <String, Object?>{
      'enabled': true,
      'longPressAction': 'autoReading',
    };
    expect(
      ReaderSettings.resolve(
        global: global,
        device: device,
        comic: comic,
      ).longPressAction,
      'autoReading',
    );
    comic['longPressAction'] = null;
    expect(
      ReaderSettings.resolve(
        global: global,
        device: device,
        comic: comic,
      ).longPressAction,
      'none',
    );
  });

  test(
    'invalid numeric and enum values cannot escape into reading policies',
    () {
      final settings = ReaderSettings.resolve(
        global: {
          'readerSideMargin': 500,
          'autoScrollSpeed': double.nan,
          'eInkRefreshInterval': -5,
          'readerScreenPicNumberForPortrait': 'broken',
          'readerMode': 'unknown',
          'longPressZoomPosition': 3,
        },
      );
      expect(settings.readerSideMargin, 30);
      expect(settings.autoScrollSpeed, 80);
      expect(settings.eInkRefreshInterval, 1);
      expect(settings.readerScreenPicNumberForPortrait, 1);
      expect(settings.readerMode, 'waterfallTopToBottom');
      expect(settings.longPressZoomPosition, 'press');
    },
  );

  test('snapshot neither changes persistence nor follows later mutations', () {
    final global = <String, Object?>{
      'autoScrollSpeed': 120,
      'unknownField': 'keep',
    };
    final before = jsonEncode(global);
    final snapshot = ReaderSettings.resolve(global: global);
    expect(jsonEncode(global), before);
    global['autoScrollSpeed'] = 240;
    expect(snapshot.autoScrollSpeed, 120);
    expect(global['unknownField'], 'keep');
  });

  test(
    'stored settings adapter agrees with legacy precedence and stays live',
    () {
      final settings = appdata.settings;
      final previous =
          jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map;
      addTearDown(
        () => previous.forEach((key, value) => settings[key] = value),
      );
      settings['deviceId'] = 'snapshot-test';
      settings['comicSpecificSettings'] = <String, dynamic>{};
      settings['deviceSpecificSettings'] = <String, dynamic>{};
      settings['autoScrollSpeed'] = 100;
      for (final enabled in [false, true]) {
        settings.setEnabledDeviceSpecificSettings(enabled);
        settings.setDeviceReaderSetting('autoScrollSpeed', 200);
        settings.setEnabledComicSpecificSettings('comic', 'source', enabled);
        settings.setReaderSetting('comic', 'source', 'autoScrollSpeed', 300);
        expect(
          settings.readerSettings('comic', 'source').autoScrollSpeed,
          settings.getReaderSetting('comic', 'source', 'autoScrollSpeed'),
        );
      }
    },
  );
}
