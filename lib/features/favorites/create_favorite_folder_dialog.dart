import 'dart:async';
import 'package:flutter/material.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

class CreateFavoriteFolderDialog extends StatefulWidget {
  const CreateFavoriteFolderDialog({
    super.key,
    required this.validate,
    required this.create,
    required this.selectImport,
    required this.importJson,
  });
  final String? Function(String) validate;
  final FutureOr<void> Function(String) create;
  final Future<String?> Function(SelectionOperation) selectImport;
  final FutureOr<void> Function(String) importJson;

  @override
  State<CreateFavoriteFolderDialog> createState() =>
      _CreateFavoriteFolderDialogState();
}

class _CreateFavoriteFolderDialogState
    extends State<CreateFavoriteFolderDialog> {
  final controller = TextEditingController();
  String? error;
  bool importing = false;
  WindowSelectionTask? _task;

  @override
  void dispose() {
    _task?.cancel();
    controller.dispose();
    super.dispose();
  }

  Future<void> import() async {
    if (importing) return;
    final task = WindowSelectionTask(context);
    if (!task.canPresent) return;
    _task = task;
    final selectImport = widget.selectImport;
    final importJson = widget.importJson;
    setState(() {
      importing = true;
      error = null;
    });
    try {
      final imported = await task.run((operation) async {
        final json = await selectImport(operation);
        if (json == null) return false;
        operation.checkActive();
        await importJson(json);
        return true;
      });
      if (mounted && imported && task.canPresent) context.pop();
    } on SelectionCancelled {
      // A late picker/read may finish, but cannot start a new import.
    } catch (failure, stack) {
      Log.error('Import favorite folder', failure, stack);
      if (task.canPresent) setState(() => error = "Failed to import".tl);
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  Future<void> create() async {
    if (importing) return;
    final task = WindowSelectionTask(context);
    if (!task.canPresent) return;
    _task = task;
    try {
      final failure = widget.validate(controller.text);
      if (failure != null) {
        setState(() => error = failure);
        return;
      }
      setState(() => importing = true);
      final create = widget.create;
      final name = controller.text;
      await task.run((_) async => await create(name));
      if (mounted && task.canPresent) context.pop();
    } on SelectionCancelled {
      // An already accepted create is awaited; a new one cannot start on exit.
    } catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  @override
  Widget build(BuildContext context) => ContentDialog(
    title: "New Folder".tl,
    content: TextField(
      controller: controller,
      enabled: !importing,
      decoration: InputDecoration(hintText: "Folder Name".tl, errorText: error),
      onChanged: (_) {
        if (error != null) setState(() => error = null);
      },
    ).paddingHorizontal(16),
    actions: [
      TextButton(
        onPressed: importing ? null : import,
        child: Text("Import from file".tl),
      ).paddingRight(4),
      FilledButton(
        onPressed: importing ? null : create,
        child: Text("Create".tl),
      ),
    ],
  );
}
