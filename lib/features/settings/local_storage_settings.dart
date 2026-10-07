import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/translations.dart';

import 'settings_task_presenter.dart';

/// Keep the recovery entry usable when the active storage path cannot be read.
class LocalStorageSettings extends StatefulWidget {
  const LocalStorageSettings({super.key, this.manager});
  final LocalManager? manager;

  @override
  State<LocalStorageSettings> createState() => _LocalStorageSettingsState();
}

class _LocalStorageSettingsState extends State<LocalStorageSettings> {
  final _tasks = SettingsTaskPresenter();

  Future<void> _run(LocalManager manager) async {
    final recovering = manager.requiresStorageRecovery;
    await _tasks.run(
      context,
      task: (operation) async {
        if (recovering) {
          await manager.recoverStorage();
          return null;
        }
        final selection = await operation.pickDirectory(
          () =>
              DirectoryPicker().pickDirectory(checkStop: operation.checkActive),
        );
        if (selection == null) {
          operation.cancel();
          return null;
        }
        return operation.useDirectory(selection, (directory) async {
          await selection.retainAccessForSession();
          operation.checkActive();
          return manager.setNewPath(directory.path);
        });
      },
      errorMessage: recovering
          ? 'Storage recovery failed. Please retry.'.tl
          : 'Error'.tl,
      successMessage: recovering
          ? 'Storage access restored'.tl
          : 'Path set successfully'.tl,
    );
    // Failure can change a formerly known root into an unresolved one too.
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final manager = widget.manager ?? LocalManager();
    final recovering = manager.requiresStorageRecovery;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          title: Text('Storage Path for local comics'.tl),
          subtitle: Semantics(
            liveRegion: recovering,
            child: Text(
              recovering ? 'Local storage needs recovery'.tl : manager.path,
            ),
          ),
          trailing: IconButton(
            tooltip: 'Copy'.tl,
            icon: const Icon(Icons.copy),
            onPressed: recovering
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: manager.path));
                    context.showMessage(message: 'Path copied to clipboard'.tl);
                  },
          ),
        ),
        ListTile(
          title: Text(
            recovering ? 'Recover Local Storage'.tl : 'Set New Storage Path'.tl,
          ),
          trailing: TextButton(
            onPressed: () => _run(manager),
            child: Text(recovering ? 'Retry'.tl : 'Set'.tl),
          ),
          onTap: () => _run(manager),
        ),
      ],
    );
  }
}
