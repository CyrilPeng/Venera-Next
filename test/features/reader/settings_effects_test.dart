import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/settings_effects.dart';
import 'package:venera_next/foundation/reader_preferences.dart';

void main() {
  test('settings request keeps ordered reader and shell effects', () {
    final effects = <String>[];
    final request = ReaderSettingsRequest(
      comicId: 'book',
      sourceKey: 'source',
      isCurrent: () => true,
      currentMode: () => 'galleryLeftToRight',
      isDetectingLayout: () => false,
      detectLayout: () async {},
      applyReaderEffect: (effect) => effects.add('reader:${effect.name}'),
    );
    void apply(String key) => request.apply(
      key,
      applyShellEffect: (effect) => effects.add('shell:${effect.name}'),
    );
    apply('readerMode');
    expect(effects, [
      'reader:applyMode',
      'shell:rebindImageGesture',
      'reader:detectLayout',
      'reader:rebuildReader',
    ]);
    effects.clear();
    apply('showSystemStatusBar');
    expect(effects, [
      'shell:updateSystemUi',
      'shell:rebuildShell',
      'reader:rebuildReader',
    ]);
    effects.clear();
    apply('enableTurnPageByVolumeKey');
    apply('futureReaderOption');
    expect(effects, [
      'reader:updateVolumeListener',
      'reader:rebuildReader',
      'reader:rebuildReader',
    ]);
  });

  for (final invalidateAt in [0, 1]) {
    test(
      'settings request stops after adapter $invalidateAt changes target',
      () {
        final effects = <ReaderSettingEffect>[];
        var current = true;
        void record(ReaderSettingEffect effect) {
          effects.add(effect);
          if (effects.length == invalidateAt + 1) current = false;
        }

        final request = ReaderSettingsRequest(
          comicId: 'book',
          sourceKey: 'source',
          isCurrent: () => current,
          currentMode: () => 'galleryLeftToRight',
          isDetectingLayout: () => false,
          detectLayout: () async {},
          applyReaderEffect: record,
        );
        request.apply('readerMode', applyShellEffect: record);
        expect(effects, [
          ReaderSettingEffect.applyMode,
          if (invalidateAt == 1) ReaderSettingEffect.rebindImageGesture,
        ]);
        request.apply('readerMode', applyShellEffect: record);
        expect(effects.length, invalidateAt + 1);
      },
    );
  }

  test(
    'retired settings do not read new state or restart actual detection',
    () async {
      var current = true;
      var mode = 'galleryLeftToRight';
      var started = 0;
      final detection = Completer<void>();
      final request = ReaderSettingsRequest(
        comicId: 'book',
        sourceKey: 'source',
        isCurrent: () => current,
        currentMode: () => mode,
        isDetectingLayout: () => true,
        detectLayout: () {
          started++;
          return detection.future;
        },
        applyReaderEffect: (_) => fail('Retired settings applied an effect'),
      );
      expect(request.isDetectingLayout, isTrue);
      var finished = false;
      final pending = request.detectLayout().then((_) => finished = true);
      current = false;
      mode = 'continuousTopToBottom';
      expect(request.currentMode, 'galleryLeftToRight');
      expect(request.isDetectingLayout, isFalse);
      await request.detectLayout();
      expect(started, 1);
      expect(finished, isFalse);
      request.apply(
        'readerMode',
        applyShellEffect: (_) => fail('Shell effect'),
      );
      detection.complete();
      await pending;
      expect(finished, isTrue);
    },
  );

  test(
    'every registered and unknown setting refreshes view inputs exactly once',
    () {
      for (final key in [
        ...ReaderPreferences.all.map((preference) => preference.key),
        'futureReaderOption',
        'readerBrightnessFutureOption',
        'eInkRefreshFutureOption',
      ]) {
        final effects = readerSettingEffects(key).toList();
        expect(effects.last, ReaderSettingEffect.rebuildReader, reason: key);
        expect(effects.toSet().length, effects.length, reason: key);
        if (effects.contains(ReaderSettingEffect.updateSystemUi)) {
          expect(
            effects.indexOf(ReaderSettingEffect.updateSystemUi),
            lessThan(effects.indexOf(ReaderSettingEffect.rebuildShell)),
          );
        }
      }
    },
  );

  test('mode change applies before gesture rebinding and layout detection', () {
    final effects = readerSettingEffects(
      ReaderPreferences.readerMode.key,
    ).toList();
    expect(effects, [
      ReaderSettingEffect.applyMode,
      ReaderSettingEffect.rebindImageGesture,
      ReaderSettingEffect.detectLayout,
      ReaderSettingEffect.rebuildReader,
    ]);
    // A gesture-only change must not restart detection or change the mode.
    final gesture = readerSettingEffects(
      ReaderPreferences.quickCollectImage.key,
    );
    expect(gesture, isNot(contains(ReaderSettingEffect.applyMode)));
    expect(gesture, isNot(contains(ReaderSettingEffect.detectLayout)));
  });
}
