// Controlled protocol probe using the production command and shutdown adapters.
// This does not start Flutter, open native stores, or access user data.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:venera_next/app_runtime/headless_output.dart';
import 'package:venera_next/app_runtime/headless_shutdown.dart';
import 'package:venera_next/app_runtime/headless_sync_command.dart';
import 'package:venera_next/foundation/res.dart';

Future<void> main(List<String> args) async {
  final failures = args[0].split(',').toSet();
  final traceFile = File(args[1]);
  final events = <String>[];
  final reported = <String>[];
  var bindingsActive = true;
  var pendingChanges = 0;
  var persistedChanges = 0;
  var exitCode = await runHeadlessSyncCommand(
    'up',
    isConfigured: true,
    upload: () async => failures.contains('command')
        ? const Res.error('command denied')
        : const Res(true),
    download: () async => const Res(false),
    emit: cliPrint,
  );
  final releaseCore = Completer<void>();
  void failIfRequested(String stage) {
    if (failures.contains(stage)) throw StateError('$stage failed');
  }

  final closing = finishHeadlessRuntime(
    closeCore: () async {
      events.add('close started');
      await releaseCore.future;
      if (bindingsActive) pendingChanges++;
      events.add('late source change');
      events.add('close finished');
      failIfRequested('close');
    },
    disposeBindings: () {
      bindingsActive = false;
      events.add('disposed');
      failIfRequested('dispose');
    },
    flushPersistence: () async {
      events.add('flush started');
      await Future<void>.value();
      failIfRequested('flush');
      persistedChanges = pendingChanges;
      events.add('flush finished');
    },
    reportError: (error, _) {
      reported.add(error.toString());
      failIfRequested('report');
    },
    emit: (message) {
      failIfRequested('emit');
      cliPrint(message);
    },
  );
  await Future<void>.value();
  final bindingsDuringClose = bindingsActive;
  final stagesDuringClose = List<String>.of(events);
  releaseCore.complete();
  if (!await closing) exitCode = 1;

  await traceFile.writeAsString(
    jsonEncode({
      'events': events,
      'reported': reported,
      'bindingsDuringClose': bindingsDuringClose,
      'stagesDuringClose': stagesDuringClose,
      'bindingsAfterClose': bindingsActive,
      'pendingChanges': pendingChanges,
      'persistedChanges': persistedChanges,
    }),
  );
  exit(exitCode);
}
