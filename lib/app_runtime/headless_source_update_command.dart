class HeadlessSourceUpdate {
  const HeadlessSourceUpdate({
    required this.key,
    required this.name,
    required this.version,
    required this.url,
    required this.update,
  });
  final String key;
  final String name;
  final String version;
  final String url;
  final Future<void> Function() update;
}

class HeadlessSourceUpdateCheck {
  HeadlessSourceUpdateCheck({
    required List<HeadlessSourceUpdate> updates,
    List<String> failures = const [],
  }) : updates = List.unmodifiable(updates),
       failures = List.unmodifiable(failures);
  final List<HeadlessSourceUpdate> updates;
  final List<String> failures;
}

Future<int> runHeadlessSourceUpdateCommand({
  required Future<HeadlessSourceUpdateCheck> Function() checkUpdates,
  required void Function(Map<String, dynamic>) emit,
}) async {
  emit({
    'status': 'running',
    'message': 'Checking for comic source script updates...',
  });
  HeadlessSourceUpdateCheck check;
  try {
    check = await checkUpdates();
  } catch (error) {
    emit({
      'status': 'error',
      'message': 'Failed to check comic source script updates: $error',
    });
    return 1;
  }
  final total = check.updates.length;
  if (total == 0) {
    emit(
      check.failures.isEmpty
          ? {'status': 'success', 'message': 'No updates found.'}
          : {
              'status': 'error',
              'message': 'Failed to check comic source script updates.',
              'data': {'checkErrors': check.failures},
            },
    );
    return check.failures.isEmpty ? 0 : 1;
  }
  var current = 0;
  var updated = 0;
  var errors = 0;
  emit({
    'status': 'running',
    'message': 'Updating all comic source scripts...',
    'data': {'total': total, 'current': 0, 'updated': 0, 'errors': 0},
  });
  for (final source in check.updates) {
    current++;
    final data = <String, dynamic>{
      'current': current,
      'total': total,
      'source': {
        'key': source.key,
        'name': source.name,
        'version': source.version,
        'url': source.url,
      },
    };
    String? error;
    try {
      await source.update();
      updated++;
    } catch (failure) {
      errors++;
      error = failure.toString();
    }
    emit({
      'status': 'running',
      'message': error == null ? 'Progress' : 'ProgressError',
      'data': {...data, 'error': ?error},
    });
  }
  final failed = errors > 0 || check.failures.isNotEmpty;
  emit({
    'status': failed ? 'error' : 'success',
    'message': failed ? 'Some script updates failed.' : 'All scripts updated.',
    'data': {
      'total': total,
      'updated': updated,
      'errors': errors,
      if (check.failures.isNotEmpty) 'checkErrors': check.failures,
    },
  });
  return failed ? 1 : 0;
}
