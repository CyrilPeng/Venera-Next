import 'package:venera_next/foundation/preferences.dart';
import 'package:venera_next/foundation/reader_preferences.dart';
import 'package:venera_next/foundation/reader_preference_store.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/features/reader/reader_mode_labels.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_layout.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';

class ReaderModeSettings extends StatefulWidget {
  const ReaderModeSettings({
    super.key,
    this.comicId,
    this.sourceKey,
    this.currentMode,
    this.isDetecting,
    this.onDetect,
    this.onChanged,
  });

  final String? comicId;
  final String? sourceKey;
  final String Function()? currentMode;
  final bool Function()? isDetecting;
  final Future<void> Function()? onDetect;
  final VoidCallback? onChanged;

  @override
  State<ReaderModeSettings> createState() => _ReaderModeSettingsState();
}

class _ReaderModeSettingsState extends SettingsSaveState<ReaderModeSettings> {
  bool _detecting = false;

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

  ReaderPreferenceStore get _store =>
      ReaderPreferenceStore(settings: appdata.settings);

  Future<bool> _setPreference<T extends Object>(
    Preference<T> preference,
    T value,
  ) {
    final target = (widget.comicId, widget.sourceKey);
    return saveSetting(
      preference.key,
      () => appdata.updateSettings((draft) {
        ReaderPreferenceStore(settings: draft).write(preference, value);
      }),
      onSaved: () => widget.onChanged?.call(),
      isCurrent: () => target == (widget.comicId, widget.sourceKey),
    );
  }

  Future<void> _chooseMode({
    required String title,
    required String value,
    required Future<bool> Function(String) onSelected,
    bool allowDefault = false,
  }) async {
    if (!acceptsSettingsChanges) return;
    final target = (widget.comicId, widget.sourceKey);
    final options = {
      if (allowDefault) 'default': 'Follow default'.tl,
      ...readerModeLabels,
    };
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: options.entries.map((option) {
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(context, option.key),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            child: Row(
              children: [
                Icon(
                  value == option.key
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: value == option.key
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  size: 20,
                ),
                const SizedBox(width: 16),
                Expanded(child: Text(option.value)),
              ],
            ),
          );
        }).toList(),
      ),
    );
    if (mounted &&
        selected != null &&
        target == (widget.comicId, widget.sourceKey) &&
        acceptsSettingsChanges &&
        options.containsKey(selected)) {
      await onSelected(selected);
    }
  }

  Widget _preference(
    String title,
    Preference<String> preference, {
    String? description,
  }) {
    final value = _store.read(preference);
    return ListTile(
      title: Text(title.tl),
      subtitle: Text(
        [
          readerModeLabels[value] ?? value,
          if (description != null) description.tl,
        ].join('\n'),
      ),
      trailing: const Icon(Icons.expand_more),
      onTap: () => _chooseMode(
        title: title.tl,
        value: value,
        onSelected: (value) => _setPreference(preference, value),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = appdata.settings;
    final auto = _store.read(ReaderPreferences.autoReaderMode) == true;
    final cid = widget.comicId;
    final source = widget.sourceKey;
    if (cid == null || source == null) {
      return Column(
        children: [
          settingsSaveStatus,
          SwitchListTile(
            title: Text('Choose reading mode automatically'.tl),
            subtitle: Text(
              'Recognize paged and long-strip comics from image proportions.'
                  .tl,
            ),
            value: auto,
            onChanged: (value) =>
                _setPreference(ReaderPreferences.autoReaderMode, value),
          ),
          if (auto) ...[
            _preference('Paged comics', ReaderPreferences.pagedReaderMode),
            _preference(
              'Long-strip comics',
              ReaderPreferences.longStripReaderMode,
            ),
          ],
          _preference(
            auto ? 'When layout is unknown' : 'Default reading mode',
            ReaderPreferences.readerMode,
            description: auto
                ? 'Used when there are too few images or their proportions are mixed.'
                : null,
          ),
        ],
      );
    }

    final override = settings.comicReaderModeOverride(cid, source);
    final effective = settings.resolveReaderMode(cid, source);
    final current = widget.currentMode?.call() ?? effective;
    final layout = settings.comicLayout(cid, source);
    final detecting = _detecting || (widget.isDetecting?.call() ?? false);
    final layoutLabel = switch (layout) {
      ComicLayout.paged => 'Paged comic'.tl,
      ComicLayout.longStrip => 'Long-strip comic'.tl,
      ComicLayout.unknown => 'Not identified'.tl,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        settingsSaveStatus,
        ListTile(
          title: Text('Reading mode for this comic'.tl),
          subtitle: Text(
            [
              override == null
                  ? 'Follow default'.tl
                  : readerModeLabels[override] ?? override,
              'Currently using: @mode'.tlParams({
                'mode': readerModeLabels[current] ?? current,
              }),
            ].join('\n'),
          ),
          trailing: const Icon(Icons.expand_more),
          onTap: () => _chooseMode(
            title: 'Reading mode for this comic'.tl,
            value: override ?? 'default',
            allowDefault: true,
            onSelected: (value) => saveSetting(
              (cid, source, 'readerMode'),
              () => appdata.updateSettings((draft) {
                draft.setComicReaderModeOverride(
                  cid,
                  source,
                  value == 'default' ? null : value,
                );
              }),
              onSaved: () => widget.onChanged?.call(),
              isCurrent: () =>
                  cid == widget.comicId && source == widget.sourceKey,
            ),
          ),
        ),
        if (auto) ...[
          ListTile(
            leading: Icon(switch (layout) {
              ComicLayout.paged => Icons.auto_stories_outlined,
              ComicLayout.longStrip => Icons.view_day_outlined,
              ComicLayout.unknown => Icons.aspect_ratio,
            }),
            title: Text(
              detecting ? 'Identifying comic layout…'.tl : layoutLabel,
            ),
            subtitle: Text(
              (override != null
                      ? 'Your choice for this comic takes priority.'
                      : layout == ComicLayout.unknown
                      ? 'Not enough consistent image proportions to identify the layout.'
                      : 'Recognized from image proportions. Your reading preference applies automatically.')
                  .tl,
            ),
          ),
          if (widget.onDetect != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextButton(
                  onPressed: detecting
                      ? null
                      : () async {
                          setState(() => _detecting = true);
                          try {
                            await widget.onDetect!();
                          } catch (error, stack) {
                            Log.error('Layout detection', error, stack);
                            if (context.mounted) {
                              context.showMessage(message: error.toString());
                            }
                          } finally {
                            if (mounted) setState(() => _detecting = false);
                          }
                        },
                  child: Text('Identify again from this chapter'.tl),
                ),
              ),
            ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(
            'This selection only affects this comic. Change default preferences in Settings → Reader.'
                .tl,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
