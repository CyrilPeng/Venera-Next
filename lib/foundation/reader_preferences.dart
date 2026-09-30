/// Typed storage keys shared by settings forms and immutable reader snapshots.
sealed class ReaderPreference<T extends Object> {
  const ReaderPreference(this.key, this.defaultValue);
  final String key;
  final T defaultValue;
  Object? get storageDefault => defaultValue;
  T normalize(Object? value);
}

final class BoolReaderPreference extends ReaderPreference<bool> {
  const BoolReaderPreference(super.key, super.defaultValue);
  @override
  bool normalize(Object? value) => value is bool ? value : defaultValue;
}

final class ChoiceReaderPreference extends ReaderPreference<String> {
  const ChoiceReaderPreference(
    super.key,
    super.defaultValue,
    this.choices, {
    this.legacyNullDefault = false,
  });
  final List<String> choices;
  final bool legacyNullDefault;
  @override
  Object? get storageDefault => legacyNullDefault ? null : defaultValue;
  @override
  String normalize(Object? value) =>
      value is String && choices.contains(value) ? value : defaultValue;
}

final class NumericReaderPreference extends ReaderPreference<num> {
  const NumericReaderPreference(
    super.key,
    super.defaultValue, {
    required this.min,
    required this.max,
    required this.step,
    this.integer = false,
  });
  final double min;
  final double max;
  final double step;
  final bool integer;
  @override
  num normalize(Object? value) {
    final number = value is num && value.isFinite ? value : defaultValue;
    final bounded = number.toDouble().clamp(min, max);
    return integer ? bounded.toInt() : bounded;
  }
}

