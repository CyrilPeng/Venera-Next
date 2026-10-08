import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';
import 'package:venera_next/network/request_scope.dart';

import 'favorite_metadata_update.dart';
import 'favorites_manager.dart';

Future<void> showFavoriteMetadataDialog({
  required BuildContext context,
  required WindowSelectionTask owner,
  required LocalFavoritesManager manager,
  required String folder,
  required bool Function() isCurrent,
}) {
  final result = _showFavoriteMetadataDialog(
    context: context,
    owner: owner,
    manager: manager,
    folder: folder,
    isCurrent: isCurrent,
  );
  unawaited(
    result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        Log.error('Favorite metadata presentation', error, stack);
      },
    ),
  );
  return result;
}

Future<void> _showFavoriteMetadataDialog({
  required BuildContext context,
  required WindowSelectionTask owner,
  required LocalFavoritesManager manager,
  required String folder,
  required bool Function() isCurrent,
}) async {
  if (!context.mounted || !owner.canPresent || !isCurrent()) return;
  final parentPopup = context
      .getInheritedWidgetOfExactType<PopupIndicatorWidget>()
      ?.route;
  if (parentPopup?.isCurrent == false) return;
  final generation = manager.connectionGeneration;
  final path = App.dataPath;
  final navigator = Navigator.of(context, rootNavigator: true);
  final disposed = Completer<void>();
  final removalFailed = Completer<void>();
  removalFailed.future.ignore();
  final changed = ValueNotifier(0);
  FavoriteMetadataProgress? progress;
  FavoriteMetadataUpdate? update;
  FavoriteMetadataResult? result;
  WindowSelectionTask? presentationOwner;
  ResourceDialogRoute<void>? route;
  bool finished = false;
  bool cancelled = false;
  bool abandoned = false;
  Object? runError;
  StackTrace? runStack;
  Object? dismissalError;
  bool taskEnded = false;
  bool notifierDisposed = false;

  void releaseNotifier() {
    if (!notifierDisposed && taskEnded && disposed.isCompleted) {
      notifierDisposed = true;
      changed.dispose();
    }
  }

  void finishPresentation() {
    if (!disposed.isCompleted) disposed.complete();
    releaseNotifier();
  }

  bool canDismiss() =>
      !disposed.isCompleted &&
      presentationOwner?.canPresent == true &&
      route?.isCurrent == true;
  void cancel() {
    if (!finished) {
      abandoned = true;
      cancelled = true;
      update?.cancel();
    }
  }

  void checkTarget() {
    if (!owner.active ||
        !isCurrent() ||
        parentPopup?.isActive == false ||
        !identical(LocalFavoritesManager.cache, manager) ||
        manager.connectionGeneration != generation ||
        App.dataPath != path) {
      throw const RequestCancelled();
    }
  }

  Future<void> runUpdate() async {
    try {
      final comics = await AppDataOperations.instance.access(() async {
        checkTarget();
        if (cancelled || !manager.existsFolder(folder)) {
          throw const RequestCancelled();
        }
        return manager.getFolderComics(folder);
      });
      final sources = {
        for (final item in comics) item.type.value: item.type.comicSource,
      };
      final loaders = {
        for (final entry in sources.entries)
          entry.key: entry.value?.loadComicInfo,
      };
      void checkSource(int type) {
        checkTarget();
        final source = sources[type];
        if (source != null &&
            !identical(ComicSource.fromIntKey(type), source)) {
          throw const RequestCancelled();
        }
      }

      late final FavoriteMetadataUpdate operation;
      operation = update = FavoriteMetadataUpdate(
        comics: comics,
        load: (item) async {
          checkSource(item.type.value);
          if (sources[item.type.value] == null) return null;
          final loader = loaders[item.type.value];
          if (loader == null) {
            throw UnsupportedError('Source does not support comic metadata');
          }
          return loader(item.id);
        },
        save: (item) => AppDataOperations.instance.access(() async {
          operation.checkActive();
          checkSource(item.type.value);
          if (!manager.existsFolder(folder)) throw const RequestCancelled();
          await manager.updateInfo(
            folder,
            item,
            generation: generation,
            checkActive: () {
              operation.checkActive();
              checkSource(item.type.value);
            },
          );
        }),
        checkActive: checkTarget,
        onProgress: (value) {
          progress = value;
          changed.value++;
        },
      );
      if (cancelled) operation.cancel();
      result = await operation.run();
      cancelled = result!.cancelled;
      for (final failure in result!.failures) {
        Log.error('Favorite metadata', failure, failure.stackTrace);
      }
    } on RequestCancelled {
      cancelled = true;
    } on SelectionCancelled {
      cancelled = true;
    } catch (error, stack) {
      runError = error;
      runStack = stack;
    } finally {
      finished = true;
      changed.value++;
    }
  }

  try {
    await owner.run<void>((operation) async {
      operation.checkActive();
      checkTarget();
      final dialog = route = ResourceDialogRoute<void>(
        context: context,
        themes: InheritedTheme.capture(from: context, to: navigator.context),
        barrierColor: DialogTheme.of(context).barrierColor ?? Colors.black54,
        onDispose: finishPresentation,
        builder: (view) {
          presentationOwner ??= WindowSelectionTask(view);
          void dismiss() {
            if (!canDismiss()) return;
            cancel();
            try {
              navigator.pop();
              dismissalError = null;
            } catch (error, stack) {
              Log.error('Favorite metadata dismissal', error, stack);
              dismissalError = error;
              changed.value++;
            }
          }

          return NavigationAdmission(
            allowsNavigation: canDismiss,
            child: ValueListenableBuilder(
              valueListenable: changed,
              builder: (_, value, _) {
                final total = progress?.total;
                final completed = progress?.completed ?? 0;
                final errors = progress?.failed ?? 0;
                final errorLabel = 'Error'.tl;
                final visibleError = dismissalError ?? runError;
                return ContentDialog(
                  title: visibleError != null
                      ? 'Error'.tl
                      : !finished
                      ? 'Updating'.tl
                      : cancelled
                      ? 'Cancelled'.tl
                      : 'Finished'.tl,
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: total == null
                            ? null
                            : total == 0
                            ? 1
                            : completed / total,
                      ),
                      const SizedBox(height: 4),
                      if (total != null) Text('$completed/$total'),
                      const SizedBox(height: 4),
                      if (errors > 0) Text('$errorLabel: $errors'),
                      if (visibleError != null) Text(visibleError.toString()),
                    ],
                  ).paddingHorizontal(16),
                  actions: [
                    Button.filled(
                      color: finished ? null : view.colorScheme.error,
                      onPressed: dismiss,
                      child: Text(finished ? 'OK'.tl : 'Cancel'.tl),
                    ),
                  ],
                );
              },
            ),
          );
        },
      );
      final release = owner.retainPresentation(() {
        cancel();
        try {
          if (navigator.mounted && dialog.isActive) {
            navigator.removeRoute(dialog);
          } else {
            finishPresentation();
          }
        } catch (error, stack) {
          if (!removalFailed.isCompleted) {
            removalFailed.completeError(error, stack);
          }
          rethrow;
        }
      }, isCurrent: () => dialog.isCurrent);
      Object? presentationError;
      StackTrace? presentationStack;
      final presentation =
          Future.any<void>([
            navigator.push(dialog),
            disposed.future,
            removalFailed.future,
          ]).then<void>(
            (_) {
              cancel();
              release();
            },
            onError: (Object error, StackTrace stack) {
              cancel();
              presentationError = error;
              presentationStack = stack;
            },
          );
      // Both branches record their own error so neither hides the other's
      // failure while the original host drains accepted source work.
      await Future.wait<void>([presentation, runUpdate()]);
      Object? failure = runError;
      StackTrace? stack = runStack;
      final errors = result?.failures;
      if (failure == null && abandoned && errors != null && errors.isNotEmpty) {
        failure = FavoriteMetadataBatchFailure(errors);
        stack = errors.first.stackTrace;
      }
      if (presentationError != null) {
        Error.throwWithStackTrace(
          failure == null
              ? presentationError!
              : SelectionCleanupFailure(
                  [(error: presentationError!, stack: presentationStack!)],
                  operationError: failure,
                  operationStack: stack,
                ),
          presentationStack!,
        );
      }
      if (failure != null) {
        Error.throwWithStackTrace(failure, stack ?? StackTrace.current);
      }
    }, reportFailureOnClose: true);
  } on SelectionCancelled {
    // The original page can disappear before the dialog is admitted.
  } on RequestCancelled {
    // A retired original target never redirects this task.
  } finally {
    taskEnded = true;
    if (route?.navigator == null) finishPresentation();
    releaseNotifier();
  }
}
