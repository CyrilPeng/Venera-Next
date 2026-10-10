import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';

import 'follow_updates_manager.dart';
import 'follow_updates_runtime.dart';

/// Preparation can be cancelled. Once accepted, the final assignment is owned
/// by SettingsSaveState; retry only persists that captured assignment.
class FollowUpdatesFolderDialog extends StatefulWidget {
  const FollowUpdatesFolderDialog({
    super.key,
    required this.runtime,
    required this.onSaved,
    this.createCheck,
  });
  final FollowUpdatesRuntime runtime;
  final VoidCallback onSaved;
  final FollowUpdateJob Function(String)? createCheck;

  @override
  State<FollowUpdatesFolderDialog> createState() =>
      _FollowUpdatesFolderDialogState();
}

class _FollowUpdatesFolderDialogState
    extends SettingsSaveState<FollowUpdatesFolderDialog> {
  late final LocalFavoritesManager _manager;
  late final int _generation;
  late final List<String> _folders;
  String? _selected;
  Object? _preparationError;
  Future<void>? _preparation;
  FollowUpdateJob? _job;
  double? _progress;
  bool _cancelled = false;
  bool _leavingPreparation = false;
  WindowFrameController? _preparationWindow;

  @override
  void initState() {
    super.initState();
    _manager = FavoritesScope.read(context);
    _generation = _manager.connectionGeneration;
    _folders = List<String>.unmodifiable(_manager.folderNames);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final window = context
        .dependOnInheritedWidgetOfExactType<WindowFrameController>();
    if (window?.addExitTask != _preparationWindow?.addExitTask) {
      _preparationWindow?.removeExitTask(_stopPreparation);
      final preparation = _preparation;
      if (preparation != null) {
        _cancelPreparation();
        _preparationWindow?.trackExitTask(preparation);
      }
      _preparationWindow = window;
      window?.addExitTask(_stopPreparation);
    }
  }

  @override
  void didUpdateWidget(FollowUpdatesFolderDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime ||
        oldWidget.createCheck != widget.createCheck) {
      _cancelPreparation();
    }
  }

  void _cancelPreparation() {
    _cancelled = true;
    _job?.cancel();
  }

  Future<void> _stopPreparation() {
    final preparation = _preparation;
    _cancelPreparation();
    return preparation ?? Future.value();
  }

  Future<void> _leave() async {
    if (_leavingPreparation) return;
    _leavingPreparation = true;
    try {
      await _stopPreparation();
      // Let PopScope publish the completed preparation before asking it to pop.
      if (mounted) await WidgetsBinding.instance.endOfFrame;
      if (mounted) await leaveSettings();
    } catch (error) {
      if (mounted) context.showMessage(message: error.toString());
    } finally {
      _leavingPreparation = false;
    }
  }

  Future<void> _confirm(String? folder) async {
    if (!acceptsSettingsChanges ||
        _preparation != null ||
        savingSettings ||
        hasSettingsSaveError) {
      return;
    }
    final runtime = widget.runtime;
    final createCheck = widget.createCheck;
    final onSaved = widget.onSaved;
    _cancelled = false;
    _preparationError = null;
    _progress = null;
    final done = Completer<void>();
    setState(() {
      _preparation = done.future;
    });
    bool active() =>
        mounted &&
        !_cancelled &&
        acceptsSettingsChanges &&
        widget.runtime == runtime &&
        widget.createCheck == createCheck;
    Future<void> prepare() async {
      runtime.cancelChecking();
      FollowUpdateJob.cancelActive();
      if (folder != null) {
        final prepared = await _manager.prepareTableForFollowUpdates(
          folder,
          generation: _generation,
          isCurrent: active,
        );
        if (!prepared || !active()) return;
        if (_manager.count(folder) > 0) {
          final job = _job =
              createCheck?.call(folder) ??
              FollowUpdateJob(folder, true, manager: _manager);
          // Consume progress to start the job; done owns actual completion and
          // its errors independently of the presentation stream.
          final progress = job.progress.listen((value) {
            if (mounted && identical(_job, job)) {
              setState(() => _progress = value.fraction);
            }
          }, onError: (Object _, StackTrace _) {});
          try {
            await job.done;
          } finally {
            await progress.cancel();
            if (identical(_job, job)) _job = null;
          }
          if (job.isCancelled || !active()) return;
        }
      }
      if (!active()) return;
      await saveSetting(
        FavoritePreferences.followUpdatesFolder.key,
        () => _manager.setFollowUpdatesFolder(folder, generation: _generation),
        isCurrent: () =>
            widget.runtime == runtime && widget.createCheck == createCheck,
        onSaved: () {
          onSaved();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) leaveSettings();
          });
        },
      );
    }

    Future<void>.sync(prepare).then(done.complete, onError: done.completeError);
    try {
      await done.future;
    } catch (error, stack) {
      Log.error('Follow updates preparation', error, stack);
      if (mounted) setState(() => _preparationError = error);
    } finally {
      if (identical(_preparation, done.future)) _preparation = null;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _preparation != null || savingSettings || hasSettingsSaveError;
    return PopScope(
      canPop: _preparation == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_leave());
      },
      child: protectSettings(
        ContentDialog(
          title: 'Choose Folder'.tl,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Folder'.tl),
              const SizedBox(height: 8),
              AbsorbPointer(
                absorbing: busy,
                child: Select(
                  minWidth: 120,
                  current: _selected,
                  values: _folders,
                  onTap: (index) {
                    if (!mounted ||
                        !acceptsSettingsChanges ||
                        _preparation != null ||
                        savingSettings ||
                        hasSettingsSaveError ||
                        index < 0 ||
                        index >= _folders.length) {
                      return;
                    }
                    setState(() => _selected = _folders[index]);
                  },
                ),
              ),
              if (_preparation != null && !savingSettings) ...[
                const SizedBox(height: 16),
                Text('Updating comics...'.tl),
                LinearProgressIndicator(value: _progress),
              ],
              if (_preparationError != null) Text(_preparationError.toString()),
            ],
          ),
          actions: [
            Expanded(
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  settingsSaveStatus,
                  if (_preparation != null && !savingSettings)
                    TextButton(onPressed: _leave, child: Text('Cancel'.tl)),
                  if (GlobalPreferenceStore(
                        appdata.settings,
                      ).read(FavoritePreferences.followUpdatesFolder) !=
                      null)
                    TextButton(
                      onPressed: busy ? null : () => _confirm(null),
                      child: Text('Disable'.tl),
                    ),
                  FilledButton(
                    onPressed: busy || _selected == null
                        ? null
                        : () => _confirm(_selected),
                    child: Text('Confirm'.tl),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _cancelPreparation();
    _preparationWindow?.removeExitTask(_stopPreparation);
    final preparation = _preparation;
    if (preparation != null) _preparationWindow?.trackExitTask(preparation);
    super.dispose();
  }
}
