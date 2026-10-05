import 'dart:async';
import 'package:flutter/material.dart';
import 'package:venera_next/components/message.dart';
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
  final Future<String?> Function() selectImport;
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

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> import() async {
    if (importing) return;
    final route = ModalRoute.of(context);
    setState(() {
      importing = true;
      error = null;
    });
    try {
      final json = await widget.selectImport();
      if (!mounted || json == null) return;
      await widget.importJson(json);
      if (mounted && route?.isCurrent != false) context.pop();
    } catch (_) {
      if (mounted) setState(() => error = "Failed to import".tl);
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  Future<void> create() async {
    if (importing) return;
    final route = ModalRoute.of(context);
    try {
      final failure = widget.validate(controller.text);
      if (failure != null) {
        setState(() => error = failure);
        return;
      }
      setState(() => importing = true);
      await widget.create(controller.text);
      if (mounted && route?.isCurrent != false) context.pop();
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
