import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/request_scope.dart';
import 'archive_download.dart';

class ArchiveDownloadSelection {
  const ArchiveDownloadSelection.normal() : url = null;
  const ArchiveDownloadSelection.archive(this.url);
  final String? url;
}

Future<ArchiveDownloadSelection?> showArchiveDownloadDialog({
  required BuildContext context,
  required ArchiveDownloader downloader,
  required String comicId,
}) async {
  final task = WindowSelectionTask(context);
  final navigator = Navigator.of(context, rootNavigator: true);
  final disposed = Completer<ArchiveDownloadSelection?>();
  final removalFailed = Completer<ArchiveDownloadSelection?>();
  removalFailed.future.ignore();
  ResourceDialogRoute<ArchiveDownloadSelection>? route;

  void finish() {
    if (!disposed.isCompleted) disposed.complete(null);
  }

  try {
    return await task.run((operation) async {
      operation.checkActive();
      final dialog = route = ResourceDialogRoute<ArchiveDownloadSelection>(
        context: context,
        themes: InheritedTheme.capture(from: context, to: navigator.context),
        barrierColor: DialogTheme.of(context).barrierColor ?? Colors.black54,
        onDispose: finish,
        builder: (_) =>
            ArchiveDownloadDialog(downloader: downloader, comicId: comicId),
      );
      final release = task.retainPresentation(() {
        try {
          if (navigator.mounted && dialog.isActive) {
            navigator.removeRoute(dialog);
          } else {
            finish();
          }
        } catch (error, stack) {
          if (!removalFailed.isCompleted) {
            removalFailed.completeError(error, stack);
          }
          rethrow;
        }
      }, isCurrent: () => dialog.isCurrent);
      final selected = await Future.any<ArchiveDownloadSelection?>([
        navigator.push(dialog),
        disposed.future,
        removalFailed.future,
      ]);
      release();
      return selected;
    });
  } on SelectionCancelled {
    return null;
  } finally {
    if (route?.navigator == null) finish();
  }
}

class ArchiveDownloadDialog extends StatefulWidget {
  const ArchiveDownloadDialog({
    super.key,
    required this.downloader,
    required this.comicId,
  });
  final ArchiveDownloader downloader;
  final String comicId;
  @override
  State<ArchiveDownloadDialog> createState() => _ArchiveDownloadDialogState();
}

