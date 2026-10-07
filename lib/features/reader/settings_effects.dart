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

/// Settings callbacks bound to the original comic and reader session.
/// Persistence remains owned by SettingsSaveState and the reader's ImageWork.
class ReaderSettingsRequest {
  ReaderSettingsRequest({
    required this.comicId,
    required this.sourceKey,
    required this.isCurrent,
    required String Function() currentMode,
    required bool Function() isDetectingLayout,
    required Future<void> Function() detectLayout,
    required void Function(ReaderSettingEffect) applyReaderEffect,
  }) : _currentMode = currentMode,
       _initialMode = currentMode(),
       _isDetectingLayout = isDetectingLayout,
       _detectLayout = detectLayout,
       _applyReaderEffect = applyReaderEffect;

  final String comicId;
  final String sourceKey;
  final bool Function() isCurrent;
  final String _initialMode;
  final String Function() _currentMode;
  final bool Function() _isDetectingLayout;
  final Future<void> Function() _detectLayout;
  final void Function(ReaderSettingEffect) _applyReaderEffect;

  String get currentMode => isCurrent() ? _currentMode() : _initialMode;
  bool get isDetectingLayout => isCurrent() && _isDetectingLayout();
  Future<void> detectLayout() => isCurrent() ? _detectLayout() : Future.value();

  void apply(
    String key, {
    required void Function(ReaderSettingEffect) applyShellEffect,
  }) {
    for (final effect in readerSettingEffects(key)) {
      // Either adapter may synchronously close or replace the original reader.
      if (!isCurrent()) return;
      switch (effect) {
        case ReaderSettingEffect.applyMode:
        case ReaderSettingEffect.detectLayout:
        case ReaderSettingEffect.updateVolumeListener:
        case ReaderSettingEffect.rebuildReader:
          _applyReaderEffect(effect);
        case ReaderSettingEffect.rebindImageGesture:
        case ReaderSettingEffect.resetEInk:
        case ReaderSettingEffect.updateSystemUi:
        case ReaderSettingEffect.rebuildShell:
          applyShellEffect(effect);
      }
    }
  }
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
