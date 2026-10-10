import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'folder_name_validation.dart';
import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'network_favorite_import.dart';
import 'network_favorite_import_dialog.dart';
import 'favorite_models.dart';
import 'create_favorite_folder_dialog.dart';
import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/async_confirm_dialog.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/translations.dart';

/// Open a dialog to create a new favorite folder.
Future<void> newFolder(
  BuildContext context, {
  ValueChanged<List<String>>? onChanged,
}) {
  final result = _newFolder(context, onChanged: onChanged);
  unawaited(
    result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        Log.error('Favorite folder presentation', error, stack);
      },
    ),
  );
  return result;
}

Future<void> _newFolder(
  BuildContext context, {
  ValueChanged<List<String>>? onChanged,
}) async {
  final owner = WindowSelectionTask(context);
  if (!owner.canPresent) return;
  // Popup content has its own Navigator; its inner route can remain current
  // while another root route covers the popup.
  final popup = context
      .getInheritedWidgetOfExactType<PopupIndicatorWidget>()
      ?.route;
  if (popup?.isCurrent == false) return;
  final store = FavoritesScope.capture(context);
  final manager = store.manager;
  final generation = manager.connectionGeneration;
  final dataPath = App.dataPath;
  bool isCurrent() =>
      store.isCurrent &&
      manager.connectionGeneration == generation &&
      App.dataPath == dataPath;
  void checkCurrent() {
    if (!isCurrent()) throw const SelectionCancelled();
  }

  Future<void> write(FutureOr<void> Function() action) =>
      AppDataOperations.instance.access(() async {
        checkCurrent();
        await action();
      });
  final navigator = Navigator.of(context, rootNavigator: true);
  final disposed = Completer<void>();
  final removalFailed = Completer<void>();
  removalFailed.future.ignore();
  try {
    await owner.run<void>((operation) async {
      operation.checkActive();
      if (popup?.isCurrent == false) throw const SelectionCancelled();
      checkCurrent();
      late final ResourceDialogRoute<void> dialog;
      dialog = ResourceDialogRoute<void>(
        context: context,
        themes: InheritedTheme.capture(from: context, to: navigator.context),
        barrierColor: DialogTheme.of(context).barrierColor ?? Colors.black54,
        onDispose: () {
          if (!disposed.isCompleted) disposed.complete();
        },
        builder: (_) => CreateFavoriteFolderDialog(
          isCurrent: () =>
              owner.canPresent &&
              dialog.isCurrent &&
              popup?.isActive != false &&
              isCurrent(),
          validate: (name) {
            checkCurrent();
            return validateFolderName(name, folders: manager.folderNames);
          },
          create: (name) => write(() async => await manager.createFolder(name)),
          selectImport: (operation) async {
            checkCurrent();
            final file = await operation.pickFile(
              () => selectFile(ext: ['json'], checkStop: operation.checkActive),
            );
            return file == null
                ? null
                : operation.useFile(
                    file,
                    (selected) async =>
                        utf8.decode(await selected.readAsBytes()),
                  );
          },
          importJson: (json) => write(() => manager.fromJson(json)),
        ),
      );
      final release = owner.retainPresentation(() {
        try {
          if (navigator.mounted && dialog.isActive) {
            navigator.removeRoute(dialog);
          }
        } catch (error, stack) {
          if (!removalFailed.isCompleted) {
            removalFailed.completeError(error, stack);
          }
          rethrow;
        }
      }, isCurrent: () => dialog.isCurrent);
      await Future.any<void>([
        navigator.push(dialog),
        disposed.future,
        removalFailed.future,
      ]);
      release();
    });
    if (owner.canPresent && popup?.isCurrent != false && isCurrent()) {
      onChanged?.call(List.unmodifiable(manager.folderNames));
    }
  } on SelectionCancelled {
    // The original caller or database can retire before presentation or commit.
  }
}

Future<void> addFavorite(
  BuildContext context,
  List<Comic> comics, {
  bool Function()? isCurrent,
}) {
  final result = _addFavorite(context, comics, isCurrent: isCurrent);
  unawaited(
    result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        Log.error('Add favorites', error, stack);
      },
    ),
  );
  return result;
}

Future<void> _addFavorite(
  BuildContext context,
  List<Comic> comics, {
  bool Function()? isCurrent,
}) async {
  if (!context.mounted || isCurrent?.call() == false) return;
  final owner = WindowSelectionTask(context);
  final store = FavoritesScope.capture(context);
  final manager = store.manager;
  if (!owner.canPresent) return;
  final generation = manager.connectionGeneration;
  final dataPath = App.dataPath;
  final folders = List<String>.unmodifiable(manager.folderNames);
  if (folders.isEmpty) return;
  final items = comics
      .map(
        (comic) => FavoriteItem(
          id: comic.id,
          name: comic.title,
          coverPath: comic.cover,
          author: comic.subtitle ?? '',
          type: ComicType(
            comic.sourceKey == 'local' ? 0 : comic.sourceKey.hashCode,
          ),
          tags: List.of(comic.tags ?? []),
        ),
      )
      .toList();
  bool currentDatabase() =>
      store.isCurrent &&
      manager.connectionGeneration == generation &&
      App.dataPath == dataPath;
  String? selectedFolder = GlobalPreferenceStore(
    appdata.settings,
  ).read(FavoritePreferences.quickFavorite);
  if (!folders.contains(selectedFolder)) selectedFolder = null;
  await showAsyncConfirmDialog(
    context: context,
    title: 'Select a folder'.tl,
    content: '',
    contentBuilder: (dialogContext, enabled) => StatefulBuilder(
      builder: (context, setState) => ListTile(
        title: Text('Folder'.tl),
        trailing: Select(
          current: selectedFolder,
          values: folders,
          minWidth: 112,
          onTap: (index) {
            if (!enabled ||
                !context.mounted ||
                !owner.active ||
                isCurrent?.call() == false ||
                !currentDatabase()) {
              return;
            }
            setState(() => selectedFolder = folders[index]);
          },
        ),
      ),
    ),
    onConfirm: () async {
      final folder = selectedFolder;
      if (folder == null ||
          !owner.active ||
          isCurrent?.call() == false ||
          !currentDatabase()) {
        throw const SelectionCancelled();
      }
      await AppDataOperations.instance.access(() async {
        if (!currentDatabase() || !manager.existsFolder(folder)) {
          throw const SelectionCancelled();
        }
        await manager.addComics(folder, items);
      });
    },
  );
}

