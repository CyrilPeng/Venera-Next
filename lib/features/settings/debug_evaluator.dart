import 'dart:async';
import 'dart:convert';

import 'package:venera_next/foundation/operation_failure.dart';

class DebugEvaluationFailure extends OperationFailure {
  DebugEvaluationFailure({
    required super.message,
    required super.cause,
    required super.stackTrace,
    super.kind,
    Iterable<({Object error, StackTrace stack})> cleanupFailures = const [],
  }) : cleanupFailures = List.unmodifiable(cleanupFailures);

  final List<({Object error, StackTrace stack})> cleanupFailures;
}

/// The display deadline does not cancel arbitrary JavaScript. [completion]
/// joins execution, synchronous release and injected descendant cleanup, even
/// after [result] is displayed or times out. It does not join work that the
/// script starts without returning it in the result graph.
class DebugEvaluation {
  DebugEvaluation._(Future<String> display, this.completion, Duration timeout)
    : result = display.timeout(timeout) {
    // Callers may only await the display result. Keep late cleanup failures
    // observed while preserving them for callers that join completion.
    unawaited(completion.then<void>((_) {}, onError: (Object _) {}));
  }

  final Future<String> result;
  final Future<String> completion;
}

/// Runs one submitted debug script without retries or a global runtime lookup.
/// The release callback receives one graph containing the returned value and
/// original failure, so native adapters can release aliases exactly once.
class DebugEvaluator {
  const DebugEvaluator({
    required this.evaluate,
    required this.release,
    this.drain,
    this.timeout = const Duration(seconds: 30),
  });

  final FutureOr<Object?> Function(String code) evaluate;
  final void Function(Object? graph) release;

  /// Called after synchronous release (including failure), before display is
  /// published. It must skip already released root references and join newly
  /// arriving descendants without blocking the display result.
  final Future<void> Function(Object? graph)? drain;
  final Duration timeout;

  DebugEvaluation start(String code) {
    final display = Completer<String>();
    final completion = _execute(code, display);
    return DebugEvaluation._(display.future, completion, timeout);
  }

  Future<String> _execute(String code, Completer<String> display) async {
    Object? value;
    String? output;
    DebugEvaluationFailure? failure;
    try {
      final evaluated = evaluate(code);
      value = evaluated is Future<Object?> ? await evaluated : evaluated;
      try {
        output = value is Map || value is List
            ? const JsonEncoder.withIndent('  ').convert(value)
            : value.toString();
      } catch (_) {
        output = value.toString();
      }
    } catch (error, stack) {
      failure = DebugEvaluationFailure(
        message: _describe(error),
        cause: error,
        stackTrace: stack,
        kind: error is FailureDetails ? error.kind : FailureKind.failed,
      );
    }
    final graph = [value, failure?.cause];
    try {
      release(graph);
    } catch (error, stack) {
      failure = _withCleanup(failure, error, stack);
    }
    Future<void>? descendants;
    try {
      descendants = drain?.call(graph);
    } catch (error, stack) {
      failure = _withCleanup(failure, error, stack);
    }
    if (failure == null) {
      display.complete(output!);
    } else {
      display.completeError(failure, failure.stackTrace!);
    }
    try {
      await descendants;
    } catch (error, stack) {
      failure = _withCleanup(failure, error, stack);
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure, failure.stackTrace!);
    }
    return output!;
  }

  static DebugEvaluationFailure _withCleanup(
    DebugEvaluationFailure? failure,
    Object error,
    StackTrace stack,
  ) => DebugEvaluationFailure(
    message: failure == null
        ? 'JavaScript result cleanup failed: ${_describe(error)}'
        : '${failure.message}; result cleanup failed: ${_describe(error)}',
    cause: failure?.cause ?? error,
    stackTrace: failure?.stackTrace ?? stack,
    kind:
        failure?.kind ??
        (error is FailureDetails ? error.kind : FailureKind.failed),
    cleanupFailures: [
      ...?failure?.cleanupFailures,
      (error: error, stack: stack),
    ],
  );

  // Error rendering must not prevent native result cleanup.
  static String _describe(Object error) {
    try {
      return error.toString();
    } catch (_) {
      return 'JavaScript evaluation failed (${error.runtimeType})';
    }
  }
}
