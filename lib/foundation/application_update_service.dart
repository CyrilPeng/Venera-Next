import 'dart:async';
import 'dart:convert';

import 'package:venera_next/network/app_dio.dart'
    show Dio, Options, RHttpAdapter;
import 'package:venera_next/network/request_scope.dart';

import 'operation_failure.dart';
import 'release_version.dart';

/// Owns actual HTTP completion independently of the page showing its result.
class ApplicationUpdateService {
  ApplicationUpdateService({
    required Dio Function() createClient,
    required String Function() currentVersion,
  }) : _createClient = createClient,
       _currentVersion = currentVersion;

  final Dio Function() _createClient;
  final String Function() _currentVersion;
  final _pending = <RequestScope, Future<void>>{};
  final _cleanupFailures = <ApplicationUpdateCleanupFailure>[];
  bool _closed = false;
  Future<void>? _closing;

  Future<String?> check({RequestScope? scope}) {
    if (_closed) {
      return Future.error(StateError('Application updates are closed'));
    }
    final owned = RequestScope(parent: scope);
    final completion = Completer<String?>();
    final settled = completion.future
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          owned.dispose();
          _pending.remove(owned);
        });
    // Registration precedes injected callbacks, which may reenter close.
    _pending[owned] = settled;
    _check(owned).then(completion.complete, onError: completion.completeError);
    return completion.future;
  }

  Future<String?> _check(RequestScope scope) async {
    scope.check();
    final version = _currentVersion();
    scope.check();
    final dio = _createClient();
    final adapter = dio.httpClientAdapter;
    Object? cause;
    StackTrace? causeStack;
    String? available;
    try {
      scope.check();
      final includePrerelease = allowsPrereleaseUpdates(version);
      final response = await dio.get<Object?>(
        includePrerelease
            ? 'https://api.github.com/repos/CyrilPeng/venera-next/releases?per_page=20'
            : 'https://api.github.com/repos/CyrilPeng/venera-next/releases/latest',
        cancelToken: scope.cancelToken,
        options: Options(headers: {'Accept': 'application/vnd.github+json'}),
      );
      scope.check();
      if (response.statusCode != 200) {
        throw FormatException(
          'Unexpected release status: ${response.statusCode}',
        );
      }
      final data = response.data is String
          ? jsonDecode(response.data as String)
          : response.data;
      if (data is! Map && data is! List) {
        throw const FormatException('Invalid release response');
      }
      final releases = data is List ? data : [data];
      for (final release in releases) {
        if (release is! Map ||
            release['tag_name'] is! String ||
            (release['tag_name'] as String).trim().isEmpty) {
          throw const FormatException('Invalid release metadata');
        }
      }
      final latest = selectPublishedReleaseVersion(
        data,
        includePrerelease: includePrerelease,
      );
      available = latest != null && shouldNotifyRelease(latest, version)
          ? latest
          : null;
    } catch (error, stack) {
      cause = error;
      causeStack = stack;
      if (scope.isCancelled) throw const RequestCancelled();
      Error.throwWithStackTrace(
        OperationFailure(
          message: 'Failed to check application updates',
          cause: error,
          stackTrace: stack,
        ),
        stack,
      );
    } finally {
      final failures = <({Object error, StackTrace stack})>[];
      Future<void> release(FutureOr<void> Function() action) async {
        try {
          await action();
        } catch (error, stack) {
          failures.add((error: error, stack: stack));
        }
      }

      await release(() => dio.close(force: true));
      if (adapter is RHttpAdapter) await release(adapter.waitForIdle);
      if (failures.isNotEmpty) {
        final failure = ApplicationUpdateCleanupFailure(
          failures,
          cause: cause,
          stackTrace: causeStack,
        );
        _cleanupFailures.add(failure);
        throw failure;
      }
    }
    scope.check();
    return available;
  }

  Future<void> closeAndWait() {
    final closing = _closing;
    if (closing != null) return closing;
    _closed = true;
    final done = Completer<void>();
    _closing = done.future;
    for (final scope in _pending.keys.toList()) {
      scope.cancel();
    }
    _drain().then(done.complete, onError: done.completeError);
    return done.future;
  }

  Future<void> _drain() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.values.toList());
    }
    if (_cleanupFailures.isNotEmpty) {
      throw ApplicationUpdateCleanupFailure([
        for (final failure in _cleanupFailures)
          (error: failure, stack: failure.stackTrace ?? StackTrace.current),
      ]);
    }
  }
}

class ApplicationUpdateCleanupFailure implements FailureDetails {
  ApplicationUpdateCleanupFailure(
    Iterable<({Object error, StackTrace stack})> failures, {
    this.cause,
    this.stackTrace,
  }) : failures = List.unmodifiable(failures);

  final List<({Object error, StackTrace stack})> failures;
  @override
  final Object? cause;
  @override
  final StackTrace? stackTrace;
  @override
  FailureKind get kind => FailureKind.failed;
  @override
  String get message =>
      'Application update cleanup failed: '
      '${failures.map((failure) => failure.error).join('; ')}';
  @override
  String toString() => message;
}
