import 'package:flutter/foundation.dart';

enum ArchiveItemState { pending, working, success, skipped, failed, cancelled }

class ArchiveItem {
  ArchiveItem({required this.title, required this.fileName});

  final String title;
  final String fileName;
  ArchiveItemState _state = ArchiveItemState.pending;
  Object? _error;
  StackTrace? _stack;
  bool _retryAllowed = true;

  ArchiveItemState get state => _state;
  Object? get error => _error;
  StackTrace? get stack => _stack;
  bool get canRetry => _state == ArchiveItemState.failed && _retryAllowed;
}

class ArchiveTransferFailure implements Exception {
  const ArchiveTransferFailure(this.message, {this.retryAllowed = true});

  final String message;
  final bool retryAllowed;

  @override
  String toString() => message;
}

typedef ArchiveItemAction =
    Future<ArchiveItemState> Function(
      int index,
      bool retry,
      bool Function() isCancelled,
    );

/// An in-memory batch; retries keep the original targets and completed rows.
class ComicArchiveBatch extends ChangeNotifier {
  ComicArchiveBatch({
    required Iterable<ArchiveItem> items,
    required ArchiveItemAction action,
    required this.errorText,
    bool Function(Object error)? retryAllowed,
  }) : items = List.unmodifiable(items),
       _action = action,
       _retryAllowed = retryAllowed ?? ((_) => true);

  final List<ArchiveItem> items;
  final ArchiveItemAction _action;
  final bool Function(Object error) _retryAllowed;
  final String Function(Object error) errorText;
  bool _running = false;
  bool _cancelRequested = false;
  bool _disposed = false;

  bool get running => _running;
  bool get cancelRequested => _cancelRequested;
  int count(ArchiveItemState state) =>
      items.where((item) => item.state == state).length;
  bool get hasRetryableFailures => items.any((item) => item.canRetry);
  bool get hasPending => items.any(
    (item) =>
        item.state == ArchiveItemState.pending ||
        item.state == ArchiveItemState.cancelled,
  );

  void cancel() {
    if (!_running || _cancelRequested) return;
    _cancelRequested = true;
    _notify();
  }

  Future<void> run({
    bool retryFailed = false,
    int? onlyIndex,
    void Function(int current, int total, String title)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (_disposed || _running) return;
    final targets = [
      for (var i = 0; i < items.length; i++)
        if ((onlyIndex == null || onlyIndex == i) &&
            (retryFailed
                ? items[i].canRetry
                : items[i].state == ArchiveItemState.pending ||
                      items[i].state == ArchiveItemState.cancelled))
          i,
    ];
    if (targets.isEmpty) return;
    _running = true;
    _cancelRequested = false;
    _notify();
    bool cancelled() => _cancelRequested || isCancelled?.call() == true;
    try {
      for (var position = 0; position < targets.length; position++) {
        if (cancelled()) break;
        final index = targets[position];
        final item = items[index];
        final retry = item.state == ArchiveItemState.failed;
        item._state = ArchiveItemState.working;
        item._error = null;
        item._stack = null;
        _notify();
        try {
          onProgress?.call(position + 1, targets.length, item.title);
          item._state = await _action(index, retry, cancelled);
        } catch (error, stack) {
          item._state = ArchiveItemState.failed;
          item._error = error;
          item._stack = stack;
          item._retryAllowed =
              _retryAllowed(error) &&
              (error is! ArchiveTransferFailure || error.retryAllowed);
        }
        _notify();
      }
    } finally {
      _cancelRequested = cancelled();
      _running = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelRequested = true;
    super.dispose();
  }
}
