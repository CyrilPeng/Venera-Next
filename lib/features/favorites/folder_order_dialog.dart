import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

Future<void> sortFolders(BuildContext context) {
  final result = _sortFolders(context);
  unawaited(
    result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        Log.error('Sort favorite folders', error, stack);
      },
    ),
  );
  return result;
}

Future<void> _sortFolders(BuildContext context) async {
  if (!context.mounted) return;
  final owner = WindowSelectionTask(context);
  if (!owner.canPresent) return;
  final parentPopup = context
      .getInheritedWidgetOfExactType<PopupIndicatorWidget>()
      ?.route;
  if (parentPopup?.isCurrent == false) return;
  final store = FavoritesScope.capture(context);
  final manager = store.manager;
  final generation = manager.connectionGeneration;
  final dataPath = App.dataPath;
  final folders = List<String>.of(manager.folderNames);
  final navigator = Navigator.of(context, rootNavigator: true);
  bool isCurrentDatabase() =>
      store.isCurrent &&
      manager.connectionGeneration == generation &&
      App.dataPath == dataPath;
  void checkDatabase() {
    if (!isCurrentDatabase()) throw const SelectionCancelled();
  }

  Future<void> present(Route<void> route, Completer<void> ended) async {
    var removalFailed = false;
    final release = owner.retainPresentation(() {
      try {
        if (navigator.mounted && route.isActive) navigator.removeRoute(route);
      } catch (_) {
        removalFailed = true;
        // End presentation even on failure so the accepted draft can be saved.
        // The owner retains this exact route and error for cleanup retry.
        if (!ended.isCompleted) ended.complete();
        rethrow;
      }
    }, isCurrent: () => route.isCurrent);
    await Future.any<void>([navigator.push(route), ended.future]);
    if (!removalFailed) release();
  }

  try {
    await owner.run<void>((operation) async {
      operation.checkActive();
      if (parentPopup?.isCurrent == false) throw const SelectionCancelled();
      checkDatabase();
      final ended = Completer<void>();
      late final PopUpWidget<void> popup;
      WindowSelectionTask? presentationOwner;
      bool canDismiss() =>
          (presentationOwner?.canPresent ?? owner.canPresent) &&
          popup.isCurrent;
      bool canEdit(BuildContext view) =>
          view.mounted &&
          owner.canPresent &&
          parentPopup?.isActive != false &&
          canDismiss() &&
          isCurrentDatabase();
      popup = PopUpWidget<void>(
        StatefulBuilder(
          builder: (view, setState) {
            // The visible popup can dismiss itself after its initiating control
            // disappears; editing still belongs to that original control.
            presentationOwner ??= WindowSelectionTask(view);
            return PopUpWidgetScaffold(
              title: "Sort".tl,
              onBack: () {
                if (view.mounted && canDismiss()) navigator.pop();
              },
              tailing: [
                Tooltip(
                  message: "Help".tl,
                  child: IconButton(
                    icon: const Icon(Icons.help_outline),
                    onPressed: () {
                      if (!canEdit(view)) return;
                      final helpEnded = Completer<void>();
                      late final ResourceDialogRoute<void> help;
                      help = ResourceDialogRoute<void>(
                        context: view,
                        themes: InheritedTheme.capture(
                          from: view,
                          to: navigator.context,
                        ),
                        barrierColor:
                            DialogTheme.of(view).barrierColor ?? Colors.black54,
                        onDispose: () {
                          if (!helpEnded.isCompleted) helpEnded.complete();
                        },
                        builder: (helpContext) => ContentDialog(
                          title: "Reorder".tl,
                          content: Text(
                            "Long press and drag to reorder.".tl,
                          ).paddingHorizontal(16).paddingVertical(8),
                          actions: [
                            Button.filled(
                              onPressed: () {
                                if (helpContext.mounted &&
                                    presentationOwner?.canPresent == true &&
                                    help.isCurrent &&
                                    popup.isActive) {
                                  navigator.pop();
                                }
                              },
                              child: Text("OK".tl),
                            ),
                          ],
                        ),
                      );
                      unawaited(
                        present(help, helpEnded).catchError((
                          Object error,
                          StackTrace stack,
                        ) {
                          Log.error('Folder sort help', error, stack);
                        }),
                      );
                    },
                  ),
                ),
              ],
              body: ReorderableListView.builder(
                onReorder: (oldIndex, newIndex) {
                  if (!canEdit(view)) return;
                  if (oldIndex < newIndex) newIndex--;
                  setState(() {
                    final item = folders.removeAt(oldIndex);
                    folders.insert(newIndex, item);
                  });
                },
                itemCount: folders.length,
                itemBuilder: (context, index) => ListTile(
                  key: ValueKey(folders[index]),
                  title: Text(folders[index]),
                ),
              ),
            );
          },
        ),
        onDispose: () {
          if (!ended.isCompleted) ended.complete();
        },
        canDismiss: canDismiss,
      );
      await present(popup, ended);
      final order = List<String>.of(folders);
      // Closing the original host must still persist its accepted draft.
      // Database replacement, however, retires the old write at admission.
      await AppDataOperations.instance.access(() async {
        checkDatabase();
        await manager.updateOrder(order);
      });
    }, reportFailureOnClose: true);
  } on SelectionCancelled {
    // No old order is written into a replacement database or application path.
  } catch (error) {
    if (context.mounted &&
        owner.canPresent &&
        parentPopup?.isCurrent != false) {
      context.showMessage(message: error.toString());
    }
    rethrow;
  }
}
