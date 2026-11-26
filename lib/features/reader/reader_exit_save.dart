import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/translations.dart';

import 'reader_session.dart';

class ReaderExitSave {
  ReaderExitSave({
    required this.title,
    required OverlayState overlay,
    required NavigatorState navigator,
    required this.window,
    required this.registry,
    required ReaderSession session,
  }) : _presentation = _ReaderSaveOverlay.of(overlay, navigator),
       _session = session;

  final String title;
  final WindowFrameController? window;
  final SelectionTaskRegistry? registry;
  final _ReaderSaveOverlay _presentation;
  final ReaderSession _session;
  late Future<void> _pending;
  void Function()? _release;
  Timer? _timer;
  Object? _error;
  bool _alertDismissed = false;

  void start(Future<void> Function() save) {
    _run(() {
      _release = registry?.retain(cancel: () {}, close: _waitForSave);
      window?.addExitTask(_waitForSave);
      return save();
    });
  }

  Future<void> _waitForSave() {
    if (_alertDismissed && _error != null) {
      if (!_canRetry) {
        _session.releaseStorage();
        _finish();
        return Future.value();
      }
      _retry();
    }
    return _pending;
  }

  bool get _canRetry => _error != null && _session.canRetryAfterExit(_error!);

  void _retry() {
    _alertDismissed = false;
    _error = null;
    _presentation.hide(this);
    _run(_session.retryAfterExit);
  }

  void _run(Future<void> Function() save) {
    final completion = Completer<void>();
    _pending = completion.future;
    _timer = Timer(
      const Duration(milliseconds: 350),
      () => _presentation.show(this),
    );
    unawaited(
      _pending.then<void>(
        (_) => _finish(),
        onError: (Object error, StackTrace stack) {
          _timer?.cancel();
          _error = error;
          Log.error('Reader', 'Failed to save after leaving: $error', stack);
          _presentation.show(this);
        },
      ),
    );
    unawaited(
      Future<void>.sync(
        save,
      ).then(completion.complete, onError: completion.completeError),
    );
  }

  void _dismissAlert() {
    _alertDismissed = true;
    _presentation.hide(this);
  }

  void _finish() {
    _timer?.cancel();
    _presentation.hide(this);
    window?.removeExitTask(_waitForSave);
    _release?.call();
    _release = null;
  }

  String _describe(Object error) {
    if (error is FailureDetails) {
      if (error.cause != null) return '${error.message}\n${error.cause}';
    }
    return error.toString();
  }

  String get _details {
    final error = _error!;
    if (error is ReaderSessionFailure) {
      return error.failures
          .map((failure) => _describe(failure.error))
          .join('\n\n');
    }
    return _describe(error);
  }
}

class _ReaderSaveOverlay {
  _ReaderSaveOverlay(this.overlay, this.navigator);

  static final _owners = Expando<_ReaderSaveOverlay>();

  static _ReaderSaveOverlay of(
    OverlayState overlay,
    NavigatorState navigator,
  ) => _owners[overlay] ??= _ReaderSaveOverlay(overlay, navigator);

  final OverlayState overlay;
  final NavigatorState navigator;
  final _visible = <ReaderExitSave>{};
  OverlayEntry? _entry;
  bool _dialogOpen = false;

  void show(ReaderExitSave save) {
    if (!overlay.mounted) return;
    _visible.add(save);
    if (_entry == null) {
      final entry = OverlayEntry(builder: _build);
      _entry = entry;
      overlay.insert(entry);
    } else {
      _entry?.markNeedsBuild();
    }
  }

  void hide(ReaderExitSave save) {
    if (!_visible.remove(save)) return;
    if (_visible.isEmpty) {
      final entry = _entry;
      _entry = null;
      if (overlay.mounted) {
        entry?.remove();
        entry?.dispose();
      }
    } else if (overlay.mounted) {
      _entry?.markNeedsBuild();
    }
  }

  Widget _build(BuildContext context) {
    if (_visible.isEmpty || _dialogOpen) return const SizedBox.shrink();
    final hasError = _visible.any((save) => save._error != null);
    final colors = Theme.of(context).colorScheme;
    return PositionedDirectional(
      bottom: 16 + MediaQuery.paddingOf(context).bottom,
      end: 16 + MediaQuery.paddingOf(context).right,
      child: Material(
        shape: const CircleBorder(),
        elevation: 3,
        color: hasError ? colors.errorContainer : colors.surfaceContainerHigh,
        child: hasError
            ? IconButton(
                color: colors.onErrorContainer,
                icon: const Icon(Icons.error_outline),
                tooltip: 'Reading progress save failed'.tl,
                onPressed: () {
                  if (NavigationAdmission.allows(context)) {
                    unawaited(_showFailures());
                  }
                },
              )
            : Padding(
                padding: const EdgeInsets.all(10),
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    semanticsLabel: 'Saving reading progress'.tl,
                    value: MediaQuery.disableAnimationsOf(context) ? 0.5 : null,
                  ),
                ),
              ),
      ),
    );
  }

  Future<void> _showFailures() async {
    if (_dialogOpen || !navigator.mounted) return;
    final failures = [
      for (final save in _visible)
        if (save._error != null) (save: save, details: save._details),
    ];
    if (failures.isEmpty) return;
    _dialogOpen = true;
    _entry?.markNeedsBuild();
    try {
      await showDialog<void>(
        context: navigator.context,
        builder: (context) => AlertDialog(
          title: Text('Reading progress save failed'.tl),
          scrollable: true,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (:save, :details) in failures) ...[
                Text(
                  save.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                SelectableText(details),
                Wrap(
                  children: [
                    if (save._canRetry)
                      TextButton(
                        onPressed: () {
                          if (!NavigationAdmission.allows(context)) return;
                          Navigator.pop(context);
                          if (save._canRetry) save._retry();
                        },
                        child: Text('Retry'.tl),
                      ),
                    TextButton(
                      onPressed: () {
                        if (!NavigationAdmission.allows(context)) return;
                        Navigator.pop(context);
                        if (save._error != null) save._dismissAlert();
                      },
                      child: Text('Dismiss this alert'.tl),
                    ),
                  ],
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Close'.tl),
            ),
          ],
        ),
      );
    } finally {
      _dialogOpen = false;
      if (overlay.mounted) _entry?.markNeedsBuild();
    }
  }
}
