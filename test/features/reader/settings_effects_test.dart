import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/settings_effects.dart';
import 'package:venera_next/foundation/reader_preferences.dart';

void main() {
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
