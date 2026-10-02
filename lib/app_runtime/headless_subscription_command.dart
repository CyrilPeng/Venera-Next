typedef HeadlessComicSelector = ({String id, String sourceKey});

/// CLI data only; the host maps persisted comics and service progress here.
class HeadlessSubscriptionProgress {
  const HeadlessSubscriptionProgress({
    required this.total,
    required this.current,
    required this.updated,
    required this.errors,
    this.comic,
    this.errorMessage,
  });

  final int total;
  final int current;
  final int updated;
  final int errors;
  final Map<String, dynamic>? comic;
  final String? errorMessage;
}

Future<int> runHeadlessSubscriptionCommand({
  required String? folder,
  HeadlessComicSelector? selected,
  required Future<HeadlessSubscriptionProgress?> Function(
    String folder,
    HeadlessComicSelector selected,
  )
  updateSelected,
  required Stream<HeadlessSubscriptionProgress> Function(String folder)
  updateAll,
  required Future<Object?> Function(String folder) readUpdatedComics,
  required void Function(Map<String, dynamic>) emit,
  required void Function(Object error, StackTrace stack) reportError,
}) async {
  emit({'status': 'running', 'message': 'Updating subscribed comics...'});
  if (folder == null) {
    emit({
      'status': 'error',
      'message': 'Follow updates folder is not configured.',
    });
    return 1;
  }
  try {
    var total = 0;
    var current = 0;
    var updated = 0;
    var errors = 0;
    var hadError = false;
    var sawProgress = false;
    void progress(HeadlessSubscriptionProgress value) {
      sawProgress = true;
      total = value.total;
      current = value.current;
      updated = value.updated;
      errors = value.errors;
      hadError |= errors > 0 || value.errorMessage != null;
      emit({
        'status': 'running',
        'message': value.errorMessage == null ? 'Progress' : 'ProgressError',
        'data': {
          'current': current,
          'total': total,
          'comic': ?value.comic,
          'error': ?value.errorMessage,
        },
      });
    }

    if (selected != null) {
      final result = await updateSelected(folder, selected);
      if (result == null) {
        emit({'status': 'error', 'message': 'Subscribed comic not found.'});
        return 1;
      }
      progress(result);
    } else {
      await for (final value in updateAll(folder)) {
        progress(value);
      }
    }
    // A cancelled folder stream may close normally before all items finish.
    if (!sawProgress || current < total) {
      emit({
        'status': 'error',
        'message': 'Subscription update did not complete.',
        'data': {
          'current': current,
          'total': total,
          'updated': updated,
          'errors': errors,
        },
      });
      return 1;
    }
    emit({
      'status': 'running',
      'message': 'Update check complete.',
      'data': {'total': total, 'updated': updated, 'errors': errors},
    });
    final comics = await readUpdatedComics(folder);
    emit({
      'status': hadError ? 'error' : 'success',
      'message': 'Updated comics list.',
      'data': comics,
    });
    return hadError ? 1 : 0;
  } catch (error, stack) {
    reportError(error, stack);
    emit({'status': 'error', 'message': 'Command failed: $error'});
    return 1;
  }
}
