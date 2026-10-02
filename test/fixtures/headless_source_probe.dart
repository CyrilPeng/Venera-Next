import 'dart:io';
import 'package:venera_next/app_runtime/headless_arguments.dart';
import 'package:venera_next/app_runtime/headless_output.dart';
import 'package:venera_next/app_runtime/headless_source_update_command.dart';

Future<void> main(List<String> args) async {
  final parsed = parseHeadlessArguments(args);
  if (parsed.error) {
    cliPrint({'status': 'error', 'message': parsed.errorMessage});
    exit(1);
  }
  final scenario = Platform.environment['VENERA_PROBE_SCENARIO'];
  exit(
    await runHeadlessSourceUpdateCommand(
      checkUpdates: () async {
        if (scenario == 'throw') throw StateError('check failed');
        return HeadlessSourceUpdateCheck(
          failures: scenario == 'check-failure' ? ['check failed'] : [],
          updates: scenario == 'partial'
              ? [
                  for (final id in [0, 1])
                    HeadlessSourceUpdate(
                      key: '$id',
                      name: '$id',
                      version: '1',
                      url: '',
                      update: () async {
                        if (id == 0) throw StateError('update failed');
                      },
                    ),
                ]
              : [],
        );
      },
      emit: cliPrint,
    ),
  );
}
