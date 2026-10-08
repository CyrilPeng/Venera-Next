import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/operation_failure.dart';

import 'debug_evaluator.dart';

/// Capture the actual runtime at submission. Closing or replacing that runtime
/// cannot transfer pending scripts or native references to its successor.
DebugEvaluator createDebugEvaluator(JsEngine engine) => DebugEvaluator(
  evaluate: (code) async {
    try {
      return await engine.runOwnedCode(code, '<debug>');
    } on JsDisposedError catch (error, stack) {
      Error.throwWithStackTrace(
        OperationFailure(
          message: error.toString(),
          kind: FailureKind.cancelled,
          cause: error,
          stackTrace: stack,
        ),
        stack,
      );
    }
  },
  release: discardJsResult,
  drain: _drainDebugResults,
);

Future<void> _drainDebugResults(Object? graph) async {
  try {
    await drainJsResultDescendants(graph);
  } on JsResourceReleaseFailure catch (error, stack) {
    if (error.failures.every(
      (failure) =>
          failure.resource == 'nested Promise' &&
          failure.error is JsDisposedError,
    )) {
      Error.throwWithStackTrace(
        OperationFailure(
          message: error.toString(),
          kind: FailureKind.cancelled,
          cause: error,
          stackTrace: stack,
        ),
        stack,
      );
    }
    rethrow;
  }
}
