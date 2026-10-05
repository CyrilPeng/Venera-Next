import 'dart:async';
import 'dart:convert';
import 'package:venera_next/foundation/preferences.dart';
import 'package:venera_next/foundation/reader_preference_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

class _SettingField<T extends Object> {
  const _SettingField(
    this.key,
    this.preference,
    this.comicId,
    this.sourceKey,
    this.device,
  );
  final String key;
  final Preference<T>? preference;
  final String? comicId, sourceKey;
  final bool device;

  bool matches(_SettingField<T> other) =>
      key == other.key &&
      comicId == other.comicId &&
      sourceKey == other.sourceKey &&
      device == other.device &&
      identical(preference, other.preference);

  T? read() {
    final raw = comicId != null
        ? appdata.settings.getReaderSetting(comicId!, sourceKey!, key)
        : device
        ? appdata.settings.getDeviceReaderSetting(key)
        : appdata.settings[key];
    return preference?.normalize(raw) ?? raw as T?;
  }

  Future<void> save(T value) {
    final snapshot = jsonEncode(preference?.normalize(value) ?? value);
    return appdata.updateSettings((settings) {
      final decoded = jsonDecode(snapshot);
      final typed = preference;
      if (typed != null) {
        ReaderPreferenceStore(
          settings: settings,
          comicId: comicId,
          sourceKey: sourceKey,
          scope: comicId != null
              ? ReaderPreferenceScope.comic
              : device
              ? ReaderPreferenceScope.device
              : ReaderPreferenceScope.global,
        ).write(typed, typed.normalize(decoded));
        return;
      }
      final stored = decoded is num && decoded.toInt() == decoded
          ? decoded.toInt()
          : decoded;
      if (comicId != null) {
        settings.setReaderSetting(comicId!, sourceKey!, key, stored);
      } else if (device) {
        settings.setDeviceReaderSetting(key, stored);
      } else {
        settings[key] = stored;
      }
    });
  }
}

const _savingIndicator = SizedBox.square(
  dimension: 18,
  child: CircularProgressIndicator(strokeWidth: 2),
);

/// Own the actual save until it finishes, including during forced unmount.
/// Each edit joins appdata's queue immediately; a later successful snapshot
/// includes earlier edits and can repair an earlier persistence failure.
abstract class _SettingState<W extends StatefulWidget, T extends Object>
    extends SettingsSaveState<W> {
  _SettingField<T> get field;
  VoidCallback? get onSaved;
  int _revision = 0;
  T? _preview;
  _SettingField<T>? _previewField;
  bool get saving => savingSettings;
  T? get currentValue =>
      _preview != null && _previewField?.matches(field) == true
      ? _preview!
      : field.read();
  Future<void> change(T value) async {
    if (!acceptsSettingsChanges) return;
    final target = field;
    final revision = ++_revision;
    setState(() {
      _preview = value;
      _previewField = target;
    });
    await saveSetting(
      (
        target.key,
        target.comicId,
        target.sourceKey,
        target.device,
        target.preference,
      ),
      () => target.save(value),
      onSaved: () => onSaved?.call(),
      isCurrent: () => revision == _revision && target.matches(field),
    );
    if (revision == _revision) _preview = null;
    if (mounted) setState(() {});
  }

  Widget withSaveStatus(Widget child) => protectSettings(
    Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        child,
        if (hasSettingsSaveError)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: settingsSaveStatus,
          ),
      ],
    ),
  );
}

class SwitchSetting extends StatefulWidget {
  const SwitchSetting({
    super.key,
    required this.title,
    this.preference,
    required this.settingKey,
    this.onChanged,
    this.subtitle,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
  });

  factory SwitchSetting.preference({
    Key? key,
    required String title,
    required Preference<bool> preference,
    VoidCallback? onChanged,
    String? subtitle,
  }) => SwitchSetting(
    key: key,
    title: title,
    settingKey: preference.key,
    preference: preference,
    onChanged: onChanged,
    subtitle: subtitle,
  );

