import 'package:venera_next/foundation/keyword_settings_store.dart';
import 'package:venera_next/foundation/keyword_filter.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/components/keyword_match_preview.dart';
import 'package:venera_next/components/keyword_rule_labels.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';

final _keywordSettings = KeywordSettingsStore(
  readSettings: () => appdata.settings,
  updateSettings: (change) => appdata.updateSettings(change),
);

Future<void> showKeywordRuleEditor(
  BuildContext context, {
  required BlockedKeywordList target,
  KeywordRule? rule,
}) {
  final work = context.getInheritedWidgetOfExactType<SettingsSaveScope>()?.work;
  return showDialog<void>(
    context: context,
    animationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (_) {
      final editor = KeywordRuleEditor(target: target, initialRule: rule);
      return work == null
          ? editor
          : SettingsSaveScope(work: work, child: editor);
    },
  );
}

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
    showKeywordRuleEditor(context, target: _target);
  }

  void _delete(BlockedKeywordList target, KeywordRule rule) {
    var removed = false;
    saveSetting(
      (target, rule.keyword),
      () async {
        removed = await _keywordSettings.removeRule(target, rule);
      },
      onSaved: () {
        if (!removed && mounted) {
          context.showMessage(
            message: 'The rule changed. Close and reopen the editor.'.tl,
          );
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final target = _target;
    final rules = _keywordSettings.rules(target);
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
          itemCount: rules.length,
          itemBuilder: (context, index) {
            final rule = rules[index];
            return ListTile(
              title: Text(
                rule.keyword.isEmpty ? 'Empty keyword'.tl : rule.keyword,
              ),
              subtitle: Text(keywordRuleSummary(rule)),
              onTap: acceptsSettingsChanges
                  ? () => showKeywordRuleEditor(
                      context,
                      target: target,
                      rule: rule,
                    )
                  : null,
              trailing: IconButton(
                tooltip: 'Delete'.tl,
                icon: const Icon(Icons.close),
                onPressed: () => _delete(target, rule),
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

class KeywordRuleEditor extends StatefulWidget {
  const KeywordRuleEditor({super.key, required this.target, this.initialRule});
  final BlockedKeywordList target;
  final KeywordRule? initialRule;

  @override
  State<KeywordRuleEditor> createState() => _KeywordRuleEditorState();
}

class _KeywordRuleEditorState extends SettingsSaveState<KeywordRuleEditor> {
  final _form = GlobalKey<FormState>();
  late final _controller = TextEditingController(
    text: widget.initialRule?.keyword,
  );
  final _sample = TextEditingController();
  late KeywordMatchMode _mode =
      widget.initialRule?.mode ?? KeywordMatchMode.contains;
  late bool _caseSensitive = widget.initialRule?.caseSensitive ?? false;
  bool _modeChosen = false;
  bool _showPreview = false;
  bool _stale = false;
  String? _error;

  bool get _comments => widget.target == BlockedKeywordList.comments;
  bool get _editable => !savingSettings && !hasSettingsSaveError && !_stale;
  bool get _shortAbbreviation =>
      KeywordRule.isShortAbbreviation(_controller.text);

  KeywordRule get _candidate {
    final original = widget.initialRule;
    final raw = _controller.text;
    final word = raw == original?.keyword ? raw : raw.trim();
    if (original?.isLegacy == true &&
        _mode == original!.mode &&
        _caseSensitive == original.caseSensitive) {
      return KeywordRule.legacy(word, caseSensitive: _caseSensitive);
    }
    return KeywordRule(word, mode: _mode, caseSensitive: _caseSensitive);
  }

  void _wordChanged(String value) {
    setState(() {
      _error = null;
      if (widget.initialRule == null && !_modeChosen) {
        _mode = _shortAbbreviation
            ? KeywordMatchMode.wholeWord
            : KeywordMatchMode.contains;
      }
    });
  }

  Future<void> _save() async {
    if (!acceptsSettingsChanges || savingSettings || hasSettingsSaveError) {
      return;
    }
    if (_stale || !_form.currentState!.validate()) return;
    final target = widget.target;
    final candidate = _candidate;
    final original = widget.initialRule;
    var result = KeywordRuleSaveResult.changed;
    await saveSetting(
      (target, original?.keyword ?? candidate.keyword),
      () async {
        result = await _keywordSettings.saveRule(
          target,
          candidate,
          replacing: original,
        );
      },
      onSaved: () {
        if (!mounted) return;
        if (result == KeywordRuleSaveResult.saved) {
          // Route ownership is released only after the durable save finishes.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) leaveSettings();
          });
        } else {
          setState(() {
            _stale = result == KeywordRuleSaveResult.changed;
            _error = _stale
                ? 'The rule changed. Close and reopen the editor.'.tl
                : 'Keyword already exists'.tl;
          });
        }
      },
    );
  }

  Widget _preview() {
    final candidate = _candidate;
    final filter = KeywordFilter.rules([candidate]);
    final sample = _sample.text;
    final match = candidate.keyword.trim().isEmpty || sample.isEmpty
        ? null
        : _comments
        ? filter.commentMatch(sample)
        : filter.comicMatch(
            title: _mode == KeywordMatchMode.exactTag ? '' : sample,
            description: '',
            tags: _mode == KeywordMatchMode.exactTag ? [sample] : const [],
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('keyword-rule-sample'),
          controller: _sample,
          minLines: 1,
          maxLines: 3,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: _comments
                ? 'Sample comment'.tl
                : _mode == KeywordMatchMode.exactTag
                ? 'Sample tag'.tl
                : 'Sample title'.tl,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        if (sample.isNotEmpty && candidate.keyword.trim().isNotEmpty) ...[
          Text(
            match == null ? 'Will stay visible'.tl : 'Will be hidden'.tl,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          if (match != null) KeywordMatchPreview(match: match),
        ] else
          Text('Enter sample text to check this rule.'.tl),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => protectSettings(
    ContentDialog(
      title: widget.initialRule == null ? 'Add keyword'.tl : 'Edit keyword'.tl,
      content: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                key: const ValueKey('keyword-rule-word'),
                controller: _controller,
                enabled: _editable,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Keyword'.tl,
                  errorText: _error,
                  errorMaxLines: 4,
                ),
                validator: (_) {
                  final word = _candidate.keyword;
                  if (word.trim().isEmpty) return 'Keyword cannot be blank'.tl;
                  if (word != widget.initialRule?.keyword &&
                      _keywordSettings.contains(widget.target, word)) {
                    return 'Keyword already exists'.tl;
                  }
                  return null;
                },
                onChanged: _wordChanged,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<KeywordMatchMode>(
                key: ValueKey(_mode),
                initialValue: _mode,
                isExpanded: true,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Matching method'.tl,
                ),
                items: [
                  for (final mode in KeywordMatchMode.values)
                    if (!_comments || mode != KeywordMatchMode.exactTag)
                      DropdownMenuItem(value: mode, child: Text(mode.label)),
                ],
                onChanged: _editable
                    ? (mode) => setState(() {
                        _modeChosen = true;
                        _mode = mode!;
                      })
                    : null,
              ),
              const SizedBox(height: 8),
              Text(
                _comments && _mode == KeywordMatchMode.contains
                    ? 'Matches text anywhere in a comment.'.tl
                    : _mode.help,
              ),
              if (_shortAbbreviation && _mode != KeywordMatchMode.exactTag) ...[
                const SizedBox(height: 8),
                Text(
                  _mode == KeywordMatchMode.wholeWord
                      ? 'Whole word is recommended for short English abbreviations.'
                            .tl
                      : 'Short abbreviations may match longer words. Try Whole word.'
                            .tl,
                ),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Ignore case'.tl),
                value: !_caseSensitive,
                onChanged: _editable
                    ? (value) => setState(() => _caseSensitive = !value)
                    : null,
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => setState(() => _showPreview = !_showPreview),
                  icon: Icon(
                    _showPreview ? Icons.expand_less : Icons.expand_more,
                  ),
                  label: Text(_showPreview ? 'Hide test'.tl : 'Test match'.tl),
                ),
              ),
              if (_showPreview) _preview(),
            ],
          ),
        ),
      ),
      actions: [
        settingsSaveStatus,
        FilledButton(
          onPressed: _editable ? _save : null,
          child: Text(widget.initialRule == null ? 'Add'.tl : 'Save'.tl),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    _sample.dispose();
    super.dispose();
  }
}
