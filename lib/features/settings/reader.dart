import 'package:venera_next/foundation/preferences.dart';
import 'package:venera_next/foundation/reader_preferences.dart';
import 'package:venera_next/foundation/reader_preference_store.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/code.dart';
import 'package:venera_next/components/layout.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/reader/brightness.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/features/settings/reader_mode.dart';
import 'package:venera_next/features/settings/reader_brightness.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

class ReaderSettings extends StatefulWidget {
  const ReaderSettings({
    super.key,
    this.onChanged,
    this.comicId,
    this.comicSource,
    this.currentReaderMode,
    this.isDetectingLayout,
    this.onDetectLayout,
    this.brightnessPreview,
  });

  final void Function(String key)? onChanged;
  final String? comicId;
  final String? comicSource;
  final String Function()? currentReaderMode;
  final bool Function()? isDetectingLayout;
  final Future<void> Function()? onDetectLayout;
  final ReaderBrightnessPreview? brightnessPreview;

  @override
  State<ReaderSettings> createState() => _ReaderSettingsState();
}

class _ReaderSettingsState extends SettingsSaveState<ReaderSettings> {
  @override
  void initState() {
    super.initState();
    appdata.settings.addListener(_refresh);
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  ReaderPreferenceStore get _store => ReaderPreferenceStore(
    settings: appdata.settings,
    comicId: widget.comicId,
    sourceKey: widget.comicSource,
  );

  T _value<T extends Object>(Preference<T> preference) {
    if (widget.comicId != null &&
        widget.comicSource != null &&
        identical(preference, ReaderPreferences.readerMode) &&
        widget.currentReaderMode != null) {
      return preference.normalize(widget.currentReaderMode!());
    }
    return _store.read(preference);
  }

  T _deviceValue<T extends Object>(Preference<T> preference) =>
      ReaderPreferenceStore(
        settings: appdata.settings,
        scope: ReaderPreferenceScope.device,
      ).read(preference);

  String get _activeReaderMode => _value(ReaderPreferences.readerMode);

  bool _usesMode(bool Function(String mode) matches) {
    if (matches(_activeReaderMode)) return true;
    if (widget.comicId != null ||
        _deviceValue(ReaderPreferences.autoReaderMode) != true) {
      return false;
    }
    return matches(_deviceValue(ReaderPreferences.pagedReaderMode)) ||
        matches(_deviceValue(ReaderPreferences.longStripReaderMode));
  }

  bool get _isVerticalFlowMode => _usesMode(
    (mode) => mode == 'waterfallTopToBottom' || mode == 'continuousTopToBottom',
  );

  bool _isChapterCommentsAtEndSupported() =>
      _value(ReaderPreferences.showChapterComments) == true &&
      _usesMode(
        (mode) => mode == 'galleryLeftToRight' || mode == 'galleryRightToLeft',
      );

  void _onShowChapterCommentsChanged() {
    setState(() {});
    widget.onChanged?.call('showChapterComments');
  }

  Future<bool> _saveScope(Object key, void Function(Settings) edit) {
    final target = (widget.comicId, widget.comicSource);
    return saveSetting(
      key,
      () => appdata.updateSettings(edit),
      onSaved: () => widget.onChanged?.call('readerMode'),
      isCurrent: () => target == (widget.comicId, widget.comicSource),
    );
  }

  Widget _modeSettings() => ReaderModeSettings(
    comicId: widget.comicId,
    sourceKey: widget.comicSource,
    currentMode: widget.currentReaderMode,
    isDetecting: widget.isDetectingLayout,
    onDetect: widget.onDetectLayout,
    onChanged: () {
      widget.onChanged?.call('readerMode');
      _refresh();
    },
  ).toSliver();

  @override
  Widget build(BuildContext context) {
    final comicId = widget.comicId;
    final sourceKey = widget.comicSource;
    final key = "$comicId@$sourceKey";

    bool isEnabledSpecificSettings =
        comicId != null &&
        appdata.settings.isComicSpecificSettingsEnabled(comicId, sourceKey);
    bool useDeviceSpecificSettings =
        !isEnabledSpecificSettings &&
        appdata.settings.isDeviceSpecificSettingsEnabled();

    return protectSettings(
      SmoothCustomScrollView(
        slivers: [
          SliverAppbar(title: Text("Reading".tl)),
          settingsSaveStatus.toSliver(),
          if (comicId != null) _modeSettings(),
          if (comicId != null && sourceKey != null)
            SliverMainAxisGroup(
              slivers: [
                SwitchListTile(
                  title: Text('Customize other settings for this comic'.tl),
                  value: isEnabledSpecificSettings,
                  onChanged: (b) {
                    _saveScope((comicId, sourceKey, 'scope'), (draft) {
                      draft.setEnabledComicSpecificSettings(
                        comicId,
                        sourceKey,
                        b,
                      );
                    });
                  },
                ).toSliver(),
                if (isEnabledSpecificSettings)
                  Center(
                    child: TextButton(
                      onPressed: () {
                        _saveScope((comicId, sourceKey, 'scope'), (draft) {
                          draft.resetComicReaderSettings(key);
                        });
                      },
                      child: Text('Reset all settings for this comic'.tl),
                    ),
                  ).toSliver(),
                Divider().toSliver(),
              ],
            ),
          if (comicId == null)
            SliverMainAxisGroup(
              slivers: [
                SwitchListTile(
                  title: Text("Enable device specific settings".tl),
                  value: useDeviceSpecificSettings,
                  onChanged: (b) {
                    _saveScope('deviceScope', (draft) {
                      draft.setEnabledDeviceSpecificSettings(b);
                    });
                  },
                ).toSliver(),
                if (useDeviceSpecificSettings)
                  Center(
                    child: TextButton(
                      onPressed: () {
                        _saveScope('deviceScope', (draft) {
                          draft.resetDeviceReaderSettings();
                        });
                      },
                      child: Text(
                        "Clear specific reader settings for this device".tl,
                      ),
                    ),
                  ).toSliver(),
                Divider().toSliver(),
              ],
            ),
          if (comicId == null) _modeSettings(),
          const Divider().toSliver(),
          SwitchSetting.reader(
            title: "Tap to turn Pages".tl,
            preference: ReaderPreferences.enableTapToTurnPages,
            onChanged: () {
              widget.onChanged?.call("enableTapToTurnPages");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
          SwitchSetting.reader(
            title: "Reverse tap to turn Pages".tl,
            preference: ReaderPreferences.reverseTapToTurnPages,
            onChanged: () {
              widget.onChanged?.call("reverseTapToTurnPages");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
          SwitchSetting.reader(
            title: "Page animation".tl,
            preference: ReaderPreferences.enablePageAnimation,
            onChanged: () {
              widget.onChanged?.call("enablePageAnimation");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
          ReaderBrightnessSetting(
            comicId: widget.comicId,
            sourceKey: widget.comicSource,
            preview: widget.brightnessPreview,
            onChanged: widget.onChanged,
          ).toSliver(),
          SwitchSetting.reader(
            title: "E-Ink display refresh".tl,
            subtitle:
                "Flash the screen after page changes to reduce ghosting on E-Ink displays. Only applies to Gallery modes."
                    .tl,
            preference: ReaderPreferences.eInkRefreshEnabled,
            onChanged: () {
              setState(() {});
              widget.onChanged?.call("eInkRefreshEnabled");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
          SliverAnimatedVisibility(
            visible: _value(ReaderPreferences.eInkRefreshEnabled) == true,
            child: Column(
              children: [
                SliderSetting.reader(
                  title: "Refresh flash duration".tl,
                  preference: ReaderPreferences.eInkRefreshDuration,
                  valueFormatter: (value) => '${value.toInt()} ms',
                  onChanged: () {
                    widget.onChanged?.call("eInkRefreshDuration");
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
                SliderSetting.reader(
                  title: "Refresh interval".tl,
                  preference: ReaderPreferences.eInkRefreshInterval,
                  valueFormatter: (value) => value.toInt().toString(),
                  onChanged: () {
                    widget.onChanged?.call("eInkRefreshInterval");
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
                SelectSetting.reader(
                  title: "Refresh flash style".tl,
                  preference: ReaderPreferences.eInkRefreshStyle,
                  optionTranslation: {
                    "black": "Black".tl,
                    "white": "White".tl,
                    "whiteThenBlack": "White then black".tl,
                  },
                  onChanged: () {
                    widget.onChanged?.call("eInkRefreshStyle");
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
              ],
            ),
          ),
          SliderSetting.reader(
            title: "Auto page turning interval (gallery)".tl,
            preference: ReaderPreferences.autoPageTurningInterval,
            valueFormatter: (value) => '${value.toInt()} s',
            onChanged: () => widget.onChanged?.call('autoPageTurningInterval'),
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
          SelectSetting.reader(
            title: 'Automatic scrolling (continuous and waterfall)'.tl,
            preference: ReaderPreferences.autoScrollStyle,
            optionTranslation: {
              'smooth': 'Smooth scrolling'.tl,
              'stepped': 'Step scrolling'.tl,
            },
            onChanged: () {
              setState(() {});
              widget.onChanged?.call('autoScrollStyle');
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
          if (_value(ReaderPreferences.autoScrollStyle) == 'smooth')
            SliderSetting.reader(
              title: "Automatic scroll speed".tl,
              preference: ReaderPreferences.autoScrollSpeed,
              valueFormatter: (value) => '${value.toInt()} px/s',
              onChanged: () => widget.onChanged?.call('autoScrollSpeed'),
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource: isEnabledSpecificSettings
                  ? widget.comicSource
                  : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ).toSliver(),
          if (_value(ReaderPreferences.autoScrollStyle) == 'stepped') ...[
            SliderSetting.reader(
              title: "Scroll steps per second".tl,
              preference: ReaderPreferences.autoScrollFrequency,
              valueFormatter: (value) => '${value.toInt()} /s',
              onChanged: () => widget.onChanged?.call('autoScrollFrequency'),
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource: isEnabledSpecificSettings
                  ? widget.comicSource
                  : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ).toSliver(),
            SliderSetting.reader(
              title: "Distance per scroll step".tl,
              preference: ReaderPreferences.autoScrollDistance,
              valueFormatter: (value) => '${value.toInt()} px',
              onChanged: () => widget.onChanged?.call('autoScrollDistance'),
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource: isEnabledSpecificSettings
                  ? widget.comicSource
                  : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ).toSliver(),
          ],
          SwitchSetting.reader(
            title: 'Continue automatically to the next chapter'.tl,
            preference: ReaderPreferences.autoReadingAcrossChapters,
            onChanged: () =>
                widget.onChanged?.call('autoReadingAcrossChapters'),
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
          SliverAnimatedVisibility(
            visible: _usesMode((mode) => mode.startsWith('gallery')),
            child: SliderSetting.reader(
              title:
                  "The number of pic in screen for landscape (Only Gallery Mode)"
                      .tl,
              preference: ReaderPreferences.readerScreenPicNumberForLandscape,
              onChanged: () {
                setState(() {});
                widget.onChanged?.call("readerScreenPicNumberForLandscape");
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource: isEnabledSpecificSettings
                  ? widget.comicSource
                  : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
          ),
          SliverAnimatedVisibility(
            visible: _usesMode((mode) => mode.startsWith('gallery')),
            child: SliderSetting.reader(
              title:
                  "The number of pic in screen for portrait (Only Gallery Mode)"
                      .tl,
              preference: ReaderPreferences.readerScreenPicNumberForPortrait,
              onChanged: () {
                widget.onChanged?.call("readerScreenPicNumberForPortrait");
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource: isEnabledSpecificSettings
                  ? widget.comicSource
                  : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
          ),
          SliverAnimatedVisibility(
            visible:
                _usesMode((mode) => mode.startsWith('gallery')) &&
                (_value(ReaderPreferences.readerScreenPicNumberForLandscape) >
                        1 ||
                    _value(ReaderPreferences.readerScreenPicNumberForPortrait) >
                        1),
            child: SwitchSetting.reader(
              title: "Show single image on first page".tl,
              preference: ReaderPreferences.showSingleImageOnFirstPage,
              onChanged: () {
                widget.onChanged?.call("showSingleImageOnFirstPage");
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource: isEnabledSpecificSettings
                  ? widget.comicSource
                  : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
          ),
          SliverAnimatedVisibility(
            visible: _usesMode(
              (mode) =>
                  mode.startsWith('continuous') || mode.startsWith('waterfall'),
            ),
            child: SliderSetting.reader(
              title: "Mouse scroll speed".tl,
              preference: ReaderPreferences.readerScrollSpeed,
              onChanged: () {
                widget.onChanged?.call("readerScrollSpeed");
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource: isEnabledSpecificSettings
                  ? widget.comicSource
                  : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
          ),
          SwitchSetting.reader(
            title: 'Double tap to zoom'.tl,
            preference: ReaderPreferences.enableDoubleTapToZoom,
            onChanged: () {
              setState(() {});
              widget.onChanged?.call('enableDoubleTapToZoom');
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
          SelectSetting.reader(
            title: 'Long press action'.tl,
            preference: ReaderPreferences.longPressAction,
            optionTranslation: {
              'zoom': 'Zoom image'.tl,
              'autoReading': 'Start or stop automatic reading'.tl,
              'none': 'No action'.tl,
            },
            onChanged: () {
              setState(() {});
              widget.onChanged?.call('longPressAction');
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
          SliverAnimatedVisibility(
            visible: _value(ReaderPreferences.longPressAction) == 'zoom',
            child: SelectSetting.reader(
              title: "Long press zoom position".tl,
              preference: ReaderPreferences.longPressZoomPosition,
              optionTranslation: {
                "press": "Press position".tl,
                "center": "Screen center".tl,
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource: isEnabledSpecificSettings
                  ? widget.comicSource
                  : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
          ),
          SwitchSetting.reader(
            title: 'Limit image width'.tl,
            subtitle: 'When using Continuous(Top to Bottom) mode'.tl,
            preference: ReaderPreferences.limitImageWidth,
            onChanged: () {
              widget.onChanged?.call('limitImageWidth');
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
          SliverAnimatedVisibility(
            visible: _isVerticalFlowMode,
            child: SliderSetting.reader(
              title: 'Side margins (each side)'.tl,
              preference: ReaderPreferences.readerSideMargin,
              valueFormatter: (value) => '${value.toInt()}%',
              onChanged: () => widget.onChanged?.call('readerSideMargin'),
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource: isEnabledSpecificSettings
                  ? widget.comicSource
                  : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
          ),
          SliverAnimatedVisibility(
            visible: _isVerticalFlowMode,
            child: SwitchSetting.reader(
              title: 'Split dual pages'.tl,
              subtitle:
                  'Only applies to Continuous and Waterfall (Top to Bottom) modes'
                      .tl,
              preference: ReaderPreferences.splitDualPage,
              onChanged: () {
                setState(() {});
                widget.onChanged?.call('splitDualPage');
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource: isEnabledSpecificSettings
                  ? widget.comicSource
                  : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
          ),
          SliverAnimatedVisibility(
            visible:
                _isVerticalFlowMode &&
                _value(ReaderPreferences.splitDualPage) == true,
            child: SwitchSetting.reader(
              title: 'Swap split dual page order'.tl,
              subtitle:
                  'Turn this on when the split page order does not match the reading direction'
                      .tl,
              preference: ReaderPreferences.splitDualPageInvert,
              onChanged: () {
                widget.onChanged?.call('splitDualPageInvert');
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource: isEnabledSpecificSettings
                  ? widget.comicSource
                  : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
          ),
          if (App.isAndroid)
            SwitchSetting.reader(
              title: 'Turn page by volume keys'.tl,
              preference: ReaderPreferences.enableTurnPageByVolumeKey,
              onChanged: () {
                widget.onChanged?.call('enableTurnPageByVolumeKey');
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource: isEnabledSpecificSettings
                  ? widget.comicSource
                  : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ).toSliver(),
          SwitchSetting.reader(
            title: "Display time & battery info in reader".tl,
            preference: ReaderPreferences.enableClockAndBatteryInfoInReader,
            onChanged: () {
              widget.onChanged?.call("enableClockAndBatteryInfoInReader");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
          SwitchSetting.reader(
            title: "Show system status bar".tl,
            preference: ReaderPreferences.showSystemStatusBar,
            onChanged: () {
              widget.onChanged?.call("showSystemStatusBar");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
          SelectSetting.reader(
            title: "Quick collect image".tl,
            preference: ReaderPreferences.quickCollectImage,
            optionTranslation: {
              "No": "Not enable".tl,
              "DoubleTap": "Double Tap".tl,
              "Swipe": "Swipe".tl,
            },
            onChanged: () {
              widget.onChanged?.call("quickCollectImage");
            },
            help:
                "On the image browsing page, you can quickly collect images by sliding horizontally or vertically according to your reading mode"
                    .tl,
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
          CallbackSetting(
            title: "Custom Image Processing".tl,
            callback: () => context.to(() => _CustomImageProcessing()),
            actionTitle: "Edit".tl,
          ).toSliver(),
          SliderSetting.reader(
            title: "Number of images preloaded".tl,
            preference: ReaderPreferences.preloadImageCount,
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
          SwitchSetting.reader(
            title: "Show Page Number".tl,
            preference: ReaderPreferences.showPageNumberInReader,
            onChanged: () {
              widget.onChanged?.call("showPageNumberInReader");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
          SwitchSetting.reader(
            title: "Show Chapter Comments".tl,
            preference: ReaderPreferences.showChapterComments,
            onChanged: _onShowChapterCommentsChanged,
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
          SliverAnimatedVisibility(
            visible: _isChapterCommentsAtEndSupported(),
            child: SwitchSetting.reader(
              title: "Show Comments at Chapter End".tl,
              preference: ReaderPreferences.showChapterCommentsAtEnd,
              onChanged: () {
                widget.onChanged?.call("showChapterCommentsAtEnd");
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource: isEnabledSpecificSettings
                  ? widget.comicSource
                  : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
          ),
        ],
      ),
    );
  }
}

class _CustomImageProcessing extends StatefulWidget {
  const _CustomImageProcessing();

  @override
  State<_CustomImageProcessing> createState() => __CustomImageProcessingState();
}

class __CustomImageProcessingState
    extends SettingsSaveState<_CustomImageProcessing> {
  var current = '';

  @override
  void initState() {
    super.initState();
    current = appdata.settings['customImageProcessing'];
  }

  void _saveCode(String value) {
    if (!acceptsSettingsChanges) return;
    current = value;
    saveSetting(
      'customImageProcessing',
      () => appdata.updateSettings((draft) {
        draft['customImageProcessing'] = value;
      }),
    );
  }

  int resetKey = 0;

  @override
  Widget build(BuildContext context) {
    return protectSettings(
      Scaffold(
        appBar: Appbar(
          title: Text("Custom Image Processing".tl),
          actions: [
            settingsSaveStatus,
            TextButton(
              onPressed: () {
                if (!acceptsSettingsChanges) return;
                _saveCode(defaultCustomImageProcessing);
                resetKey++;
                setState(() {});
              },
              child: Text("Reset".tl),
            ),
          ],
        ),
        body: Column(
          children: [
            SwitchSetting(
              title: "Enable".tl,
              settingKey: "enableCustomImageProcessing",
            ),
            Expanded(
              child: Container(
                margin: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: context.colorScheme.outlineVariant),
                ),
                child: SizedBox.expand(
                  child: CodeEditor(
                    key: ValueKey(resetKey),
                    initialValue: current,
                    onChanged: _saveCode,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
