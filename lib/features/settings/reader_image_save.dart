import 'package:flutter/material.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/image_directory_save.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';

String imageSaveDirectoryLabel(String path) => path.startsWith('android://')
    ? path.substring('android://'.length).replaceFirst(RegExp(r'^primary:'), '')
    : path;

class ReaderImageSaveSetting extends StatefulWidget {
  const ReaderImageSaveSetting({super.key});
  @override
  State<ReaderImageSaveSetting> createState() => _ReaderImageSaveSettingState();
}

class _ReaderImageSaveSettingState
    extends SettingsSaveState<ReaderImageSaveSetting> {
  bool _choosing = false;

  @override
  void initState() {
    super.initState();
    appdata.settings.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _choose() async {
    if (_choosing || !acceptsSettingsChanges) return;
    setState(() => _choosing = true);
    final task = WindowSelectionTask(context);
    try {
      await task.run((operation) async {
        final selection = await operation.pickDirectory(
          () => DirectoryPicker().pickDirectory(),
        );
        if (selection == null) return;
        final path = await operation.useDirectory(
          selection,
          (directory) async => directory.path,
        );
        operation.checkActive();
        await saveSetting(
          ImageSavePreferences.directory.key,
          () => appdata.updateSettings(
            (draft) => draft[ImageSavePreferences.directory.key] = path,
            sync: false,
          ),
        );
      });
    } on SelectionCancelled {
      // The picker retains its real completion after page/window cancellation.
    } catch (error, stack) {
      Log.error('Image save directory', error, stack);
      if (mounted && task.canPresent) {
        context.showMessage(
          message: 'Unable to select an image save directory'.tl,
        );
      }
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ImageDirectorySaver.supported) return const SizedBox.shrink();
    final directory = ImageSavePreferences.directory.normalize(
      appdata.settings[ImageSavePreferences.directory.key],
    );
    final enabled = acceptsSettingsChanges && !_choosing && !savingSettings;
    return protectSettings(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text('Image save directory'.tl),
            subtitle: Text(
              directory == null
                  ? 'Ask every time'.tl
                  : imageSaveDirectoryLabel(directory),
            ),
            onTap: enabled ? _choose : null,
          ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 8),
            child: Wrap(
              spacing: 12,
              children: [
                TextButton.icon(
                  onPressed: enabled ? _choose : null,
                  icon: const Icon(Icons.folder_open),
                  label: Text('Choose folder'.tl),
                ),
                if (directory != null)
                  TextButton(
                    onPressed: enabled
                        ? () => saveSetting(
                            ImageSavePreferences.directory.key,
                            () => appdata.updateSettings(
                              (draft) =>
                                  draft[ImageSavePreferences.directory.key] =
                                      null,
                              sync: false,
                            ),
                          )
                        : null,
                    child: Text('Ask every time'.tl),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'The folder is saved on this device. Hold the image save button to save elsewhere.'
                  .tl,
            ),
          ),
          settingsSaveStatus,
        ],
      ),
    );
  }
}
