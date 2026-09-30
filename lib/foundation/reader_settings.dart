import 'comic_layout.dart';
import 'reader_preferences.dart';

/// Immutable, validated effective settings. Storage keys remain compatible with
/// existing JSON; UI and reading policies consume named, typed properties.
class ReaderSettings {
  ReaderSettings._(Map<String, Object?> values)
    : _values = Map.unmodifiable(values);

  final Map<String, Object?> _values;

  factory ReaderSettings.resolve({
    required Map global,
    Map? device,
    Map? comic,
    ComicLayout layout = ComicLayout.unknown,
  }) {
    final deviceEnabled = device?['enabled'] == true;
    final comicEnabled = comic?['enabled'] == true;
    Object? deviceValue(String key) =>
        (deviceEnabled ? device![key] : null) ?? global[key];
    final values = <String, Object?>{};
    for (final entry in _fields.entries) {
      final raw =
          (comicEnabled ? comic![entry.key] : null) ?? deviceValue(entry.key);
      values[entry.key] = entry.value.normalize(raw);
    }

    // Manual comic mode is independent of the other-settings switch. An
    // explicit default/invalid override must not revive the old readerMode.
    final Object? override;
    if (comic?.containsKey('readerModeOverride') == true) {
      final value = comic?['readerModeOverride'];
      override = value is String && value != 'default' ? value : null;
    } else {
      final value = comicEnabled ? comic!['readerMode'] : null;
      override = value is String ? value : null;
    }
    final modeKey = deviceValue('autoReaderMode') == true
        ? switch (layout) {
            ComicLayout.paged => 'pagedReaderMode',
            ComicLayout.longStrip => 'longStripReaderMode',
            ComicLayout.unknown => 'readerMode',
          }
        : 'readerMode';
    values['readerMode'] = _mode(override ?? deviceValue(modeKey));
    values['autoReaderMode'] = deviceValue('autoReaderMode') == true;
    values['longPressAction'] =
        (comicEnabled ? _legacyAction(comic) : null) ??
        (deviceEnabled ? _legacyAction(device) : null) ??
        _legacyAction(global) ??
        'zoom';
    return ReaderSettings._(values);
  }

  static String? _legacyAction(Map? values) {
    final action = values?['longPressAction'];
    if (const ['zoom', 'autoReading', 'none'].contains(action)) {
      return action as String;
    }
    final legacy = values?['enableLongPressToZoom'];
    return legacy is bool ? (legacy ? 'zoom' : 'none') : null;
  }

  static String _mode(Object? value) =>
      ReaderPreferences.readerMode.normalize(value);

  static final _fields = {
    for (final preference in ReaderPreferences.all) preference.key: preference,
  };

  T read<T extends Object>(ReaderPreference<T> preference) =>
      preference.normalize(_values[preference.key]);

  String get readerMode => _values['readerMode'] as String;
  String get quickCollectImage => _values['quickCollectImage'] as String;
  String get longPressAction => _values['longPressAction'] as String;
  String get longPressZoomPosition =>
      _values['longPressZoomPosition'] as String;
  String get autoScrollStyle => _values['autoScrollStyle'] as String;
  String get eInkRefreshStyle => _values['eInkRefreshStyle'] as String;
  double get autoPageTurningInterval =>
      _values['autoPageTurningInterval'] as double;
  double get autoScrollSpeed => _values['autoScrollSpeed'] as double;
  double get autoScrollFrequency => _values['autoScrollFrequency'] as double;
  double get autoScrollDistance => _values['autoScrollDistance'] as double;
  double get readerScrollSpeed => _values['readerScrollSpeed'] as double;
  double get readerSideMargin => _values['readerSideMargin'] as double;
  double get readerBrightness => _values['readerBrightness'] as double;
  int get readerScreenPicNumberForPortrait =>
      _values['readerScreenPicNumberForPortrait'] as int;
  int get readerScreenPicNumberForLandscape =>
      _values['readerScreenPicNumberForLandscape'] as int;
  int get eInkRefreshDuration => _values['eInkRefreshDuration'] as int;
  int get eInkRefreshInterval => _values['eInkRefreshInterval'] as int;
  int get preloadImageCount => _values['preloadImageCount'] as int;
  bool get autoReaderMode => _values['autoReaderMode'] as bool;
  bool get autoReadingAcrossChapters =>
      _values['autoReadingAcrossChapters'] as bool;
  bool get autoReadingPauseOnLongPress =>
      _values['autoReadingPauseOnLongPress'] as bool;
  bool get enableTapToTurnPages => _values['enableTapToTurnPages'] as bool;
  bool get reverseTapToTurnPages => _values['reverseTapToTurnPages'] as bool;
  bool get enablePageAnimation => _values['enablePageAnimation'] as bool;
  bool get readerBrightnessEnabled =>
      _values['readerBrightnessEnabled'] as bool;
  bool get eInkRefreshEnabled => _values['eInkRefreshEnabled'] as bool;
  bool get limitImageWidth => _values['limitImageWidth'] as bool;
  bool get enableTurnPageByVolumeKey =>
      _values['enableTurnPageByVolumeKey'] as bool;
  bool get enableClockAndBatteryInfoInReader =>
      _values['enableClockAndBatteryInfoInReader'] as bool;
  bool get showPageNumberInReader => _values['showPageNumberInReader'] as bool;
  bool get showSingleImageOnFirstPage =>
      _values['showSingleImageOnFirstPage'] as bool;
  bool get enableDoubleTapToZoom => _values['enableDoubleTapToZoom'] as bool;
  bool get showSystemStatusBar => _values['showSystemStatusBar'] as bool;
  bool get showChapterComments => _values['showChapterComments'] as bool;
  bool get showChapterCommentsAtEnd =>
      _values['showChapterCommentsAtEnd'] as bool;
  bool get splitDualPage => _values['splitDualPage'] as bool;
  bool get splitDualPageInvert => _values['splitDualPageInvert'] as bool;
}
