import 'package:flutter/material.dart';
import 'package:venera_next/features/reader/brightness.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/preferences.dart';
import 'package:venera_next/foundation/reader_preference_store.dart';
import 'package:venera_next/foundation/reader_preferences.dart';

class ReaderBrightnessSetting extends StatefulWidget {
  const ReaderBrightnessSetting({
    super.key,
    this.comicId,
    this.sourceKey,
    this.preview,
    this.panel = false,
    this.onChanged,
  });
  final String? comicId, sourceKey;
  final ReaderBrightnessPreview? preview;
  final bool panel;
  final ValueChanged<String>? onChanged;

  @override
  State<ReaderBrightnessSetting> createState() =>
      _ReaderBrightnessSettingState();
}

class _ReaderBrightnessSettingState
    extends SettingsSaveState<ReaderBrightnessSetting> {
  var _localPreview = ReaderBrightnessPreview();
  ReaderBrightnessPreview? _observedPreview;
  ReaderBrightnessPreview get _preview => widget.preview ?? _localPreview;

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _bindPreview() {
    if (identical(_observedPreview, _preview)) return;
    _observedPreview?.removeListener(_refresh);
    _observedPreview = _preview..addListener(_refresh);
  }

  @override
  void initState() {
    super.initState();
    _bindPreview();
    appdata.settings.addListener(_refresh);
  }

  @override
  void didUpdateWidget(ReaderBrightnessSetting oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.comicId != widget.comicId ||
        oldWidget.sourceKey != widget.sourceKey) {
      _localPreview.dispose();
      _localPreview = ReaderBrightnessPreview();
    }
    _bindPreview();
  }

  Future<void> _save<T extends Object>(
    Preference<T> preference,
    T value,
    VoidCallback release,
  ) async {
    final comic = widget.comicId, source = widget.sourceKey;
    try {
      await saveSetting(
        (comic, source, preference.key),
        () => appdata.updateSettings((draft) {
          ReaderPreferenceStore(
            settings: draft,
            comicId: comic,
            sourceKey: source,
          ).write(preference, value);
        }),
        onSaved: () => widget.onChanged?.call(preference.key),
        isCurrent: () => comic == widget.comicId && source == widget.sourceKey,
      );
    } finally {
      release();
    }
  }

  void _enabled(bool value) {
    if (!acceptsSettingsChanges) return;
    _save(
      ReaderPreferences.readerBrightnessEnabled,
      value,
      _preview.previewEnabled(value),
    );
  }

  void _brightness(int value) {
    if (!acceptsSettingsChanges) return;
    _save<num>(
      ReaderPreferences.readerBrightness,
      value,
      _preview.previewBrightness(value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = ReaderPreferenceStore(
      settings: appdata.settings,
      comicId: widget.comicId,
      sourceKey: widget.sourceKey,
    );
    final enabled =
        _preview.enabled ??
        store.read(ReaderPreferences.readerBrightnessEnabled);
    final brightness =
        _preview.brightness ??
        store.read<num>(ReaderPreferences.readerBrightness);
    return protectSettings(
      widget.panel
          ? ReaderBrightnessPanel(
              enabled: enabled,
              brightness: brightness,
              onEnabledChanged: _enabled,
              onBrightnessChanged: _brightness,
              status: settingsSaveStatus,
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ReaderBrightnessControl(
                  enabled: enabled,
                  brightness: brightness,
                  onEnabledChanged: _enabled,
                  onBrightnessChanged: _brightness,
                ),
                settingsSaveStatus,
              ],
            ),
    );
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_refresh);
    _observedPreview?.removeListener(_refresh);
    _localPreview.dispose();
    super.dispose();
  }
}
