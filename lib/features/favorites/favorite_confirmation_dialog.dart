import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/async_confirm_dialog.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/selection_operation.dart';

import 'favorites_manager.dart';

/// Presents a captured favorite mutation and publishes only a known commit to
/// the original page after the confirmation has stopped using that page.
Future<void> confirmFavoriteMutation({
  required BuildContext context,
  required LocalFavoritesManager manager,
  required String folder,
  required String title,
  required String content,
  required bool Function() isCurrent,
  required Future<void> Function() mutate,
  required VoidCallback onCommitted,
  Color? btnColor,
}) {
  final result = _confirmFavoriteMutation(
    context: context,
    manager: manager,
    folder: folder,
    title: title,
    content: content,
    isCurrent: isCurrent,
    mutate: mutate,
    onCommitted: onCommitted,
    btnColor: btnColor,
  );
  unawaited(
    result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        Log.error('Favorite confirmation', error, stack);
      },
    ),
  );
  return result;
}

Future<void> _confirmFavoriteMutation({
  required BuildContext context,
  required LocalFavoritesManager manager,
  required String folder,
  required String title,
  required String content,
  required bool Function() isCurrent,
  required Future<void> Function() mutate,
  required VoidCallback onCommitted,
  Color? btnColor,
}) async {
  if (!context.mounted || !isCurrent()) return;
  final owner = WindowSelectionTask(context);
  final popup = context
      .getInheritedWidgetOfExactType<PopupIndicatorWidget>()
      ?.route;
  if (!owner.canPresent || popup?.isCurrent == false) return;
  final generation = manager.connectionGeneration;
  final path = App.dataPath;
  bool isCurrentDatabase() =>
      identical(LocalFavoritesManager.cache, manager) &&
      manager.connectionGeneration == generation &&
      App.dataPath == path;
  if (!isCurrentDatabase() || !manager.existsFolder(folder)) return;
  var committed = false;
  await showAsyncConfirmDialog(
    context: context,
    title: title,
    content: content,
    btnColor: btnColor,
    onConfirm: () async {
      if (!owner.active ||
          !isCurrent() ||
          popup?.isActive == false ||
          !isCurrentDatabase()) {
        throw const SelectionCancelled();
      }
      try {
        await AppDataOperations.instance.access(() async {
          // Accepted work can outlive its page, but cannot enter a replacement
          // database after waiting behind an import or storage migration.
          if (!isCurrentDatabase() || !manager.existsFolder(folder)) {
            throw const SelectionCancelled();
          }
          await mutate();
        });
        committed = true;
      } on PersistenceFailure catch (failure) {
        if (failure.commitState == PersistenceCommitState.committed) {
          committed = true;
        }
        rethrow;
      }
    },
  );
  if (!committed ||
      !owner.canPresent ||
      !isCurrent() ||
      !isCurrentDatabase() ||
      popup?.isCurrent == false) {
    return;
  }
  try {
    onCommitted();
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
