import 'preferences.dart';

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
  static const readerMode = ChoicePreference(
    'readerMode',
    'waterfallTopToBottom',
    modes,
  );
  static const pagedReaderMode = ChoicePreference(
    'pagedReaderMode',
    'galleryRightToLeft',
    modes,
  );
  static const longStripReaderMode = ChoicePreference(
    'longStripReaderMode',
    'continuousTopToBottom',
    modes,
  );
  static const quickCollectImage = ChoicePreference('quickCollectImage', 'No', [
    'No',
    'DoubleTap',
    'Swipe',
  ]);
  static const autoReaderMode = BoolPreference('autoReaderMode', false);
  static const longPressAction = ChoicePreference('longPressAction', 'zoom', [
    'zoom',
    'autoReading',
    'none',
  ], legacyNullDefault: true);
  static const longPressZoomPosition = ChoicePreference(
    'longPressZoomPosition',
    'press',
    ['press', 'center'],
  );
  static const autoScrollStyle = ChoicePreference('autoScrollStyle', 'smooth', [
    'smooth',
    'stepped',
  ]);
  static const eInkRefreshStyle = ChoicePreference(
    'eInkRefreshStyle',
    'black',
    ['black', 'white', 'whiteThenBlack'],
  );
  static const autoPageTurningInterval = NumericPreference(
    'autoPageTurningInterval',
    5,
    min: 1,
    max: 20,
    step: 1,
    integer: false,
  );
  static const autoScrollSpeed = NumericPreference(
    'autoScrollSpeed',
    80,
    min: 10,
    max: 1000,
    step: 10,
    integer: false,
  );
  static const autoScrollFrequency = NumericPreference(
    'autoScrollFrequency',
    2,
    min: 1,
    max: 10,
    step: 1,
    integer: false,
  );
  static const autoScrollDistance = NumericPreference(
    'autoScrollDistance',
    40,
    min: 10,
    max: 500,
    step: 10,
    integer: false,
  );
  static const readerScrollSpeed = NumericPreference(
    'readerScrollSpeed',
    1,
    min: 0.5,
    max: 3,
    step: 0.1,
    integer: false,
  );
  static const readerSideMargin = NumericPreference(
    'readerSideMargin',
    0,
    min: 0,
    max: 30,
    step: 1,
    integer: false,
  );
  static const readerBrightness = NumericPreference(
    'readerBrightness',
    50,
    min: 20,
    max: 100,
    step: 1,
    integer: false,
  );
  static const readerScreenPicNumberForPortrait = NumericPreference(
    'readerScreenPicNumberForPortrait',
    1,
    min: 1,
    max: 5,
    step: 1,
    integer: true,
  );
  static const readerScreenPicNumberForLandscape = NumericPreference(
    'readerScreenPicNumberForLandscape',
    1,
    min: 1,
    max: 5,
    step: 1,
    integer: true,
  );
  static const eInkRefreshDuration = NumericPreference(
    'eInkRefreshDuration',
    100,
    min: 100,
    max: 1500,
    step: 100,
    integer: true,
  );
  static const eInkRefreshInterval = NumericPreference(
    'eInkRefreshInterval',
    1,
    min: 1,
    max: 10,
    step: 1,
    integer: true,
  );
  static const preloadImageCount = NumericPreference(
    'preloadImageCount',
    4,
    min: 1,
    max: 16,
    step: 1,
    integer: true,
  );
  static const autoReadingAcrossChapters = BoolPreference(
    'autoReadingAcrossChapters',
    true,
  );
  static const autoReadingPauseOnLongPress = BoolPreference(
    'autoReadingPauseOnLongPress',
    true,
  );
  static const enableTapToTurnPages = BoolPreference(
    'enableTapToTurnPages',
    true,
  );
  static const reverseTapToTurnPages = BoolPreference(
    'reverseTapToTurnPages',
    false,
  );
  static const enablePageAnimation = BoolPreference(
    'enablePageAnimation',
    true,
  );
  static const readerBrightnessEnabled = BoolPreference(
    'readerBrightnessEnabled',
    false,
  );
  static const eInkRefreshEnabled = BoolPreference('eInkRefreshEnabled', false);
  static const limitImageWidth = BoolPreference('limitImageWidth', true);
  static const enableTurnPageByVolumeKey = BoolPreference(
    'enableTurnPageByVolumeKey',
    true,
  );
  static const enableClockAndBatteryInfoInReader = BoolPreference(
    'enableClockAndBatteryInfoInReader',
    true,
  );
  static const showPageNumberInReader = BoolPreference(
    'showPageNumberInReader',
    true,
  );
  static const showSingleImageOnFirstPage = BoolPreference(
    'showSingleImageOnFirstPage',
    false,
  );
  static const enableDoubleTapToZoom = BoolPreference(
    'enableDoubleTapToZoom',
    true,
  );
  static const showSystemStatusBar = BoolPreference(
    'showSystemStatusBar',
    false,
  );
  static const showChapterComments = BoolPreference(
    'showChapterComments',
    true,
  );
  static const showChapterCommentsAtEnd = BoolPreference(
    'showChapterCommentsAtEnd',
    false,
  );
  static const splitDualPage = BoolPreference('splitDualPage', false);
  static const splitDualPageInvert = BoolPreference(
    'splitDualPageInvert',
    false,
  );
  static const all = <Preference<Object>>[
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
