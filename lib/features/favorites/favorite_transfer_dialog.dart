import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';

import 'favorite_actions.dart' show newFolder;
import 'favorite_models.dart';
import 'favorites_manager.dart';

/// Owns a captured transfer and publishes only its known commit after the
/// popup and complete save callback have stopped using the initiating page.
Future<void> showFavoriteTransferDialog({
  required BuildContext context,
  required LocalFavoritesManager manager,
  required String source,
  required List<FavoriteItem> comics,
  required bool move,
  required bool Function() isCurrent,
  required VoidCallback onCommitted,
}) {
  final result = _showFavoriteTransferDialog(
    context: context,
    manager: manager,
    source: source,
    comics: comics,
    move: move,
    isCurrent: isCurrent,
    onCommitted: onCommitted,
  );
  unawaited(
    result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        Log.error('Favorite transfer presentation', error, stack);
      },
    ),
  );
  return result;
}

Future<void> _showFavoriteTransferDialog({
  required BuildContext context,
  required LocalFavoritesManager manager,
  required String source,
  required List<FavoriteItem> comics,
  required bool move,
  required bool Function() isCurrent,
  required VoidCallback onCommitted,
}) async {
  if (!context.mounted || !isCurrent()) return;
  final owner = WindowSelectionTask(context);
  final parentPopup = context
      .getInheritedWidgetOfExactType<PopupIndicatorWidget>()
      ?.route;
  if (!owner.canPresent || parentPopup?.isCurrent == false) return;
  final generation = manager.connectionGeneration;
  final path = App.dataPath;
  final items = comics.map((item) => item.detached()).toList();
  bool currentDatabase() =>
      identical(LocalFavoritesManager.cache, manager) &&
      manager.connectionGeneration == generation &&
      App.dataPath == path;
  if (!currentDatabase() || !manager.existsFolder(source)) return;
  var folders = manager.folderNames.where((name) => name != source).toList();
  final selected = <String>{};
  final navigator = Navigator.of(context, rootNavigator: true);
  final disposed = Completer<void>();
  final removalFailed = Completer<void>();
  removalFailed.future.ignore();
  Future<void>? confirmationEnded;
  var ended = false;
  var saving = false;
  var confirmed = false;
  var committed = false;
  String? error;
  WindowSelectionTask? presentationOwner;
  PopUpWidget<void>? popup;

  void finish() {
    if (ended) return;
    ended = true;
    disposed.complete();
  }

  bool currentPresentation() =>
      !ended &&
      presentationOwner?.canPresent == true &&
      popup?.isCurrent == true;
  bool canDismiss() => !saving && currentPresentation();
  bool canEdit() =>
      !saving &&
      !confirmed &&
      currentPresentation() &&
      owner.canPresent &&
      parentPopup?.isActive != false &&
      isCurrent() &&
      currentDatabase();

  try {
    await owner.run<void>((operation) async {
      operation.checkActive();
      if (!isCurrent() || !currentDatabase()) {
        throw const SelectionCancelled();
      }
      final route = popup = PopUpWidget<void>(
        StatefulBuilder(
          builder: (view, setState) {
            presentationOwner ??= WindowSelectionTask(view);
            void showFailure(Object failure, StackTrace stack) {
              Log.error('Transfer favorites', failure, stack);
              error = failure.toString();
              if (view.mounted && !ended) setState(() {});
            }

            void dismiss() {
              if (!canDismiss()) return;
              try {
                navigator.pop();
              } catch (failure, stack) {
                showFailure(failure, stack);
              }
            }

            return NavigationAdmission(
              allowsNavigation: canDismiss,
              child: PopUpWidgetScaffold(
                title: source,
                onBack: dismiss,
                body: Padding(
                  padding: EdgeInsets.only(bottom: view.padding.bottom + 16),
                  child: Container(
                    constraints: const BoxConstraints(
                      maxHeight: 700,
                      maxWidth: 500,
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          child: ListView.builder(
                            itemCount: folders.length + 1,
                            itemBuilder: (_, index) {
                              if (index == folders.length) {
                                return Center(
                                  child: TextButton(
                                    onPressed: saving || confirmed
                                        ? null
                                        : () {
                                            if (!canEdit()) return;
                                            newFolder(
                                              view,
                                              onChanged: (names) {
                                                if (!view.mounted ||
                                                    !canEdit()) {
                                                  return;
                                                }
                                                setState(() {
                                                  folders = names
                                                      .where(
                                                        (name) =>
                                                            name != source,
                                                      )
                                                      .toList();
                                                  selected.retainAll(folders);
                                                });
                                              },
                                            );
                                          },
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.add, size: 20),
                                        const SizedBox(width: 4),
                                        Flexible(child: Text('New Folder'.tl)),
                                      ],
                                    ),
                                  ),
                                );
                              }
                              final folder = folders[index];
                              return CheckboxListTile(
                                title: Text(folder),
                                value: selected.contains(folder),
                                onChanged: saving || confirmed
                                    ? null
                                    : (value) {
                                        if (!canEdit() || value == null) return;
                                        setState(() {
                                          if (value) {
                                            selected.add(folder);
                                          } else {
                                            selected.remove(folder);
                                          }
                                        });
                                      },
                              );
                            },
                          ),
                        ),
                        Center(
                          child: Semantics(
                            button: true,
                            enabled: !saving,
                            label: saving
                                ? (move ? 'Move'.tl : 'Add'.tl)
                                : null,
                            child: ExcludeSemantics(
                              excluding: saving,
                              child: FilledButton(
                                onPressed: saving
                                    ? null
                                    : () async {
                                        if (saving) return;
                                        if (confirmed) {
                                          dismiss();
                                          return;
                                        }
                                        if (!canEdit() ||
                                            selected.isEmpty ||
                                            items.isEmpty) {
                                          return;
                                        }
                                        final targets = List<String>.of(
                                          selected,
                                        );
                                        final confirmation =
                                            WindowSelectionTask(view);
                                        final completed = Completer<void>();
                                        confirmationEnded = completed.future;
                                        setState(() {
                                          saving = true;
                                          error = null;
                                        });
                                        try {
                                          await confirmation.run<void>((
                                            operation,
                                          ) async {
                                            operation.checkActive();
                                            await AppDataOperations.instance
                                                .access(() async {
                                                  if (!currentDatabase() ||
                                                      !manager.existsFolder(
                                                        source,
                                                      ) ||
                                                      targets.any(
                                                        (name) => !manager
                                                            .existsFolder(name),
                                                      )) {
                                                    throw const SelectionCancelled();
                                                  }
                                                  await manager
                                                      .transferFavorites(
                                                        source,
                                                        targets,
                                                        items,
                                                        move: move,
                                                      );
                                                });
                                          }, reportFailureOnClose: true);
                                          committed = true;
                                          confirmed = true;
                                          if (currentPresentation()) {
                                            navigator.pop();
                                          }
                                        } catch (failure, stack) {
                                          if (failure is SelectionCancelled) {
                                            return;
                                          }
                                          if (failure is PersistenceFailure &&
                                              failure.commitState !=
                                                  PersistenceCommitState
                                                      .notCommitted) {
                                            confirmed = true;
                                            committed =
                                                failure.commitState ==
                                                PersistenceCommitState
                                                    .committed;
                                          }
                                          showFailure(failure, stack);
                                        } finally {
                                          saving = false;
                                          try {
                                            if (view.mounted && !ended) {
                                              setState(() {});
                                            }
                                          } finally {
                                            completed.complete();
                                          }
                                        }
                                      },
                                child: saving
                                    ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Text(
                                        confirmed
                                            ? 'OK'.tl
                                            : move
                                            ? 'Move'.tl
                                            : 'Add'.tl,
                                      ),
                              ),
                            ),
                          ),
                        ),
                        if (error != null)
                          Flexible(
                            child: SingleChildScrollView(child: Text(error!)),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        onDispose: finish,
        canDismiss: canDismiss,
      );
      final release = owner.retainPresentation(() {
        try {
          if (navigator.mounted && route.isActive) {
            navigator.removeRoute(route);
          } else {
            finish();
          }
        } catch (failure, stack) {
          if (!removalFailed.isCompleted) {
            removalFailed.completeError(failure, stack);
          }
          rethrow;
        }
      }, isCurrent: () => route.isCurrent);
      await Future.any<void>([
        navigator.push(route),
        disposed.future,
        removalFailed.future,
      ]);
      release();
    });
  } on SelectionCancelled {
    // Retiring a queued target cannot redirect a transfer to a replacement.
  } finally {
    if (popup?.navigator == null) finish();
    await confirmationEnded;
  }
  if (!committed ||
      !owner.canPresent ||
      !isCurrent() ||
      !currentDatabase() ||
      parentPopup?.isCurrent == false) {
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
