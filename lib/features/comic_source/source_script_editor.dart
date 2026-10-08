import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/code.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/translations.dart';

import 'source_failure_presentation.dart';

String _saveFailure(Object error, bool canSave) => canSave
    ? sourceFailureMessage(error)
    : '${sourceFailureMessage(error)}\n\n${'Save is paused after an incomplete source change. Copy your edits before closing.'.tl}';

class SourceScriptEditor extends StatefulWidget {
  const SourceScriptEditor({
    super.key,
    required this.script,
    required this.onSave,
    this.canSave,
  });

  final String script;
  final Future<void> Function(String script) onSave;
  final bool Function()? canSave;

  @override
  State<SourceScriptEditor> createState() => _SourceScriptEditorState();
}

class _SourceScriptEditorState extends State<SourceScriptEditor> {
  late String current = widget.script;
  late String saved = widget.script;
  bool saving = false;
  bool confirmingExit = false;
  String? message;

  Future<void> save() async {
    final task = WindowSelectionTask(context);
    if (saving || widget.canSave?.call() == false || !task.canPresent) return;
    final snapshot = current;
    final onSave = widget.onSave;
    setState(() {
      saving = true;
      message = null;
    });
    try {
      await task.run((_) => onSave(snapshot));
      if (mounted) {
        setState(() {
          saved = snapshot;
          message = 'Source reloaded'.tl;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => message = _saveFailure(error, widget.canSave?.call() ?? true),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> confirmExit() async {
    if (saving || confirmingExit || !NavigationAdmission.allows(context)) {
      return;
    }
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    if (route?.isCurrent != true) return;
    confirmingExit = true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Discard unsaved changes?'.tl),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Keep editing'.tl),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Discard changes'.tl),
          ),
        ],
      ),
    );
    confirmingExit = false;
    if (discard == true &&
        mounted &&
        route?.isCurrent == true &&
        identical(ModalRoute.of(context), route) &&
        navigator.mounted &&
        NavigationAdmission.allows(context)) {
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving && current == saved,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) confirmExit();
    },
    child: Scaffold(
      appBar: Appbar(title: Text('Edit'.tl)),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: saving || widget.canSave?.call() == false
                      ? null
                      : save,
                  child: Text(saving ? 'Loading'.tl : 'Save and reload'.tl),
                ),
              ),
            ),
            if (message != null)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .2,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(message!),
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: CodeEditor(
                initialValue: widget.script,
                onChanged: (value) => setState(() => current = value),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class SourceScriptReloadDialog extends StatefulWidget {
  const SourceScriptReloadDialog({
    super.key,
    required this.read,
    required this.onSave,
    required this.canSave,
  });

  final Future<String> Function() read;
  final Future<void> Function(String script) onSave;
  final bool Function() canSave;

  @override
  State<SourceScriptReloadDialog> createState() =>
      _SourceScriptReloadDialogState();
}

class _SourceScriptReloadDialogState extends State<SourceScriptReloadDialog> {
  String? message;
  bool saving = false;

  Future<void> reload() async {
    final task = WindowSelectionTask(context);
    if (saving || !widget.canSave() || !task.canPresent) return;
    final read = widget.read;
    final onSave = widget.onSave;
    setState(() {
      saving = true;
      message = null;
    });
    try {
      await task.run((operation) async {
        final script = await read();
        operation.checkActive();
        // Once admitted, a replacement is joined without converting its
        // successful commit into a cancellation after the dialog disappears.
        await onSave(script);
      });
      if (mounted) setState(() => message = 'Source reloaded'.tl);
    } catch (error) {
      if (mounted) {
        setState(() => message = _saveFailure(error, widget.canSave()));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: Text('Reload Configs'.tl),
      scrollable: true,
      content: SelectableText(
        message ?? 'Save the file in your editor, then reload it here.'.tl,
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: Text('Cancel'.tl),
        ),
        TextButton(
          onPressed: saving || !widget.canSave() ? null : reload,
          child: Text(saving ? 'Loading'.tl : 'Reload'.tl),
        ),
      ],
    ),
  );
}
