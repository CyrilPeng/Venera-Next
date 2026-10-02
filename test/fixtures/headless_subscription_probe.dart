import 'dart:io';
import 'package:venera_next/app_runtime/headless_output.dart';
import 'package:venera_next/app_runtime/headless_subscription_command.dart';

Future<void> main(List<String> args) async {
  final scenario = args.single;
  final failed = scenario == 'partial';
  final progress = HeadlessSubscriptionProgress(
    total: 2,
    current: scenario == 'incomplete' ? 1 : 2,
    updated: failed ? 1 : 2,
    errors: failed ? 1 : 0,
    errorMessage: failed ? 'Source failed' : null,
  );
  exit(
    await runHeadlessSubscriptionCommand(
      folder: scenario == 'unconfigured' ? null : 'folder',
      selected: scenario == 'missing' ? (id: 'id', sourceKey: 'source') : null,
      updateSelected: (folder, selected) async => null,
      updateAll: (folder) => Stream.value(progress),
      readUpdatedComics: (folder) async {
        if (scenario == 'read-error') throw StateError('read failed');
        return [
          {'id': 'updated'},
        ];
      },
      emit: cliPrint,
      reportError: (error, stack) {},
    ),
  );
}
