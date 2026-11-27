import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/sync/data_sync_ownership.dart';

Future<void> main(List<String> args) async {
  final directory = args.first;
  final application = args.length == 2 && args[1] == 'application';
  final ready = ReceivePort();
  final exited = ReceivePort();
  final worker = await Isolate.spawn(_holdOwnership, (
    directory,
    application,
    ready.sendPort,
  ), onExit: exited.sendPort);
  final next = _ownership(directory, application);
  try {
    await ready.first.timeout(const Duration(seconds: 10));
    var rejected = false;
    try {
      next.acquire();
    } on SqliteException {
      rejected = true;
    }
    if (!rejected) throw StateError('A live owner must exclude contenders');
    // Flutter can destroy an engine without terminating the Android process.
    // The isolate cannot run a Dart finally block after immediate termination.
    worker.kill(priority: Isolate.immediate);
    await exited.first.timeout(const Duration(seconds: 10));
    next.acquire();
    stdout.writeln('reacquired');
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exitCode = 1;
  } finally {
    next.release();
    worker.kill(priority: Isolate.immediate);
    ready.close();
    exited.close();
  }
}

SqliteDataSyncOwnership _ownership(String path, bool application) => application
    ? SqliteDataSyncOwnership.applicationData(() => path)
    : SqliteDataSyncOwnership(() => path);

void _holdOwnership((String, bool, SendPort) arguments) {
  final (directory, application, ready) = arguments;
  final owner = _ownership(directory, application)..acquire();
  final commands = ReceivePort();
  commands.listen((_) => owner.release());
  ready.send(null);
}
