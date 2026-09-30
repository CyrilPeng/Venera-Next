import 'package:venera_next/foundation/reader_preferences.dart';

/// Ordered effects of the settings form's legacy string-key notification.
/// Resolution is UI-free; the reader host applies effects to its current state.
enum ReaderSettingEffect {
  applyMode,
  rebindImageGesture,
  detectLayout,
  updateVolumeListener,
  resetEInk,
  updateSystemUi,
  rebuildShell,
  rebuildReader,
}

Iterable<ReaderSettingEffect> readerSettingEffects(String key) sync* {
  if (key == ReaderPreferences.readerMode.key) {
    yield ReaderSettingEffect.applyMode;
    yield ReaderSettingEffect.rebindImageGesture;
    yield ReaderSettingEffect.detectLayout;
  }
  if (key == ReaderPreferences.enableTurnPageByVolumeKey.key) {
    yield ReaderSettingEffect.updateVolumeListener;
  }
  if (key == ReaderPreferences.quickCollectImage.key) {
    yield ReaderSettingEffect.rebindImageGesture;
  }
  if (key.startsWith('eInkRefresh')) yield ReaderSettingEffect.resetEInk;
  if (key == ReaderPreferences.showSystemStatusBar.key) {
    yield ReaderSettingEffect.updateSystemUi;
  }
  if (key.startsWith('readerBrightness') ||
      key == ReaderPreferences.showChapterComments.key ||
      key == ReaderPreferences.showChapterCommentsAtEnd.key ||
      key == ReaderPreferences.showSystemStatusBar.key ||
      key == ReaderPreferences.showPageNumberInReader.key ||
      key == ReaderPreferences.enableClockAndBatteryInfoInReader.key) {
    yield ReaderSettingEffect.rebuildShell;
  }
  // Other settings (including future keys) still update view configuration.
  yield ReaderSettingEffect.rebuildReader;
}
