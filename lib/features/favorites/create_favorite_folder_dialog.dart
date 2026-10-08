import 'dart:async';
import 'package:flutter/material.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

class CreateFavoriteFolderDialog extends StatefulWidget {
  const CreateFavoriteFolderDialog({
    super.key,
    required this.validate,
    required this.create,
    required this.selectImport,
    required this.importJson,
    this.isCurrent,
  });
  final String? Function(String) validate;
  final FutureOr<void> Function(String) create;
  final Future<String?> Function(SelectionOperation) selectImport;
  final FutureOr<void> Function(String) importJson;
  final bool Function()? isCurrent;

  @override
  State<CreateFavoriteFolderDialog> createState() =>
      _CreateFavoriteFolderDialogState();
}

class _CreateFavoriteFolderDialogState
    extends State<CreateFavoriteFolderDialog> {
  final controller = TextEditingController();
  String? error;
  bool importing = false;
  bool _completed = false;
  WindowSelectionTask? _owner;
  NavigatorState? _navigator;
  WindowSelectionTask? _task;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_owner == null) {
      _owner = WindowSelectionTask(context);
      _navigator = Navigator.of(context);
    }
  }

  bool get _canAct =>
      mounted &&
      _owner?.canPresent == true &&
      Navigator.maybeOf(context) == _navigator &&
      (widget.isCurrent?.call() ?? true);

  @override
  void dispose() {
    _task?.cancel();
    controller.dispose();
    super.dispose();
  }

  Future<void> import() async {
    if (importing || _completed || !_canAct) return;
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
        await _commit(() => importJson(json));
        return true;
      });
      if (imported && _canAct) _navigator!.pop();
    } on SelectionCancelled {
      // A late picker/read may finish, but cannot start a new import.
    } catch (failure, stack) {
      Log.error('Import favorite folder', failure, stack);
      // Keep the failure for a covered dialog when its caller returns.
      if (mounted) error = "Failed to import".tl;
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  Future<void> create() async {
    if (importing || !_canAct) return;
    if (_completed) {
      _navigator!.pop();
      return;
    }
    final task = WindowSelectionTask(context);
    if (!task.canPresent) return;
    _task = task;
    final validate = widget.validate;
    final create = widget.create;
    final name = controller.text;
    setState(() {
      importing = true;
      error = null;
    });
    try {
      final failure = await task.run<String?>((operation) async {
        final failure = validate(name);
        operation.checkActive();
        if (failure != null) return failure;
        await _commit(() => create(name));
        return null;
      });
      if (!_canAct) return;
      if (_completed) {
        _navigator!.pop();
      } else {
        setState(() => error = failure);
      }
    } on SelectionCancelled {
      // An already accepted create is awaited; a new one cannot start on exit.
    } catch (failure, stack) {
      Log.error('Create favorite folder', failure, stack);
      if (mounted) error = failure.toString();
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  Future<void> _commit(FutureOr<void> Function() write) async {
    try {
      await write();
      // Remember the commit before selection cleanup or route removal can fail.
      _completed = true;
    } on PersistenceFailure catch (failure) {
      _completed = failure.commitState != PersistenceCommitState.notCommitted;
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) => NavigationAdmission(
    allowsNavigation: () => _canAct,
    child: ContentDialog(
      title: "New Folder".tl,
      content: TextField(
        controller: controller,
        enabled: !importing && !_completed && _canAct,
        decoration: InputDecoration(
          hintText: "Folder Name".tl,
          errorText: error,
        ),
        onChanged: (_) {
          if (importing || _completed || !_canAct) return;
          if (error != null) setState(() => error = null);
        },
      ).paddingHorizontal(16),
      actions: [
        Flexible(
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            runSpacing: 4,
            children: [
              TextButton(
                onPressed: importing || _completed || !_canAct ? null : import,
                child: Text("Import from file".tl),
              ),
              FilledButton(
                onPressed: importing || !_canAct ? null : create,
                child: Text((_completed ? "OK" : "Create").tl),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
