import 'package:flutter/material.dart';
import 'package:venera_next/components/async_confirm_dialog.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';

import 'favorite_folder_browser.dart';
import 'favorites_scope.dart';

Future<void> moveFavoriteFolder(
  BuildContext context, {
  required String folder,
  required bool Function() isCurrent,
  required VoidCallback onCommitted,
}) async {
  try {
    if (!context.mounted || !isCurrent()) return;
    final owner = WindowSelectionTask(context);
    if (!owner.canPresent) return;
    final store = FavoritesScope.capture(context);
    final manager = store.manager;
    final generation = manager.connectionGeneration;
    final path = App.dataPath;
    final tree = manager.folderTree;
    final target = tree.named(folder);
    if (target == null) return;
    String? selected = tree.identified(target.parentId ?? '')?.name;
    bool current() =>
        store.isCurrent &&
        manager.connectionGeneration == generation &&
        App.dataPath == path;
    var committed = false;
    await showAsyncConfirmDialog(
      context: context,
      title: 'Move folder'.tl,
      content: '',
      contentBuilder: (dialogContext, enabled) => StatefulBuilder(
        builder: (context, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Moving a folder keeps its comics and favorite settings unchanged.'
                  .tl,
            ),
            const SizedBox(height: 12),
            FavoriteFolderSelect(
              menuOwnerContext: dialogContext,
              tree: tree,
              current: selected,
              allowRoot: true,
              rootsOnly: true,
              disabled: {
                target.name,
                if (tree.childrenOf(target.id).isNotEmpty)
                  ...tree.roots.map((folder) => folder.name),
              },
              onChanged: !enabled
                  ? null
                  : (name) {
                      if (owner.active && current() && isCurrent()) {
                        setState(() => selected = name);
                      }
                    },
            ),
          ],
        ),
      ),
      onConfirm: () async {
        final parentId = selected == null ? null : tree.named(selected!)!.id;
        if (!owner.active || !current() || !isCurrent()) {
          throw const SelectionCancelled();
        }
        await AppDataOperations.instance.access(() async {
          if (!current() || manager.folderTree.named(folder)?.id != target.id) {
            throw const SelectionCancelled();
          }
          await manager.moveFolder(folder, parentId);
        });
        committed = true;
      },
    );
    if (committed && owner.canPresent && current() && isCurrent()) {
      onCommitted();
    }
  } on SelectionCancelled {
    // A destination choice cannot write through a replaced database or view.
  } catch (error, stack) {
    Log.error('Move favorite folder', error, stack);
  }
}
