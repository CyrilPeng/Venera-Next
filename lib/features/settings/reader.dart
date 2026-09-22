import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/code.dart';
import 'package:venera_next/components/layout.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/reader/brightness.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/features/settings/reader_mode.dart';
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
  });

  final void Function(String key)? onChanged;
  final String? comicId;
  final String? comicSource;
  final String Function()? currentReaderMode;
  final bool Function()? isDetectingLayout;
  final Future<void> Function()? onDetectLayout;

  @override
  State<ReaderSettings> createState() => _ReaderSettingsState();
}

class _ReaderSettingsState extends State<ReaderSettings> {
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

  dynamic _value(String key) {
    if (widget.comicId != null && widget.comicSource != null) {
      if (key == 'readerMode' && widget.currentReaderMode != null) {
        return widget.currentReaderMode!();
      }
      return appdata.settings.getReaderSetting(
        widget.comicId!,
        widget.comicSource!,
        key,
      );
    }
    return appdata.settings.getDeviceReaderSetting(key);
  }

  String get _activeReaderMode => _value('readerMode') as String;

  bool _usesMode(bool Function(String mode) matches) {
    if (matches(_activeReaderMode)) return true;
    if (widget.comicId != null ||
        appdata.settings.getDeviceReaderSetting('autoReaderMode') != true) {
      return false;
    }
    return matches(
          appdata.settings.getDeviceReaderSetting('pagedReaderMode'),
        ) ||
        matches(appdata.settings.getDeviceReaderSetting('longStripReaderMode'));
  }

  bool get _isVerticalFlowMode => _usesMode(
    (mode) => mode == 'waterfallTopToBottom' || mode == 'continuousTopToBottom',
  );

  bool _isChapterCommentsAtEndSupported() =>
      _value('showChapterComments') == true &&
      _usesMode(
        (mode) => mode == 'galleryLeftToRight' || mode == 'galleryRightToLeft',
      );