  factory SwitchSetting.reader({
    Key? key,
    required String title,
    required Preference<bool> preference,
    VoidCallback? onChanged,
    String? comicId,
    String? comicSource,
    bool useDeviceSettings = false,
    String? subtitle,
  }) => SwitchSetting(
    key: key,
    title: title,
    settingKey: preference.key,
    preference: preference,
    onChanged: onChanged,
    comicId: comicId,
    comicSource: comicSource,
    useDeviceSettings: useDeviceSettings,
    subtitle: subtitle,
  );

  final Preference<bool>? preference;

  final String title;

  final String settingKey;

  final VoidCallback? onChanged;

  final String? subtitle;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  @override
  State<SwitchSetting> createState() => _SwitchSettingState();
}

class _SwitchSettingState extends _SettingState<SwitchSetting, bool> {
  @override
  _SettingField<bool> get field => _SettingField(
    widget.settingKey,
    widget.preference,
    widget.comicId,
    widget.comicSource,
    widget.useDeviceSettings,
  );
  @override
  VoidCallback? get onSaved => widget.onChanged;

  @override
  Widget build(BuildContext context) {
    final value = currentValue;
    return withSaveStatus(
      ListTile(
        title: Text(widget.title),
        subtitle: widget.subtitle == null ? null : Text(widget.subtitle!),
        trailing: saving
            ? _savingIndicator
            : Switch(value: value!, onChanged: change),
      ),
    );
  }
}

class SelectSetting extends StatelessWidget {
  const SelectSetting({
    super.key,
    required this.title,
    this.preference,
    required this.settingKey,
    required this.optionTranslation,
    this.onChanged,
    this.help,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
  });

  factory SelectSetting.preference({
    Key? key,
    required String title,
    required Preference<String> preference,
    VoidCallback? onChanged,
    required Map<String, String> optionTranslation,
    String? help,
  }) => SelectSetting(
    key: key,
    title: title,
    settingKey: preference.key,
    preference: preference,
    onChanged: onChanged,
    optionTranslation: optionTranslation,
    help: help,
  );

  factory SelectSetting.reader({
    Key? key,
    required String title,
    required Preference<String> preference,
    VoidCallback? onChanged,
    String? comicId,
    String? comicSource,
    bool useDeviceSettings = false,
    required Map<String, String> optionTranslation,
    String? help,
  }) => SelectSetting(
    key: key,
    title: title,
    settingKey: preference.key,
    preference: preference,
    onChanged: onChanged,
    comicId: comicId,
    comicSource: comicSource,
    useDeviceSettings: useDeviceSettings,
    optionTranslation: optionTranslation,
    help: help,
  );

  final Preference<String>? preference;

  final String title;

  final String settingKey;

  final Map<String, String> optionTranslation;

  final VoidCallback? onChanged;

  final String? help;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 450) {
            return _DoubleLineSelectSettings(
              title: title,
              preference: preference,
              settingKey: settingKey,
              optionTranslation: optionTranslation,
              onChanged: onChanged,
              help: help,
              comicId: comicId,
              comicSource: comicSource,
              useDeviceSettings: useDeviceSettings,
            );
          } else {
            return _EndSelectorSelectSetting(
              title: title,
              preference: preference,
              settingKey: settingKey,
              optionTranslation: optionTranslation,
              onChanged: onChanged,
              help: help,
              comicId: comicId,
              comicSource: comicSource,
              useDeviceSettings: useDeviceSettings,
            );
          }
        },
      ),
    );
  }
}

class _DoubleLineSelectSettings extends StatefulWidget {
  const _DoubleLineSelectSettings({
    required this.title,
    this.preference,
    required this.settingKey,
    required this.optionTranslation,
    this.onChanged,
    this.help,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
  });

  final Preference<String>? preference;

  final String title;

  final String settingKey;

  final Map<String, String> optionTranslation;

  final VoidCallback? onChanged;

  final String? help;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  @override
  State<_DoubleLineSelectSettings> createState() =>
      _DoubleLineSelectSettingsState();
}

