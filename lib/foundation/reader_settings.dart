import 'comic_layout.dart';

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
      values[entry.key] = entry.value(raw);
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

  static Object _boolean(Object? value, bool fallback) =>
      value is bool ? value : fallback;

  static double _number(
    Object? value,
    double fallback,
    double min,
    double max,
  ) {
    if (value is! num || !value.isFinite) return fallback;
    return value.toDouble().clamp(min, max);
  }

  static int _integer(Object? value, int fallback, int min, int max) => _number(
    value,
    fallback.toDouble(),
    min.toDouble(),
    max.toDouble(),
  ).toInt();

  static String _choice(Object? value, String fallback, List<String> choices) =>
      value is String && choices.contains(value) ? value : fallback;

  static String _mode(Object? value) => _choice(value, 'waterfallTopToBottom', [
    'waterfallTopToBottom',
    'galleryLeftToRight',
    'galleryRightToLeft',
    'galleryTopToBottom',
    'continuousTopToBottom',
    'continuousLeftToRight',
    'continuousRightToLeft',
  ]);

  static final Map<String, Object Function(Object?)> _fields = {
    'quickCollectImage': (v) => _choice(v, 'No', ['No', 'DoubleTap', 'Swipe']),
    'readerMode': _mode,
    'autoReaderMode': (v) => _boolean(v, false),
    'longPressAction': (v) =>
        _choice(v, 'zoom', ['zoom', 'autoReading', 'none']),
    'longPressZoomPosition': (v) => _choice(v, 'press', ['press', 'center']),
    'autoScrollStyle': (v) => _choice(v, 'smooth', ['smooth', 'stepped']),
    'eInkRefreshStyle': (v) =>
        _choice(v, 'black', ['black', 'white', 'whiteThenBlack']),
    'autoPageTurningInterval': (v) => _number(v, 5, 1, 20),
    'autoScrollSpeed': (v) => _number(v, 80, 10, 1000),
    'autoScrollFrequency': (v) => _number(v, 2, 1, 10),
    'autoScrollDistance': (v) => _number(v, 40, 10, 500),
    'readerScrollSpeed': (v) => _number(v, 1, 0.5, 3),
    'readerSideMargin': (v) => _number(v, 0, 0, 30),
    'readerBrightness': (v) => _number(v, 50, 20, 100),
    'readerScreenPicNumberForPortrait': (v) => _integer(v, 1, 1, 5),
    'readerScreenPicNumberForLandscape': (v) => _integer(v, 1, 1, 5),
    'eInkRefreshDuration': (v) => _integer(v, 100, 100, 1500),
    'eInkRefreshInterval': (v) => _integer(v, 1, 1, 10),
    'preloadImageCount': (v) => _integer(v, 4, 1, 16),
    'autoReadingAcrossChapters': (v) => _boolean(v, true),
    'autoReadingPauseOnLongPress': (v) => _boolean(v, true),
    'enableTapToTurnPages': (v) => _boolean(v, true),
    'reverseTapToTurnPages': (v) => _boolean(v, false),
    'enablePageAnimation': (v) => _boolean(v, true),
    'readerBrightnessEnabled': (v) => _boolean(v, false),
    'eInkRefreshEnabled': (v) => _boolean(v, false),
    'limitImageWidth': (v) => _boolean(v, true),
    'enableTurnPageByVolumeKey': (v) => _boolean(v, true),
    'enableClockAndBatteryInfoInReader': (v) => _boolean(v, true),
    'showPageNumberInReader': (v) => _boolean(v, true),
    'showSingleImageOnFirstPage': (v) => _boolean(v, false),
    'enableDoubleTapToZoom': (v) => _boolean(v, true),
    'showSystemStatusBar': (v) => _boolean(v, false),
    'showChapterComments': (v) => _boolean(v, true),
    'showChapterCommentsAtEnd': (v) => _boolean(v, false),
    'splitDualPage': (v) => _boolean(v, false),
    'splitDualPageInvert': (v) => _boolean(v, false),
  };

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
