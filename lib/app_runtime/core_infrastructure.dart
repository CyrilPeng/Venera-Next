import 'dart:async';

import 'package:venera_next/network/cookie_jar.dart';

import 'core_bootstrap.dart';

/// Owns a newly acquired cookie database until all services have initialized.
/// On success the application retains it; this is not a shutdown protocol.
Future<void> initializeCoreInfrastructure({
  required String directory,
  required Iterable<FutureOr<void> Function()> services,
}) async {
  final previous = SingleInstanceCookieJar.instance;
  final cookies = await SingleInstanceCookieJar.createInstance(
    directory: directory,
  );
  try {
    // Materialize before invoking services, then join even synchronous failures.
    final attempts = List<FutureOr<void> Function()>.of(services);
    await Future.wait(
      attempts.map((initialize) => Future<void>.sync(initialize)),
    );
  } catch (error, stack) {
    await rollbackCoreStartup(
      [
        if (!identical(previous, cookies))
          (name: 'cookies', close: cookies.dispose),
      ],
      error,
      stack,
    );
    Error.throwWithStackTrace(error, stack);
  }
}