Future<void> importNetworkFolder(
  BuildContext context,
  String source,
  int updatePageNum,
  String? folder,
  String? folderID, {
  bool Function()? isCurrent,
}) {
  final result = _importNetworkFolder(
    context,
    source,
    updatePageNum,
    folder,
    folderID,
    isCurrent: isCurrent,
  );
  unawaited(
    result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        Log.error('Network favorite import presentation', error, stack);
      },
    ),
  );
  return result;
}

Future<void> _importNetworkFolder(
  BuildContext context,
  String source,
  int updatePageNum,
  String? folder,
  String? folderID, {
  bool Function()? isCurrent,
}) async {
  if (!context.mounted || isCurrent?.call() == false) return;
  final owner = WindowSelectionTask(context);
  if (!owner.canPresent) return;
  final comicSource = ComicSource.find(source);
  final data = comicSource?.favoriteData;
  final store = FavoritesScope.capture(context);
  final manager = store.manager;
  if (comicSource == null || data == null || updatePageNum <= 0) {
    return;
  }
  final resultName = folder == null || folder.isEmpty
      ? comicSource.name
      : folder;
  if (manager.existsFolder(resultName) &&
      !manager.isLinkedToNetworkFolder(resultName, source, folderID ?? '')) {
    context.showMessage(message: 'Folder already exists'.tl);
    return;
  }
  final generation = manager.connectionGeneration;
  final dataPath = App.dataPath;
  bool currentDatabase() =>
      store.isCurrent &&
      manager.connectionGeneration == generation &&
      App.dataPath == dataPath;
  bool currentTarget() =>
      owner.active &&
      isCurrent?.call() != false &&
      currentDatabase() &&
      identical(ComicSource.find(source), comicSource) &&
      identical(comicSource.favoriteData, data);
  void checkTarget() {
    if (!currentTarget()) throw const RequestCancelled();
  }

  final navigator = Navigator.of(context, rootNavigator: true);
  final disposed = Completer<void>();
  final removalFailed = Completer<void>();
  removalFailed.future.ignore();
  Future<void>? lastWork;
  Object? presentationError;
  StackTrace? presentationStack;
  try {
    await owner.run<void>((operation) async {
      operation.checkActive();
      checkTarget();
      late final ResourceDialogRoute<void> route;
      final content = NetworkFavoriteImportDialog(
        isCurrent: currentTarget,
        onStarted: (work) => lastWork = work,
        collect: (scope, progress) => collectNetworkFavorites(
          data: data,
          sourceKey: source,
          folderId: folderID,
          pageLimit: updatePageNum,
          scope: scope,
          isCurrent: currentTarget,
          exists: (id) =>
              manager.existsFolder(resultName) &&
              manager.comicExists(resultName, id, ComicType(source.hashCode)),
          onProgress: progress,
        ),
        publish: (result) async {
          if (currentDatabase()) {
            await manager.publishNetworkFavoriteImport(result);
          }
        },
        commit: (items, scope) => AppDataOperations.instance.access(() async {
          scope.check();
          checkTarget();
          return manager.importNetworkFavorites(
            resultName,
            source,
            folderID ?? '',
            items,
            oldToNew: data.isOldToNewSort ?? false,
            checkActive: () {
              scope.check();
              checkTarget();
            },
            generation: generation,
          );
        }),
      );
      route = ResourceDialogRoute<void>(
        context: context,
        themes: InheritedTheme.capture(from: context, to: navigator.context),
        barrierColor: DialogTheme.of(context).barrierColor ?? Colors.black54,
        onDispose: () {
          if (!disposed.isCompleted) disposed.complete();
        },
        builder: (_) => content,
      );
      final release = owner.retainPresentation(() {
        try {
          if (navigator.mounted && route.isActive) navigator.removeRoute(route);
        } catch (error, stack) {
          if (!removalFailed.isCompleted) {
            removalFailed.completeError(error, stack);
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
    // No presentation was admitted.
  } on RequestCancelled {
    // The captured source or database retired before admission.
  } catch (error, stack) {
    presentationError = error;
    presentationStack = stack;
  }
  try {
    await lastWork;
  } on SelectionCancelled {
    // Closing a view cancels further reads, but has already drained accepted work.
  } catch (error, stack) {
    if (presentationError != null) {
      throw SelectionCleanupFailure(
        [(error: presentationError, stack: presentationStack!)],
        operationError: error,
        operationStack: stack,
      );
    }
    rethrow;
  }
  if (presentationError != null) {
    Error.throwWithStackTrace(presentationError, presentationStack!);
  }
}
