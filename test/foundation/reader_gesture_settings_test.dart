import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  final settings = appdata.settings;
  late Map<String, dynamic> previous;
  String action() =>
      settings.getReaderSetting('comic', 'source', 'longPressAction');
  setUp(() {
    previous = jsonDecode(jsonEncode(appdata.toJson()['settings']));
    settings['longPressAction'] = null;
    settings['enableLongPressToZoom'] = true;
    settings['deviceId'] = 'test-device';
    settings['deviceSpecificSettings'] = <String, dynamic>{};
    settings['comicSpecificSettings'] = <String, dynamic>{};
  });
  tearDown(() => previous.forEach((key, value) => settings[key] = value));

  test(
    'legacy zoom and disabled choices are preserved without rewriting data',
    () {
      expect(action(), 'zoom');
      settings['enableLongPressToZoom'] = false;
      expect(action(), 'none');
      expect(settings['longPressAction'], 'none');
      settings['longPressAction'] = 'autoReading';
      expect(action(), 'autoReading');
    },
  );

  test(
    'comic and device choices take priority, including legacy disabled choices',
    () {
      settings['longPressAction'] = 'autoReading';
      settings.setEnabledDeviceSpecificSettings(true);
      settings.setDeviceReaderSetting('enableLongPressToZoom', false);
      expect(action(), 'none');
      settings.setDeviceReaderSetting('longPressAction', 'zoom');
      expect(action(), 'zoom');
      settings.setEnabledComicSpecificSettings('comic', 'source', true);
      settings.setReaderSetting(
        'comic',
        'source',
        'enableLongPressToZoom',
        false,
      );
      expect(action(), 'none');
      settings.setReaderSetting(
        'comic',
        'source',
        'longPressAction',
        'autoReading',
      );
      expect(action(), 'autoReading');
      settings.setEnabledComicSpecificSettings('comic', 'source', false);
      expect(action(), 'zoom');
    },
  );

  test(
    'automatic speed and chapter continuation follow existing override precedence',
    () {
      settings['autoScrollSpeed'] = 80;
      settings.setEnabledDeviceSpecificSettings(true);
      settings.setDeviceReaderSetting('autoScrollSpeed', 120);
      settings.setEnabledComicSpecificSettings('comic', 'source', true);
      settings.setReaderSetting('comic', 'source', 'autoScrollSpeed', 200);
      settings.setReaderSetting(
        'comic',
        'source',
        'autoReadingAcrossChapters',
        false,
      );
      expect(
        settings.getReaderSetting('comic', 'source', 'autoScrollSpeed'),
        200,
      );
      expect(
        settings.getReaderSetting(
          'comic',
          'source',
          'autoReadingAcrossChapters',
        ),
        isFalse,
      );
      settings.setEnabledComicSpecificSettings('comic', 'source', false);
      expect(
        settings.getReaderSetting('comic', 'source', 'autoScrollSpeed'),
        120,
      );
    },
  );
}
