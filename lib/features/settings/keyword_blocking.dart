import 'package:flutter/material.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/translations.dart';

/// Both lists use keyword membership: retries cannot append a duplicate or
/// remove a different row after another edit changes the list order.
Future<void> _saveKeyword(String key, String word, bool blocked) =>
    appdata.updateSettings((draft) {
      final words = List<String>.from(draft[key] as List);
      if (blocked) {
        if (!words.contains(word)) words.add(word);
      } else {
        words.removeWhere((candidate) => candidate == word);
      }
      draft[key] = words;
    });

class KeywordBlockingSettings extends StatefulWidget {
  const KeywordBlockingSettings({super.key, this.comments = false});
  final bool comments;

  @override
  State<KeywordBlockingSettings> createState() =>
      _KeywordBlockingSettingsState();
}

class _KeywordBlockingSettingsState
    extends SettingsSaveState<KeywordBlockingSettings> {
  String get _key => widget.comments ? 'blockedCommentWords' : 'blockedWords';

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
    final key = _key;
    showDialog<void>(
      context: context,
      builder: (_) => _AddKeywordDialog(settingKey: key),
    );
  }

  @override
  Widget build(BuildContext context) {
    final key = _key;
    final words = List<String>.from(appdata.settings[key] as List);
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
                  key,
                  word,
                ), () => _saveKeyword(key, word, false)),
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
  const _AddKeywordDialog({required this.settingKey});
  final String settingKey;

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
    final key = widget.settingKey;
    final word = _controller.text;
    if ((appdata.settings[key] as List).contains(word)) {
      setState(() => _error = 'Keyword already exists'.tl);
      return;
    }
    await saveSetting(
      (key, word),
      () => _saveKeyword(key, word, true),
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
