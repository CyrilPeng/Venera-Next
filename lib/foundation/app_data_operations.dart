import 'dart:async';

/// Serializes application-data archive and database-replacement operations.
/// An action must call internal helpers rather than queue another action it awaits.
class AppDataOperations {
  static final instance = AppDataOperations();

  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }
}
