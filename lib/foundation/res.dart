import 'operation_failure.dart';

class Res<T> {
  /// error info
  final String? errorMessage;

  /// Available for migrated callers; legacy string errors remain supported.
  final FailureDetails? failure;

  /// data
  final T? _data;

  /// is there an error
  bool get error => errorMessage != null;

  /// whether succeed
  bool get success => !error;

  /// data
  T get data => _data ?? (throw Exception(errorMessage));

  /// get data, or null if there is an error
  T? get dataOrNull => _data;

  final dynamic subData;

  @override
  String toString() => _data.toString();

  Res.fromErrorRes(Res another, {this.subData})
    : _data = null,
      failure = another.failure,
      errorMessage = another.errorMessage;

  /// network result
  const Res(this._data, {this.errorMessage, this.subData}) : failure = null;

  const Res.error(String err)
    : _data = null,
      failure = null,
      subData = null,
      errorMessage = err;

  Res.failure(FailureDetails details)
    : failure = details,
      _data = null,
      subData = null,
      errorMessage = details.message;

  factory Res.fromException(Object error, StackTrace stack) => Res.failure(
    error is FailureDetails
        ? error
        : OperationFailure(
            message: error.toString(),
            kind: error is UnsupportedError
                ? FailureKind.unsupported
                : FailureKind.failed,
            cause: error,
            stackTrace: stack,
          ),
  );
}