class _DoubleLineSelectSettingsState
    extends _SettingState<_DoubleLineSelectSettings, String> {
  @override
  _SettingField<String> get field => _SettingField(
    widget.settingKey,
    widget.preference,
    widget.comicId,
    widget.comicSource,
    widget.useDeviceSettings,
  );
  @override
  VoidCallback? get onSaved => widget.onChanged;

  @override
  Widget build(BuildContext context) {
    final value = currentValue;
    return withSaveStatus(
      ListTile(
        title: Row(
          children: [
            Expanded(child: Text(widget.title)),
            const SizedBox(width: 4),
            if (widget.help != null)
              Button.icon(
                size: 18,
                icon: const Icon(Icons.help_outline),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) {
                      return ContentDialog(
                        title: "Help".tl,
                        content: Text(
                          widget.help!,
                        ).paddingHorizontal(16).fixWidth(double.infinity),
                        actions: [
                          Button.filled(
                            onPressed: context.pop,
                            child: Text("OK".tl),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
          ],
        ),
        subtitle: Text(widget.optionTranslation[value] ?? "None"),
        trailing: saving ? _savingIndicator : const Icon(Icons.arrow_drop_down),
        onTap: saving
            ? null
            : () {
                var renderBox = context.findRenderObject() as RenderBox;
                var offset = renderBox.localToGlobal(Offset.zero);
                var size = renderBox.size;
                var rect = offset & size;
                final target = field;
                showMenu(
                  elevation: 3,
                  color: context.brightness == Brightness.light
                      ? const Color(0xFFF6F6F6)
                      : const Color(0xFF1E1E1E),
                  context: context,
                  position: RelativeRect.fromRect(
                    rect,
                    Offset.zero & MediaQuery.of(context).size,
                  ),
                  items: widget.optionTranslation.keys
                      .map(
                        (key) => PopupMenuItem(
                          value: key,
                          height: App.isMobile ? 46 : 40,
                          child: Text(widget.optionTranslation[key]!),
                        ),
                      )
                      .toList(),
                ).then((value) async {
                  if (value != null &&
                      mounted &&
                      target.matches(field) &&
                      widget.optionTranslation.containsKey(value)) {
                    await change(value);
                  }
                });
              },
      ),
    );
  }
}

class _EndSelectorSelectSetting extends StatefulWidget {
  const _EndSelectorSelectSetting({
    required this.title,
    this.preference,
    required this.settingKey,
    required this.optionTranslation,
    this.onChanged,
    this.help,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
  });

  final Preference<String>? preference;

  final String title;

  final String settingKey;

  final Map<String, String> optionTranslation;

  final VoidCallback? onChanged;

  final String? help;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  @override
  State<_EndSelectorSelectSetting> createState() =>
      _EndSelectorSelectSettingState();
}

class _EndSelectorSelectSettingState
    extends _SettingState<_EndSelectorSelectSetting, String> {
  @override
  _SettingField<String> get field => _SettingField(
    widget.settingKey,
    widget.preference,
    widget.comicId,
    widget.comicSource,
    widget.useDeviceSettings,
  );
  @override
  VoidCallback? get onSaved => widget.onChanged;

  @override
  Widget build(BuildContext context) {
    final options = Map<String, String>.of(widget.optionTranslation);
    final target = field;
    final value = currentValue;
    return withSaveStatus(
      ListTile(
        title: Row(
          children: [
            Expanded(child: Text(widget.title)),
            const SizedBox(width: 4),
            if (widget.help != null)
              Button.icon(
                size: 18,
                icon: const Icon(Icons.help_outline),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) {
                      return ContentDialog(
                        title: "Help".tl,
                        content: Text(
                          widget.help!,
                        ).paddingHorizontal(16).fixWidth(double.infinity),
                        actions: [
                          Button.filled(
                            onPressed: context.pop,
                            child: Text("OK".tl),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
          ],
        ),
        trailing: saving
            ? _savingIndicator
            : Select(
                current: options[value],
                values: options.values.toList(),
                minWidth: 64,
                onTap: (index) {
                  if (mounted &&
                      target.matches(field) &&
                      index >= 0 &&
                      index < options.length) {
                    final selected = options.keys.elementAt(index);
                    if (widget.optionTranslation.containsKey(selected)) {
                      unawaited(change(selected));
                    }
                  }
                },
              ),
      ),
    );
  }
}

class SliderSetting extends StatefulWidget {
  const SliderSetting({
    super.key,
    required this.title,
    this.preference,
    required this.settingsIndex,
    required this.interval,
    required this.min,
    required this.max,
    this.onChanged,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
    this.valueFormatter,
  });

  factory SliderSetting.preference({
    Key? key,
    required String title,
    required NumericPreference preference,
    VoidCallback? onChanged,
    String Function(double)? valueFormatter,
  }) => SliderSetting(
    key: key,
    title: title,
    settingsIndex: preference.key,
    preference: preference,
    onChanged: onChanged,
    valueFormatter: valueFormatter,
    interval: preference.step,
    min: preference.min,
    max: preference.max,
  );

  factory SliderSetting.reader({
    Key? key,
    required String title,
    required NumericPreference preference,
    VoidCallback? onChanged,
    String? comicId,
    String? comicSource,
    bool useDeviceSettings = false,
    String Function(double)? valueFormatter,
  }) => SliderSetting(
    key: key,
    title: title,
    settingsIndex: preference.key,
    preference: preference,
    onChanged: onChanged,
    comicId: comicId,
    comicSource: comicSource,
    useDeviceSettings: useDeviceSettings,
    valueFormatter: valueFormatter,
    interval: preference.step,
    min: preference.min,
    max: preference.max,
  );

  final Preference<num>? preference;

  final String title;

  final String settingsIndex;

  final double interval;

  final double min;

  final double max;

  final VoidCallback? onChanged;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  final String Function(double value)? valueFormatter;

  @override
  State<SliderSetting> createState() => _SliderSettingState();
}

class _SliderSettingState extends _SettingState<SliderSetting, num> {
  @override
  _SettingField<num> get field => _SettingField(
    widget.settingsIndex,
    widget.preference,
    widget.comicId,
    widget.comicSource,
    widget.useDeviceSettings,
  );
  @override
  VoidCallback? get onSaved => widget.onChanged;

  @override
  Widget build(BuildContext context) {
    final value = currentValue!.toDouble();
    return withSaveStatus(
      ListTile(
        title: Text(widget.title, softWrap: true, maxLines: 2),
        trailing: Text(
          widget.valueFormatter?.call(value) ?? value.toString(),
          style: ts.s12,
        ),
        subtitle: Slider(
          value: value,
          onChanged: change,
          divisions: ((widget.max - widget.min) / widget.interval).toInt(),
          min: widget.min,
          max: widget.max,
        ),
      ),
    );
  }
}

class PopupWindowSetting extends StatelessWidget {
  const PopupWindowSetting({
    super.key,
    required this.title,
    required this.builder,
  });

  final Widget Function() builder;

  final String title;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      trailing: const Icon(Icons.arrow_right),
      onTap: () {
        showPopUpWidget(App.rootContext, builder());
      },
    );
  }
}

class MultiPagesFilter extends StatefulWidget {
  const MultiPagesFilter({
    super.key,
    required this.title,
    required this.settingsIndex,
    required this.pages,
  });

  final String title;

  final String settingsIndex;

  // key - name
  final Map<String, String> pages;

  @override
  State<MultiPagesFilter> createState() => _MultiPagesFilterState();
}

class _MultiPagesFilterState
    extends _SettingState<MultiPagesFilter, List<String>> {
  @override
  _SettingField<List<String>> get field =>
      _SettingField(widget.settingsIndex, null, null, null, false);
  @override
  VoidCallback? get onSaved => null;

  late List<String> keys;

  @override
  void initState() {
    keys = List.from(appdata.settings[widget.settingsIndex]);
    keys.remove("");
    super.initState();
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  var reorderWidgetKey = UniqueKey();
  var scrollController = ScrollController();
  final _key = GlobalKey();

  @override
  Widget build(BuildContext context) {
    var tiles = keys.map((e) => buildItem(e)).toList();

    var view = ReorderableBuilder<String>(
      key: reorderWidgetKey,
      scrollController: scrollController,
      longPressDelay: App.isDesktop
          ? const Duration(milliseconds: 100)
          : const Duration(milliseconds: 500),
      dragChildBoxDecoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 5,
            offset: Offset(0, 2),
            spreadRadius: 2,
          ),
        ],
      ),
      onReorder: (reorderFunc) {
        setState(() {
          keys = List.from(reorderFunc(keys));
        });
        updateSetting();
      },
      children: tiles,
      builder: (children) {
        return GridView(
          key: _key,
          controller: scrollController,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 1,
            mainAxisExtent: 48,
          ),
          children: children,
        );
      },
    );

    return protectSettings(
      PopUpWidgetScaffold(
        title: widget.title,
        onBack: leaveSettings,
        tailing: [
          settingsSaveStatus,
          if (keys.length < widget.pages.length)
            TextButton.icon(
              label: Text("Add".tl),
              icon: const Icon(Icons.add),
              onPressed: showAddDialog,
            ),
        ],
        body: view,
      ),
    );
  }

  Widget buildItem(String key) {
    Widget removeButton = Padding(
      padding: const EdgeInsets.only(right: 8),
      child: IconButton(
        onPressed: () {
          setState(() {
            keys.remove(key);
          });
          updateSetting();
        },
        icon: const Icon(Icons.delete_outline),
      ),
    );

    return ListTile(
      title: Text(widget.pages[key] ?? "(Invalid) $key"),
      key: Key(key),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [removeButton, const Icon(Icons.drag_handle)],
      ),
    );
  }

  void showAddDialog() {
    var canAdd = <String, String>{};
    widget.pages.forEach((key, value) {
      if (!keys.contains(key)) {
        canAdd[key] = value;
      }
    });
    var selected = <String>[];
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Add".tl,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: canAdd.entries
                    .map(
                      (e) => CheckboxListTile(
                        value: selected.contains(e.key),
                        title: Text(e.value),
                        key: Key(e.key),
                        onChanged: (value) {
                          setState(() {
                            if (value!) {
                              selected.add(e.key);
                            } else {
                              selected.remove(e.key);
                            }
                          });
                        },
                      ),
                    )
                    .toList(),
              ),
              actions: [
                if (selected.length < canAdd.length)
                  TextButton(
                    child: Text("Select All".tl),
                    onPressed: () {
                      setState(() {
                        selected = canAdd.keys.toList();
                      });
                    },
                  )
                else
                  TextButton(
                    child: Text("Deselect All".tl),
                    onPressed: () {
                      setState(() {
                        selected.clear();
                      });
                    },
                  ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: selected.isNotEmpty
                      ? () {
                          if (!mounted) return;
                          this.setState(() {
                            keys.addAll(selected);
                          });
                          updateSetting();
                          Navigator.pop(context);
                        }
                      : null,
                  child: Text("Add".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void updateSetting() {
    unawaited(change(List<String>.of(keys)));
  }
}

class CallbackSetting extends StatelessWidget {
  const CallbackSetting({
    super.key,
    required this.title,
    required this.callback,
    required this.actionTitle,
    this.subtitle,
  });

  final String title;

  final String? subtitle;

  final VoidCallback callback;

  final String actionTitle;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: Button.normal(
        onPressed: callback,
        child: Text(actionTitle),
      ).fixHeight(28),
      onTap: callback,
    );
  }
}

class SettingPartTitle extends StatelessWidget {
  const SettingPartTitle({super.key, required this.title, required this.icon});

  final String title;

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        padding: const EdgeInsets.only(left: 16, top: 16, bottom: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: context.colorScheme.onSurface.withValues(alpha: 0.1),
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 24),
            const SizedBox(width: 8),
            Text(title, style: ts.s18),
          ],
        ),
      ),
    );
  }
}
