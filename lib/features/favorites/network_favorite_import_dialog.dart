import 'dart:async';
import 'package:flutter/material.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/request_scope.dart';
import 'favorite_models.dart';
import 'network_favorite_import.dart';

class NetworkFavoriteImportDialog extends StatefulWidget {
  const NetworkFavoriteImportDialog({
    super.key,
    required this.collect,
    required this.commit,
    required this.publish,
    this.isCurrent,
    this.onStarted,
  });
  final Future<List<FavoriteItem>> Function(
    RequestScope,
    void Function(FavoriteImportProgress),
  )
  collect;
  final FutureOr<NetworkFavoriteImportCommit> Function(
    List<FavoriteItem>,
    RequestScope,
  )
  commit;
  final FutureOr<void> Function(NetworkFavoriteImportCommit) publish;
  final bool Function()? isCurrent;
  final ValueChanged<Future<void>>? onStarted;

  @override
  State<NetworkFavoriteImportDialog> createState() =>
      _NetworkFavoriteImportDialogState();
}

class _NetworkFavoriteImportDialogState
    extends State<NetworkFavoriteImportDialog> {
  final scope = RequestScope();
  late final NetworkFavoriteImportDialog _input = widget;
  WindowSelectionTask? _owner;
  bool _started = false;
  bool _running = false;
  bool cancelled = false;
  FavoriteImportProgress progress = (pages: 0, received: 0, collected: 0);
  String? error;
  NetworkFavoriteImportCommit? committed;
  String? publicationError;
  bool publishing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      unawaited(_start(_collectAndCommit));
    }
  }

  @override
  void didUpdateWidget(NetworkFavoriteImportDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.collect != oldWidget.collect ||
        widget.commit != oldWidget.commit ||
        widget.publish != oldWidget.publish ||
        widget.isCurrent != oldWidget.isCurrent) {
      scope.cancel();
    }
  }

  void _checkCurrent() {
    scope.check();
    if (!mounted || _input.isCurrent?.call() == false) {
      throw const RequestCancelled();
    }
  }

  Future<void> _start(Future<void> Function() action) {
    if (_running || !mounted) return Future.value();
    final owner = _owner = WindowSelectionTask(context);
    if (!owner.canPresent) return Future.value();
    _running = true;
    final releaseCancellation = owner.retainPresentation(scope.cancel);
    final work = owner.run<void>((operation) async {
      try {
        operation.checkActive();
        await action();
      } on RequestCancelled {
        throw const SelectionCancelled();
      } on FailureDetails catch (failure) {
        if (failure.kind == FailureKind.cancelled) {
          throw const SelectionCancelled();
        }
        rethrow;
      } finally {
        releaseCancellation();
      }
    }, reportFailureOnClose: true);
    final observed = work
        .then<void>(
          (_) {},
          onError: (Object failure, StackTrace stack) {
            final isCancellation =
                failure is RequestCancelled ||
                failure is SelectionCancelled ||
                failure is FailureDetails &&
                    failure.kind == FailureKind.cancelled;
            if (!isCancellation) Log.error('Favorite import', failure, stack);
            if (mounted) {
              setState(() {
                cancelled = isCancellation;
                if (!isCancellation && committed == null) {
                  error = failure.toString();
                }
              });
            }
          },
        )
        .whenComplete(() {
          _running = false;
          if (!mounted) scope.dispose();
        });
    _input.onStarted?.call(work);
    return observed;
  }

  Future<void> _collectAndCommit() async {
    _checkCurrent();
    final items = await _input.collect(scope, (value) {
      if (mounted && !scope.isCancelled && _input.isCurrent?.call() != false) {
        setState(() => progress = value);
      }
    });
    _checkCurrent();
    final result = await _input.commit(items, scope);
    // A completed SQL commit is retained even if the dialog was removed.
    committed = result;
    if (mounted) setState(() {});
    await _publish(result);
  }

  Future<void> _publish(NetworkFavoriteImportCommit result) async {
    publishing = true;
    if (mounted) setState(() => publicationError = null);
    try {
      await _input.publish(result);
    } catch (failure, stack) {
      if (mounted) setState(() => publicationError = failure.toString());
      Error.throwWithStackTrace(
        PersistenceFailure(
          commitState: PersistenceCommitState.committed,
          cause: failure,
          stackTrace: stack,
        ),
        stack,
      );
    } finally {
      publishing = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    scope.cancel();
    if (!_running) scope.dispose();
    super.dispose();
  }

  void _dismiss() {
    if (_owner?.canPresent != true) return;
    scope.cancel();
    try {
      Navigator.of(context, rootNavigator: true).pop();
    } catch (failure, stack) {
      Log.error('Favorite import dismissal', failure, stack);
      if (mounted) setState(() => error = failure.toString());
    }
  }

  @override
  Widget build(BuildContext context) => NavigationAdmission(
    allowsNavigation: () => _owner?.canPresent == true,
    child: PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) scope.cancel();
      },
      child: ContentDialog(
        title: committed != null
            ? 'Finished'.tl
            : error != null
            ? 'Error'.tl
            : cancelled
            ? 'Cancelled'.tl
            : 'Importing'.tl,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: committed != null
                  ? 1
                  : error != null || cancelled
                  ? 0
                  : null,
            ),
            Text(
              'Imported @a comics, loaded @b pages, received @c comics'
                  .tlParams({
                    'a': committed?.count ?? 0,
                    'b': progress.pages,
                    'c': progress.received,
                  }),
            ),
            if (error != null) Text(error!),
            if (publicationError != null)
              Text('${'Refresh'.tl}: $publicationError'),
          ],
        ),
        actions: [
          if (publicationError != null && committed != null)
            Button.text(
              isLoading: publishing,
              onPressed: () => _start(() => _publish(committed!)),
              child: Text('Refresh'.tl),
            ),
          Button.filled(
            onPressed: _dismiss,
            child: Text(
              committed != null || error != null || cancelled
                  ? 'OK'.tl
                  : 'Cancel'.tl,
            ),
          ),
        ],
      ),
    ),
  );
}
