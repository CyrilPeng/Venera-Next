import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_layout.dart';

void main() {
  final settings = appdata.settings;
  late Map<String, dynamic> previous;
  const cid = 'comic';
  const source = 'source';
  String resolve() => settings.resolveReaderMode(cid, source);
  void detect(ComicLayout layout) =>
      settings.setComicLayout(cid, source, ComicLayoutDetection(layout, 6));

  setUp(() {
    previous = jsonDecode(jsonEncode(appdata.toJson()['settings']));
    settings['deviceId'] = 'reader-regression-device';
    settings['deviceSpecificSettings'] = <String, dynamic>{};
    settings['comicSpecificSettings'] = <String, dynamic>{};
    settings['comicLayoutDetections'] = <String, dynamic>{};
    settings['readerMode'] = 'galleryLeftToRight';
    settings['pagedReaderMode'] = 'galleryRightToLeft';
    settings['longStripReaderMode'] = 'continuousTopToBottom';
    settings['autoReaderMode'] = false;
  });
  tearDown(() => previous.forEach((key, value) => settings[key] = value));

  test('automatic selection is opt-in for existing installations', () {
    expect(previous['autoReaderMode'], isFalse);
    detect(ComicLayout.longStrip);
    expect(resolve(), 'galleryLeftToRight');
    settings.setEnabledDeviceSpecificSettings(true);
    settings.setDeviceReaderSetting('readerMode', 'continuousLeftToRight');
    expect(resolve(), 'continuousLeftToRight');
  });

  test(
    'unknown layout falls back while recognized layouts use preferences',
    () {
      settings['autoReaderMode'] = true;
      expect(resolve(), 'galleryLeftToRight');
      detect(ComicLayout.paged);
      expect(resolve(), 'galleryRightToLeft');
      detect(ComicLayout.longStrip);
      expect(resolve(), 'continuousTopToBottom');
      detect(ComicLayout.unknown);
      expect(resolve(), 'galleryLeftToRight');
    },
  );

  test('device preferences override global preferences only when enabled', () {
    settings['autoReaderMode'] = true;
    detect(ComicLayout.longStrip);
    settings.setEnabledDeviceSpecificSettings(true);
    settings.setDeviceReaderSetting(
      'longStripReaderMode',
      'waterfallTopToBottom',
    );
    expect(resolve(), 'waterfallTopToBottom');
    settings.setDeviceReaderSetting('autoReaderMode', false);
    expect(resolve(), 'galleryLeftToRight');
    settings.setEnabledDeviceSpecificSettings(false);
    expect(resolve(), 'continuousTopToBottom');
  });

  test('explicit comic mode wins independently of other comic settings', () {
    settings['autoReaderMode'] = true;
    detect(ComicLayout.longStrip);
    settings.setComicReaderModeOverride(cid, source, 'galleryTopToBottom');
    expect(resolve(), 'galleryTopToBottom');
    settings.setEnabledComicSpecificSettings(cid, source, true);
    settings.setEnabledComicSpecificSettings(cid, source, false);
    expect(resolve(), 'galleryTopToBottom');
    settings.setComicReaderModeOverride(cid, source, null);
    expect(resolve(), 'continuousTopToBottom');
  });

  for (final enabled in [true, false]) {
    test(
      'legacy comic mode retains meaning when enabled=$enabled is toggled',
      () {
        settings['autoReaderMode'] = true;
        detect(ComicLayout.longStrip);
        settings['comicSpecificSettings'] = <String, dynamic>{
          '$cid@$source': <String, dynamic>{
            'enabled': enabled,
            'readerMode': 'galleryTopToBottom',
          },
        };
        final expected = enabled
            ? 'galleryTopToBottom'
            : 'continuousTopToBottom';
        expect(resolve(), expected);
        settings.setEnabledComicSpecificSettings(cid, source, !enabled);
        expect(resolve(), expected);
        settings.setComicReaderModeOverride(cid, source, null);
        expect(resolve(), 'continuousTopToBottom');
      },
    );
  }

  test(
    'detection cache is scoped to source and ignores old classifier versions',
    () {
      settings['autoReaderMode'] = true;
      detect(ComicLayout.longStrip);
      expect(
        settings.resolveReaderMode(cid, 'different-source'),
        'galleryLeftToRight',
      );
      settings['comicLayoutDetections'] = <String, dynamic>{
        '$cid@$source': {'layout': 'longStrip', 'samples': 6, 'version': 0},
      };
      expect(resolve(), 'galleryLeftToRight');
    },
  );
}