class _ArchiveDownloadDialogState extends State<ArchiveDownloadDialog> {
  List<ArchiveInfo>? archives;
  int selected = -1;
  bool isLoading = false;
  bool isGettingLink = false;
  String? error;
  String? _resolvedLink;
  bool _confirming = false;
  Object _generation = Object();
  WindowSelectionTask? _owner;
  SelectionTaskRegistry? _registry;
  WindowFrameController? _window;
  NavigatorState? _navigator;
  ModalRoute<dynamic>? _route;
  RequestScope? _requestScope;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final registry = context
        .dependOnInheritedWidgetOfExactType<SelectionTasksScope>()
        ?.registry;
    final window = context
        .dependOnInheritedWidgetOfExactType<WindowFrameController>();
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    if (_owner == null ||
        registry != _registry ||
        window?.addExitTask != _window?.addExitTask ||
        navigator != _navigator ||
        route != _route) {
      _registry = registry;
      _window = window;
      _navigator = navigator;
      _route = route;
      _owner = WindowSelectionTask(context);
      _reset();
    }
  }

  @override
  void didUpdateWidget(covariant ArchiveDownloadDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.comicId != widget.comicId ||
        oldWidget.downloader != widget.downloader) {
      _reset();
    }
  }

  void _reset() {
    _requestScope?.cancel();
    _requestScope = null;
    _generation = Object();
    archives = null;
    selected = -1;
    isLoading = false;
    isGettingLink = false;
    error = null;
    _resolvedLink = null;
  }

  bool _canAct(Object generation) =>
      mounted &&
      identical(_generation, generation) &&
      _owner?.canPresent == true;

  Future<Res<T>> _read<T>(Object generation, Future<Res<T>> Function() read) {
    final scope = _requestScope = RequestScope();
    final settled = Completer<void>();
    final window = _window;
    void cancel() => scope.cancel();
    Future<void> close() {
      cancel();
      return settled.future;
    }

    // Register with the original hosts before the source can reenter closure.
    final release = _registry?.retain(cancel: cancel, close: close);
    window?.addCloseStartListener(cancel);
    window?.addExitTask(close);
    window?.trackExitTask(settled.future);
    return Future<Res<T>>.microtask(() async {
      Res<T>? response;
      try {
        if (!_canAct(generation)) cancel();
        return await scope.runToCompletion(() async {
          response = await read();
          return response!;
        });
      } catch (failure, stack) {
        // Cancellation cannot hide a source failure that actually completed.
        if (response?.error == true) return response!;
        return failure is RequestCancelled
            ? Res.failure(
                OperationFailure(
                  message: failure.toString(),
                  kind: FailureKind.cancelled,
                  cause: failure,
                  stackTrace: stack,
                ),
              )
            : Res.fromException(failure, stack);
      } finally {
        scope.dispose();
        if (identical(_requestScope, scope)) _requestScope = null;
        window?.removeCloseStartListener(cancel);
        window?.removeExitTask(close);
        release?.call();
        settled.complete();
      }
    });
  }

  void _recordFailure(Res<Object?> result) {
    if (result.error && result.failure?.kind != FailureKind.cancelled) {
      Log.error(
        'Archive selection',
        result.errorMessage ?? 'Error',
        result.failure?.stackTrace,
      );
    }
  }

  Future<void> load() async {
    final generation = _generation;
    if (isLoading || isGettingLink || !_canAct(generation)) return;
    final downloader = widget.downloader;
    final comicId = widget.comicId;
    setState(() {
      isLoading = true;
      archives = null;
      error = null;
      selected = -1;
      _resolvedLink = null;
    });
    final result = await _read(
      generation,
      () => loadArchiveOptions(downloader, comicId),
    );
    _recordFailure(result);
    if (!mounted || !identical(_generation, generation)) return;
    setState(() {
      isLoading = false;
      archives = result.dataOrNull ?? [];
      error = result.error
          ? result.errorMessage
          : (archives!.isEmpty ? "No archive options available" : null);
    });
  }

  Future<void> confirm() async {
    final generation = _generation;
    if (isGettingLink || _confirming || !_canAct(generation)) return;
    if (selected == -1) {
      _publish(generation, const ArchiveDownloadSelection.normal());
      return;
    }
    if (archives == null || selected < 0 || selected >= archives!.length) {
      return;
    }
    if (_resolvedLink case final url?) {
      _publish(generation, ArchiveDownloadSelection.archive(url));
      return;
    }
    final downloader = widget.downloader;
    final comicId = widget.comicId;
    final archiveId = archives![selected].id;
    setState(() => isGettingLink = true);
    final result = await _read(
      generation,
      () => loadArchiveDownloadLink(downloader, comicId, archiveId),
    );
    _recordFailure(result);
    if (!mounted || !identical(_generation, generation)) return;
    if (!result.error) _resolvedLink = result.data;
    setState(() => isGettingLink = false);
    if (!_canAct(generation)) return;
    if (result.error) {
      context.showMessage(message: (result.errorMessage ?? "Error").tl);
    } else {
      _publish(generation, ArchiveDownloadSelection.archive(result.data));
    }
  }

  void _publish(Object generation, ArchiveDownloadSelection selection) {
    if (_confirming || !_canAct(generation)) return;
    _confirming = true;
    try {
      _navigator!.pop(selection);
      if (_route?.isCurrent == false) _requestScope?.cancel();
    } finally {
      _confirming = false;
    }
  }

  @override
  void dispose() {
    _requestScope?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final generation = _generation;
    void retry() {
      if (_canAct(generation)) unawaited(load());
    }

    return ContentDialog(
      title: "Download".tl,
      content: RadioGroup<int>(
        groupValue: selected,
        onChanged: (value) {
          if (!isGettingLink && _canAct(generation)) {
            setState(() {
              selected = value ?? selected;
              _resolvedLink = null;
            });
          }
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<int>(value: -1, title: Text("Normal".tl)),
            ExpansionTile(
              title: Text("Archive".tl),
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
              ),
              collapsedShape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
              ),
              onExpansionChanged: (expanded) {
                if (expanded && (archives == null || error != null)) retry();
              },
              children: [
                if (isLoading)
                  const Center(child: ListLoadingIndicator())
                else if (archives == null)
                  Button.text(onPressed: retry, child: Text("Retry".tl))
                else if (error != null)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(title: Text(error!.tl)),
                      Button.text(onPressed: retry, child: Text("Retry".tl)),
                    ],
                  )
                else
                  for (var i = 0; i < archives!.length; i++)
                    RadioListTile<int>(
                      value: i,
                      title: Text(archives![i].title),
                      subtitle: Text(archives![i].description),
                    ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        Button.filled(
          isLoading: isGettingLink,
          onPressed: () {
            if (_canAct(generation)) unawaited(confirm());
          },
          child: Text("Confirm".tl),
        ),
      ],
    );
  }
}
