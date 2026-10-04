import 'dart:async';

/// Commands have finished and headless mode never starts automatic sync.
/// Keep sync bindings alive while source shutdown drains late data changes.
Future<bool> finishHeadlessRuntime({
  required Future<void> Function() closeCore,
  required void Function() disposeBindings,
  required Future<void> Function() flushPersistence,
  required void Function(Map<String, dynamic>) emit,
  required void Function(Object, StackTrace) reportError,
}) async {
  var succeeded = true;
  for (final step in <({String message, FutureOr<void> Function() run})>[
    (message: 'Failed to close core resources', run: closeCore),
    (message: 'Failed to release headless bindings', run: disposeBindings),
    (message: 'Failed to persist sync state', run: flushPersistence),
  ]) {
    try {
      await step.run();
    } catch (error, stack) {
      succeeded = false;
      // Logging or a broken output pipe must not interrupt resource cleanup.
      try {
        reportError(error, stack);
      } catch (_) {
        // The failed step has already made the process result unsuccessful.
      }
      try {
        emit({'status': 'error', 'message': '${step.message}: $error'});
      } catch (_) {
        // Keep attempting the remaining cleanup even when stdout is closed.
      }
    }
  }
  return succeeded;
}