abstract final class ReaderPreferences {
  static const modes = [
    'waterfallTopToBottom',
    'galleryLeftToRight',
    'galleryRightToLeft',
    'galleryTopToBottom',
    'continuousTopToBottom',
    'continuousLeftToRight',
    'continuousRightToLeft',
  ];
  static const readerMode = ChoiceReaderPreference(
    'readerMode',
    'waterfallTopToBottom',
    modes,
  );
  static const pagedReaderMode = ChoiceReaderPreference(
    'pagedReaderMode',
    'galleryRightToLeft',
    modes,
  );
  static const longStripReaderMode = ChoiceReaderPreference(
    'longStripReaderMode',
    'continuousTopToBottom',
    modes,
  );
  static const quickCollectImage = ChoiceReaderPreference(
    'quickCollectImage',
    'No',
    ['No', 'DoubleTap', 'Swipe'],
  );
  static const autoReaderMode = BoolReaderPreference('autoReaderMode', false);
  static const longPressAction = ChoiceReaderPreference(
    'longPressAction',
    'zoom',
    ['zoom', 'autoReading', 'none'],
    legacyNullDefault: true,
  );
  static const longPressZoomPosition = ChoiceReaderPreference(
    'longPressZoomPosition',
    'press',
    ['press', 'center'],
  );
  static const autoScrollStyle = ChoiceReaderPreference(
    'autoScrollStyle',
    'smooth',
    ['smooth', 'stepped'],
  );
  static const eInkRefreshStyle = ChoiceReaderPreference(
    'eInkRefreshStyle',
    'black',
    ['black', 'white', 'whiteThenBlack'],
  );
  static const autoPageTurningInterval = NumericReaderPreference(
    'autoPageTurningInterval',
    5,
    min: 1,
    max: 20,
    step: 1,
    integer: false,
  );
  static const autoScrollSpeed = NumericReaderPreference(
    'autoScrollSpeed',
    80,
    min: 10,
    max: 1000,
    step: 10,
    integer: false,
  );
  static const autoScrollFrequency = NumericReaderPreference(
    'autoScrollFrequency',
    2,
    min: 1,
    max: 10,
    step: 1,
    integer: false,
  );
  static const autoScrollDistance = NumericReaderPreference(
    'autoScrollDistance',
    40,
    min: 10,
    max: 500,
    step: 10,
    integer: false,
  );
  static const readerScrollSpeed = NumericReaderPreference(
    'readerScrollSpeed',
    1,
    min: 0.5,
    max: 3,
    step: 0.1,
    integer: false,
  );
  static const readerSideMargin = NumericReaderPreference(
    'readerSideMargin',
    0,
    min: 0,
    max: 30,
    step: 1,
    integer: false,
  );
  static const readerBrightness = NumericReaderPreference(
    'readerBrightness',
    50,
    min: 20,
    max: 100,
    step: 1,
    integer: false,
  );
  static const readerScreenPicNumberForPortrait = NumericReaderPreference(
    'readerScreenPicNumberForPortrait',
    1,
    min: 1,
    max: 5,
    step: 1,
    integer: true,
  );
  static const readerScreenPicNumberForLandscape = NumericReaderPreference(
    'readerScreenPicNumberForLandscape',
    1,
    min: 1,
    max: 5,
    step: 1,
    integer: true,
  );
  static const eInkRefreshDuration = NumericReaderPreference(
    'eInkRefreshDuration',
    100,
    min: 100,
    max: 1500,
    step: 100,
    integer: true,
  );
  static const eInkRefreshInterval = NumericReaderPreference(
    'eInkRefreshInterval',
    1,
    min: 1,
    max: 10,
    step: 1,
    integer: true,
  );
  static const preloadImageCount = NumericReaderPreference(
    'preloadImageCount',
    4,
    min: 1,
    max: 16,
    step: 1,
    integer: true,
  );
  static const autoReadingAcrossChapters = BoolReaderPreference(
    'autoReadingAcrossChapters',
    true,
  );
  static const autoReadingPauseOnLongPress = BoolReaderPreference(
    'autoReadingPauseOnLongPress',
    true,
  );
  static const enableTapToTurnPages = BoolReaderPreference(
    'enableTapToTurnPages',
    true,
  );
  static const reverseTapToTurnPages = BoolReaderPreference(
    'reverseTapToTurnPages',
    false,
  );
  static const enablePageAnimation = BoolReaderPreference(
    'enablePageAnimation',
    true,
  );
  static const readerBrightnessEnabled = BoolReaderPreference(
    'readerBrightnessEnabled',
    false,
  );
  static const eInkRefreshEnabled = BoolReaderPreference(
    'eInkRefreshEnabled',
    false,
  );
  static const limitImageWidth = BoolReaderPreference('limitImageWidth', true);
  static const enableTurnPageByVolumeKey = BoolReaderPreference(
    'enableTurnPageByVolumeKey',
    true,
  );
  static const enableClockAndBatteryInfoInReader = BoolReaderPreference(
    'enableClockAndBatteryInfoInReader',
    true,
  );
  static const showPageNumberInReader = BoolReaderPreference(
    'showPageNumberInReader',
    true,
  );
  static const showSingleImageOnFirstPage = BoolReaderPreference(
    'showSingleImageOnFirstPage',
    false,
  );
  static const enableDoubleTapToZoom = BoolReaderPreference(
    'enableDoubleTapToZoom',
    true,
  );
  static const showSystemStatusBar = BoolReaderPreference(
    'showSystemStatusBar',
    false,
  );
  static const showChapterComments = BoolReaderPreference(
    'showChapterComments',
    true,
  );
  static const showChapterCommentsAtEnd = BoolReaderPreference(
    'showChapterCommentsAtEnd',
    false,
  );
  static const splitDualPage = BoolReaderPreference('splitDualPage', false);
  static const splitDualPageInvert = BoolReaderPreference(
    'splitDualPageInvert',
    false,
  );
  static const all = <ReaderPreference<Object>>[
    readerMode,
    pagedReaderMode,
    longStripReaderMode,
    quickCollectImage,
    autoReaderMode,
    longPressAction,
    longPressZoomPosition,
    autoScrollStyle,
    eInkRefreshStyle,
    autoPageTurningInterval,
    autoScrollSpeed,
    autoScrollFrequency,
    autoScrollDistance,
    readerScrollSpeed,
    readerSideMargin,
    readerBrightness,
    readerScreenPicNumberForPortrait,
    readerScreenPicNumberForLandscape,
    eInkRefreshDuration,
    eInkRefreshInterval,
    preloadImageCount,
    autoReadingAcrossChapters,
    autoReadingPauseOnLongPress,
    enableTapToTurnPages,
    reverseTapToTurnPages,
    enablePageAnimation,
    readerBrightnessEnabled,
    eInkRefreshEnabled,
    limitImageWidth,
    enableTurnPageByVolumeKey,
    enableClockAndBatteryInfoInReader,
    showPageNumberInReader,
    showSingleImageOnFirstPage,
    enableDoubleTapToZoom,
    showSystemStatusBar,
    showChapterComments,
    showChapterCommentsAtEnd,
    splitDualPage,
    splitDualPageInvert,
  ];
  static Map<String, Object?> get storageDefaults => {
    for (final preference in all) preference.key: preference.storageDefault,
  };
}
