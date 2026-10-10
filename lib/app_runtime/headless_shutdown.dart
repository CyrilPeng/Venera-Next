import 'dart:async';

/// Commands have finished and headless mode never starts automatic sync.
/// Keep sync bindings alive while source shutdown drains late data changes.
Future<bool> finishHeadlessRuntime({
  required Future<void> Function() prepareCore,
  required Future<void> Function() closeCore,
  required void Function() disposeBindings,
  required Future<void> Function() flushPersistence,
  required void Function(Map<String, dynamic>) emit,
  required void Function(Object, StackTrace) reportError,
}) async {
  var succeeded = true;
  var readyToClose = true;
  Future<void> attempt(
    String message,
    FutureOr<void> Function() run, {
    bool requiredBeforeClose = false,
  }) async {
    try {
      await run();
    } catch (error, stack) {
      succeeded = false;
      if (requiredBeforeClose) readyToClose = false;
      // Logging or a broken output pipe must not interrupt resource cleanup.
      try {
        reportError(error, stack);
      } catch (_) {
        // The failed step has already made the process result unsuccessful.
      }
      try {
        emit({'status': 'error', 'message': '$message: $error'});
      } catch (_) {
        // Keep attempting the remaining cleanup even when stdout is closed.
      }
    }
  }

  await attempt(
    'Failed to prepare core shutdown',
    prepareCore,
    requiredBeforeClose: true,
  );
  await attempt('Failed to release headless bindings', disposeBindings);
  await attempt(
    'Failed to persist sync state',
    flushPersistence,
    requiredBeforeClose: true,
  );
  // Stores and directory ownership outlive all producers and final persistence.
  // On a failed drain keep them alive until the failed CLI process exits.
  if (readyToClose) {
    await attempt('Failed to close core resources', closeCore);
  }
  return succeeded;
}
