import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/code.dart';
import 'package:venera_next/foundation/translations.dart';

class SourceScriptEditor extends StatefulWidget {
  const SourceScriptEditor({
    super.key,
    required this.script,
    required this.onSave,
  });

  final String script;
  final Future<void> Function(String script) onSave;

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
    if (saving) return;
    final snapshot = current;
    setState(() {
      saving = true;
      message = null;
    });
    try {
      await widget.onSave(snapshot);
      if (mounted) {
        setState(() {
          saved = snapshot;
          message = 'Source reloaded'.tl;
        });
      }
    } catch (error) {
      if (mounted) setState(() => message = error.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> confirmExit() async {
    if (saving || confirmingExit) return;
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
    if (discard == true && mounted) Navigator.pop(context);
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
                  onPressed: saving ? null : save,
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