  void _onShowChapterCommentsChanged() {
    if (_value('showChapterComments') != true) {
      appdata.settings.setActiveReaderSetting(
        widget.comicId,
        widget.comicSource,
        'showChapterCommentsAtEnd',
        false,
      );
      appdata.saveData();
    }
    setState(() {});
    widget.onChanged?.call('showChapterComments');
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

    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Reading".tl)),
        if (comicId != null) _modeSettings(),
        if (comicId != null && sourceKey != null)
          SliverMainAxisGroup(
            slivers: [
              SwitchListTile(
                title: Text('Customize other settings for this comic'.tl),
                value: isEnabledSpecificSettings,
                onChanged: (b) {
                  setState(() {
                    appdata.settings.setEnabledComicSpecificSettings(
                      comicId,
                      sourceKey,
                      b,
                    );
                  });
                  appdata.saveData();
                  widget.onChanged?.call('readerMode');
                },
              ).toSliver(),
              if (isEnabledSpecificSettings)
                Center(
                  child: TextButton(
                    onPressed: () {
                      setState(() {
                        appdata.settings.resetComicReaderSettings(key);
                      });
                      appdata.saveData();
                      widget.onChanged?.call('readerMode');
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
                  setState(() {
                    appdata.settings.setEnabledDeviceSpecificSettings(b);
                  });
                  appdata.saveData();
                },
              ).toSliver(),
              if (useDeviceSpecificSettings)
                Center(
                  child: TextButton(
                    onPressed: () {
                      setState(() {
                        appdata.settings.resetDeviceReaderSettings();
                      });
                      appdata.saveData();
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
        SwitchSetting(
          title: "Tap to turn Pages".tl,
          settingKey: "enableTapToTurnPages",
          onChanged: () {
            widget.onChanged?.call("enableTapToTurnPages");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SwitchSetting(
          title: "Reverse tap to turn Pages".tl,
          settingKey: "reverseTapToTurnPages",
          onChanged: () {
            widget.onChanged?.call("reverseTapToTurnPages");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SwitchSetting(
          title: "Page animation".tl,
          settingKey: "enablePageAnimation",
          onChanged: () {
            widget.onChanged?.call("enablePageAnimation");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        ReaderBrightnessControl(
          enabled: _value('readerBrightnessEnabled') == true,
          brightness: _value('readerBrightness'),
          onEnabledChanged: (enabled) {
            appdata.settings.setActiveReaderSetting(
              widget.comicId,
              widget.comicSource,
              'readerBrightnessEnabled',
              enabled,
            );
            setState(() {});
            appdata.saveData();
            widget.onChanged?.call('readerBrightnessEnabled');
          },
          onBrightnessChanged: (brightness) {
            appdata.settings.setActiveReaderSetting(
              widget.comicId,
              widget.comicSource,
              'readerBrightness',
              brightness,
            );
            setState(() {});
            widget.onChanged?.call('readerBrightness');
          },
          onBrightnessChangeEnd: (_) {
            appdata.saveData();
          },
        ).toSliver(),
        SwitchSetting(
          title: "E-Ink display refresh".tl,
          subtitle:
              "Flash the screen after page changes to reduce ghosting on E-Ink displays. Only applies to Gallery modes."
                  .tl,
          settingKey: "eInkRefreshEnabled",
          onChanged: () {
            setState(() {});
            widget.onChanged?.call("eInkRefreshEnabled");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: _value('eInkRefreshEnabled') == true,
          child: Column(
            children: [
              SliderSetting(
                title: "Refresh flash duration".tl,
                settingsIndex: "eInkRefreshDuration",
                interval: 100,
                min: 100,
                max: 1500,
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
              SliderSetting(
                title: "Refresh interval".tl,
                settingsIndex: "eInkRefreshInterval",
                interval: 1,
                min: 1,
                max: 10,
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
              SelectSetting(
                title: "Refresh flash style".tl,
                settingKey: "eInkRefreshStyle",
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
        SliderSetting(
          title: "Auto page turning interval".tl,
          settingsIndex: "autoPageTurningInterval",
          interval: 1,
          min: 1,
          max: 20,
          onChanged: () {
            setState(() {});
            widget.onChanged?.call("autoPageTurningInterval");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: _usesMode((mode) => mode.startsWith('gallery')),
          child: SliderSetting(
            title:
                "The number of pic in screen for landscape (Only Gallery Mode)"
                    .tl,
            settingsIndex: "readerScreenPicNumberForLandscape",
            interval: 1,
            min: 1,
            max: 5,
            onChanged: () {
              setState(() {});
              widget.onChanged?.call("readerScreenPicNumberForLandscape");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SliverAnimatedVisibility(
          visible: _usesMode((mode) => mode.startsWith('gallery')),
          child: SliderSetting(
            title:
                "The number of pic in screen for portrait (Only Gallery Mode)"
                    .tl,
            settingsIndex: "readerScreenPicNumberForPortrait",
            interval: 1,
            min: 1,
            max: 5,
            onChanged: () {
              widget.onChanged?.call("readerScreenPicNumberForPortrait");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SliverAnimatedVisibility(
          visible:
              _usesMode((mode) => mode.startsWith('gallery')) &&
              (_value('readerScreenPicNumberForLandscape') > 1 ||
                  _value('readerScreenPicNumberForPortrait') > 1),
          child: SwitchSetting(
            title: "Show single image on first page".tl,
            settingKey: "showSingleImageOnFirstPage",
            onChanged: () {
              widget.onChanged?.call("showSingleImageOnFirstPage");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SliverAnimatedVisibility(
          visible: _usesMode(
            (mode) =>
                mode.startsWith('continuous') || mode.startsWith('waterfall'),
          ),
          child: SliderSetting(
            title: "Mouse scroll speed".tl,
            settingsIndex: "readerScrollSpeed",
            interval: 0.1,
            min: 0.5,
            max: 3,
            onChanged: () {
              widget.onChanged?.call("readerScrollSpeed");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SwitchSetting(
          title: 'Double tap to zoom'.tl,
          settingKey: 'enableDoubleTapToZoom',
          onChanged: () {
            setState(() {});
            widget.onChanged?.call('enableDoubleTapToZoom');
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SwitchSetting(
          title: 'Long press to zoom'.tl,
          settingKey: 'enableLongPressToZoom',
          onChanged: () {
            setState(() {});
            widget.onChanged?.call('enableLongPressToZoom');
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: appdata.settings['enableLongPressToZoom'] == true,
          child: SelectSetting(
            title: "Long press zoom position".tl,
            settingKey: "longPressZoomPosition",
            optionTranslation: {
              "press": "Press position".tl,
              "center": "Screen center".tl,
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SwitchSetting(
          title: 'Limit image width'.tl,
          subtitle: 'When using Continuous(Top to Bottom) mode'.tl,
          settingKey: 'limitImageWidth',
          onChanged: () {
            widget.onChanged?.call('limitImageWidth');
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: _isVerticalFlowMode,
          child: SwitchSetting(
            title: 'Split dual pages'.tl,
            subtitle:
                'Only applies to Continuous and Waterfall (Top to Bottom) modes'
                    .tl,
            settingKey: 'splitDualPage',
            onChanged: () {
              setState(() {});
              widget.onChanged?.call('splitDualPage');
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SliverAnimatedVisibility(
          visible: _isVerticalFlowMode && _value('splitDualPage') == true,
          child: SwitchSetting(
            title: 'Swap split dual page order'.tl,
            subtitle:
                'Turn this on when the split page order does not match the reading direction'
                    .tl,
            settingKey: 'splitDualPageInvert',
            onChanged: () {
              widget.onChanged?.call('splitDualPageInvert');
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        if (App.isAndroid)
          SwitchSetting(
            title: 'Turn page by volume keys'.tl,
            settingKey: 'enableTurnPageByVolumeKey',
            onChanged: () {
              widget.onChanged?.call('enableTurnPageByVolumeKey');
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
        SwitchSetting(
          title: "Display time & battery info in reader".tl,
          settingKey: "enableClockAndBatteryInfoInReader",
          onChanged: () {
            widget.onChanged?.call("enableClockAndBatteryInfoInReader");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SwitchSetting(
          title: "Show system status bar".tl,
          settingKey: "showSystemStatusBar",
          onChanged: () {
            widget.onChanged?.call("showSystemStatusBar");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SelectSetting(
          title: "Quick collect image".tl,
          settingKey: "quickCollectImage",
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
        SliderSetting(
          title: "Number of images preloaded".tl,
          settingsIndex: "preloadImageCount",
          interval: 1,
          min: 1,
          max: 16,
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SwitchSetting(
          title: "Show Page Number".tl,
          settingKey: "showPageNumberInReader",
          onChanged: () {
            widget.onChanged?.call("showPageNumberInReader");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SwitchSetting(
          title: "Show Chapter Comments".tl,
          settingKey: "showChapterComments",
          onChanged: _onShowChapterCommentsChanged,
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: _isChapterCommentsAtEndSupported(),
          child: SwitchSetting(
            title: "Show Comments at Chapter End".tl,
            settingKey: "showChapterCommentsAtEnd",
            onChanged: () {
              widget.onChanged?.call("showChapterCommentsAtEnd");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
      ],
    );
  }
}

class _CustomImageProcessing extends StatefulWidget {
  const _CustomImageProcessing();

  @override
  State<_CustomImageProcessing> createState() => __CustomImageProcessingState();
}

class __CustomImageProcessingState extends State<_CustomImageProcessing> {
  var current = '';

  @override
  void initState() {
    super.initState();
    current = appdata.settings['customImageProcessing'];
  }

  @override
  void dispose() {
    appdata.settings['customImageProcessing'] = current;
    appdata.saveData();
    super.dispose();
  }

  int resetKey = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Custom Image Processing".tl),
        actions: [
          TextButton(
            onPressed: () {
              current = defaultCustomImageProcessing;
              appdata.settings['customImageProcessing'] = current;
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
                  initialValue: appdata.settings['customImageProcessing'],
                  onChanged: (value) {
                    current = value;
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
