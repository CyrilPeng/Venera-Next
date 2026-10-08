import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/input_dialog.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';

import 'favorite_actions.dart' show validateFolderName;
import 'favorites_manager.dart';

Future<void> renameFavoriteFolder(
  BuildContext context, {
  required LocalFavoritesManager manager,
  required String folder,
  required bool Function() isCurrent,
  required ValueChanged<String> onRenamed,
}) {
  final result = _renameFavoriteFolder(
    context,
    manager: manager,
    folder: folder,
    isCurrent: isCurrent,
    onRenamed: onRenamed,
  );
  unawaited(
    result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        Log.error('Rename favorite folder', error, stack);
      },
    ),
  );
  return result;
}

Future<void> _renameFavoriteFolder(
  BuildContext context, {
  required LocalFavoritesManager manager,
  required String folder,
  required bool Function() isCurrent,
  required ValueChanged<String> onRenamed,
}) async {
  if (!context.mounted || !isCurrent()) return;
  final owner = WindowSelectionTask(context);
  if (!owner.canPresent) return;
  final popup = context
      .getInheritedWidgetOfExactType<PopupIndicatorWidget>()
      ?.route;
  if (popup?.isCurrent == false) return;
  final generation = manager.connectionGeneration;
  final dataPath = App.dataPath;
  bool isCurrentDatabase() =>
      identical(LocalFavoritesManager.cache, manager) &&
      manager.connectionGeneration == generation &&
      App.dataPath == dataPath;
  if (!isCurrentDatabase()) return;

  String? renamed;
  Future<void>? confirmation;
  Future<Object?> confirm(String name) async {
    if (!owner.active ||
        !isCurrent() ||
        !isCurrentDatabase() ||
        popup?.isActive == false) {
      throw const SelectionCancelled();
    }
    final error = validateFolderName(name, folders: manager.folderNames);
    if (error != null) return error;
    try {
      await AppDataOperations.instance.access(() async {
        // A page can leave after accepting a write, but that write must never
        // enter a database that replaced its original connection while queued.
        if (!isCurrentDatabase()) throw const SelectionCancelled();
        await manager.rename(folder, name);
      });
      renamed = name;
    } on PersistenceFailure catch (failure) {
      if (failure.commitState == PersistenceCommitState.committed) {
        renamed = name;
      }
      rethrow;
    }
    return null;
  }

  try {
    await showInputDialog(
      context: context,
      title: 'Rename'.tl,
      hintText: 'New Name'.tl,
      reportConfirmationFailureOnClose: true,
      onConfirm: (name) {
        final result = confirm(name);
        // The input helper owns the confirmation error and its closing host.
        // Join the accepted write even if the user dismisses the input first.
        confirmation = result.then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {},
        );
        return result;
      },
    );
  } finally {
    final pending = confirmation;
    if (pending != null) await pending;
  }
  final name = renamed;
  if (name == null ||
      !owner.canPresent ||
      !isCurrent() ||
      !isCurrentDatabase() ||
      popup?.isCurrent == false) {
    return;
  }
  // Selecting the new folder can replace the caller's keyed page. Publish only
  // after the input has finished using that page as its presentation owner.
  try {
    onRenamed(name);
  } catch (error, stack) {
    Error.throwWithStackTrace(
      PersistenceFailure(
        commitState: PersistenceCommitState.committed,
        cause: error,
        stackTrace: stack,
      ),
      stack,
    );
  }
}
