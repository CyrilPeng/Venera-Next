import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/app_dio.dart';

import 'comic_source_manager.dart';
import 'source.dart';
import 'source_failure.dart';
import 'source_failure_presentation.dart';
import 'source_mutation_failure.dart';
import 'source_update_service.dart';

/// Retain the exact route and also settle when its navigator is disposed.
/// Navigator disposal alone does not complete the Future returned by push.
Future<bool?> showSourceActionDialog({
  required BuildContext context,
  required WindowSelectionTask task,
  required bool Function() canPresent,
  required Widget Function(BuildContext, void Function(bool)) builder,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final result = Completer<bool?>();
  void complete(bool? value) {
    if (!result.isCompleted) result.complete(value);
  }

  late final DialogRoute<bool> route;
  route = DialogRoute<bool>(
    context: context,
    builder: (context) => DialogResourceScope(
      onDispose: () => complete(null),
      child: builder(context, (value) {
        if (canPresent() && route.isCurrent) navigator.pop(value);
      }),
    ),
  );
  final release = task.retainPresentation(() {
    try {
      if (navigator.mounted && route.isActive) navigator.removeRoute(route);
    } finally {
      complete(null);
    }
  }, isCurrent: () => route.isCurrent);
  try {
    unawaited(
      navigator
          .push(route)
          .then<void>(
            complete,
            onError: (Object error, StackTrace stack) {
              if (!result.isCompleted) result.completeError(error, stack);
            },
          ),
    );
    return await result.future;
  } finally {
    // Failed removal remains registered for the task's cleanup retry.
    if (!navigator.mounted || !route.isActive) release();
  }
}

/// One page's presentation and cancellation of one service request.
class SourceUpdatePrompt {
  SourceUpdatePrompt({
    required BuildContext context,
    required this.source,
    required this.manager,
    required this.service,
    bool Function()? isCurrent,
  }) : _task = WindowSelectionTask(context),
       _dataPath = App.dataPath,
       _isCurrent = isCurrent;

  final ComicSource source;
  final ComicSourceManager manager;
  final SourceUpdateService service;
  final WindowSelectionTask _task;
  final String _dataPath;
  final bool Function()? _isCurrent;
  final _token = CancelToken();
  bool _committing = false;

  bool get _canPresent =>
      _task.canPresent &&
      _dataPath == App.dataPath &&
      !manager.isClosing &&
      !service.isClosed &&
      (_isCurrent?.call() ?? true);

  void _cancelRequest() {
    if (!_committing) service.cancel(source.key, request: _token);
  }

  void cancel() {
    _cancelRequest();
    _task.cancel();
  }

  Future<void> run() async {
    if (!_canPresent ||
        !identical(manager.find(source.key), source) ||
        service.isUpdating(source.key)) {
      return;
    }
    try {
      await _task.run<void>((_) async {
        if (!_canPresent) throw const SelectionCancelled();
        final controller = showLoadingDialog(
          _task.presentationContext!,
          onCancel: cancel,
          barrierDismissible: false,
        );
        _task.retainPresentation(() {
          _cancelRequest();
          controller.close();
        }, isCurrent: () => controller.isCurrent);
        await service.update(
          source,
          cancelToken: _token,
          onCommit: () {
            _committing = true;
            controller.close();
          },
        );
      });
    } on SelectionCancelled {
      // The original page/window no longer accepts a new operation.
    } catch (error, stack) {
      if (error is SourceFailure && error.code == SourceFailureCode.cancelled) {
        return;
      }
      Log.error('Update comic source presentation', error, stack);
      if (_canPresent) {
        _task.presentationContext!.showMessage(
          message: error is DioException
              ? 'Network error'.tl
              : sourceFailureMessage(error),
        );
      }
    }
  }
}

class SourceUpdateCheckButton extends StatefulWidget {
  const SourceUpdateCheckButton({
    required this.manager,
    required this.service,
    this.refresh,
    super.key,
  });

  final ComicSourceManager manager;
  final SourceUpdateService? service;
  final VoidCallback? refresh;

  @override
  State<SourceUpdateCheckButton> createState() =>
      _SourceUpdateCheckButtonState();
}

class _SourceUpdateCheckButtonState extends State<SourceUpdateCheckButton> {
  bool isLoading = false;
  WindowSelectionTask? _task;

  @override
  void didUpdateWidget(covariant SourceUpdateCheckButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.manager, widget.manager) ||
        !identical(oldWidget.service, widget.service)) {
      _task?.cancel();
    }
  }

  @override
  void dispose() {
    _task?.cancel();
    super.dispose();
  }

  Future<void> check() async {
    final service = widget.service;
    final manager = widget.manager;
    final refresh = widget.refresh;
    if (isLoading || service == null || service.isClosed || manager.isClosing) {
      return;
    }
    final task = WindowSelectionTask(context);
    final path = App.dataPath;
    bool canPresent() =>
        mounted &&
        identical(widget.service, service) &&
        identical(widget.manager, manager) &&
        path == App.dataPath &&
        !service.isClosed &&
        !manager.isClosing &&
        task.canPresent;
    if (!canPresent()) return;
    _task = task;
    setState(() => isLoading = true);
    try {
      await task.run<void>((_) async {
        // This check is shared; leaving one UI must not cancel other callers.
        final result = await service.checkUpdates();
        if (!mounted || !canPresent()) return;
        if (result.updates.isEmpty &&
            result.failures.isEmpty &&
            result.skipped == 0) {
          context.showMessage(message: 'No updates'.tl);
          return;
        }
        if (await _showResult(task, result, canPresent) != true ||
            !canPresent()) {
          return;
        }
        await _updateAll(task, service, result, canPresent, refresh);
      });
    } on SelectionCancelled {
      // Registration rejected by the original window/application.
    } catch (error, stack) {
      if (error is SourceFailure && error.code == SourceFailureCode.cancelled) {
        return;
      }
      Log.error('Check comic source updates', error, stack);
      if (mounted && canPresent()) {
        context.showMessage(message: sourceFailureMessage(error));
      }
    } finally {
      if (identical(_task, task)) _task = null;
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<bool?> _showResult(
    WindowSelectionTask task,
    SourceUpdateReport result,
    bool Function() canPresent,
  ) => showSourceActionDialog(
    context: context,
    task: task,
    canPresent: canPresent,
    builder: (context, finish) => AlertDialog(
      title: Text('Source update check'.tl),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '@checked checked · @skipped not checked'.tlParams({
                  'checked': result.checked.toString(),
                  'skipped': result.skipped.toString(),
                }),
              ),
              if (result.skipped > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Unlinked sources are not checked. Link a repository from each source’s origin menu.'
                        .tl,
                  ),
                ),
              if (result.updates.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    result.updates.entries
                        .map(
                          (e) => '${result.sources[e.key]!.name}: ${e.value}',
                        )
                        .join('\n'),
                  ),
                ),
              if (result.updates.isEmpty && result.checked > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text('Checked sources are up to date.'.tl),
                ),
              if (result.failures.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '${'Some sources could not be checked.'.tl}\n${result.failures.map((failure) => failure.format(sourceFailureMessage)).join('\n')}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => finish(false), child: Text('Close'.tl)),
        if (result.updates.isNotEmpty)
          FilledButton(onPressed: () => finish(true), child: Text('Update'.tl)),
      ],
    ),
  );

  Future<void> _updateAll(
    WindowSelectionTask task,
    SourceUpdateService service,
    SourceUpdateReport result,
    bool Function() canPresent,
    VoidCallback? refresh,
  ) async {
    CancelToken? token;
    String? key;
    var committing = false;
    void cancelRequest() {
      if (!committing && key != null && token != null) {
        service.cancel(key, request: token);
      }
    }

    final controller = showLoadingDialog(
      context,
      message: 'Updating'.tl,
      withProgress: true,
      onCancel: () {
        cancelRequest();
        task.cancel();
      },
    );
    final release = task.retainPresentation(() {
      cancelRequest();
      controller.close();
    }, isCurrent: () => controller.isCurrent);
    final failures = <String>[];
    var current = 0;
    try {
      for (final entry in result.updates.entries) {
        if (!canPresent()) break;
        key = entry.key;
        token = CancelToken();
        committing = false;
        try {
          await result.update(
            key,
            cancelToken: token,
            onCommit: () => committing = true,
          );
          if (canPresent()) refresh?.call();
        } catch (error, stack) {
          if (error is SourceFailure &&
              error.code == SourceFailureCode.cancelled) {
            break;
          }
          Log.error('Batch comic source update', error, stack);
          failures.add(
            '${result.sources[key]!.name}: ${sourceFailureMessage(error)}',
          );
          // Recovery/cleanup must be resolved before another source mutation.
          if (error is SourceMutationFailure ||
              error is SourceUpdateCloseFailure) {
            break;
          }
        } finally {
          token = null;
        }
        if (canPresent()) {
          controller.setProgress(++current / result.updates.length);
        }
      }
    } finally {
      controller.close();
      release();
    }
    if (mounted && failures.isNotEmpty && canPresent()) {
      context.showMessage(message: failures.join('\n'));
    }
  }

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    icon: isLoading
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.update),
    label: Text('Check updates'.tl),
    onPressed: isLoading || widget.service == null ? null : check,
  );
}
