import 'package:venera_next/foundation/keyword_settings_store.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/translations.dart';

final _keywordSettings = KeywordSettingsStore(
  readSettings: () => appdata.settings,
  updateSettings: (change) => appdata.updateSettings(change),
);

class KeywordBlockingSettings extends StatefulWidget {
  const KeywordBlockingSettings({super.key, this.comments = false});
  final bool comments;

  @override
  State<KeywordBlockingSettings> createState() =>
      _KeywordBlockingSettingsState();
}

class _KeywordBlockingSettingsState
    extends SettingsSaveState<KeywordBlockingSettings> {
  BlockedKeywordList get _target =>
      widget.comments ? BlockedKeywordList.comments : BlockedKeywordList.comics;

  @override
  void initState() {
    super.initState();
    appdata.settings.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _add() {
    if (!acceptsSettingsChanges) return;
    final target = _target;
    showDialog<void>(
      context: context,
      builder: (_) => _AddKeywordDialog(target: target),
    );
  }

  @override
  Widget build(BuildContext context) {
    final target = _target;
    final words = _keywordSettings.read(target);
    return protectSettings(
      PopUpWidgetScaffold(
        title:
            (widget.comments ? 'Comment keyword blocking' : 'Keyword blocking')
                .tl,
        onBack: leaveSettings,
        tailing: [
          settingsSaveStatus,
          TextButton.icon(
            onPressed: _add,
            icon: const Icon(Icons.add),
            label: Text('Add'.tl),
          ),
        ],
        body: ListView.builder(
          itemCount: words.length,
          itemBuilder: (context, index) {
            final word = words[index];
            return ListTile(
              title: Text(word),
              trailing: IconButton(
                tooltip: 'Delete'.tl,
                icon: const Icon(Icons.close),
                onPressed: () => saveSetting((
                  target,
                  word,
                ), () => _keywordSettings.setBlocked(target, word, false)),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_refresh);
    super.dispose();
  }
}

class _AddKeywordDialog extends StatefulWidget {
  const _AddKeywordDialog({required this.target});
  final BlockedKeywordList target;

  @override
  State<_AddKeywordDialog> createState() => _AddKeywordDialogState();
}

class _AddKeywordDialogState extends SettingsSaveState<_AddKeywordDialog> {
  final _controller = TextEditingController();
  String? _error;

  Future<void> _add() async {
    if (!acceptsSettingsChanges || savingSettings || hasSettingsSaveError) {
      return;
    }
    final target = widget.target;
    final word = _controller.text;
    if (_keywordSettings.contains(target, word)) {
      setState(() => _error = 'Keyword already exists'.tl);
      return;
    }
    await saveSetting(
      (target, word),
      () => _keywordSettings.setBlocked(target, word, true),
      // Closing is a route operation after save ownership has finished.
      onSaved: () => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) leaveSettings();
      }),
    );
  }

  @override
  Widget build(BuildContext context) => protectSettings(
    ContentDialog(
      title: 'Add keyword'.tl,
      content: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: TextField(
          controller: _controller,
          enabled: !savingSettings && !hasSettingsSaveError,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: 'Keyword'.tl,
            errorText: _error,
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
      ),
      actions: [
        settingsSaveStatus,
        FilledButton(
          onPressed: savingSettings || hasSettingsSaveError ? null : _add,
          child: Text('Add'.tl),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
