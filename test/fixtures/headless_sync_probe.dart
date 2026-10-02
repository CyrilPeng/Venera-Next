// Protocol probe using production adapters and deterministic service ports.
// This does not start the Flutter application or access user data.
import 'dart:io';
import 'package:venera_next/app_runtime/headless_output.dart';
import 'package:venera_next/app_runtime/headless_sync_command.dart';
import 'package:venera_next/foundation/res.dart';

Future<void> main(List<String> args) async {
  Future<Res<bool>> transfer() async => switch (args[1]) {
    'failure' => const Res.error('denied'),
    'throw' => throw StateError('unexpected'),
    'noop' => const Res(false),
    _ => const Res(true),
  };
  final code = await runHeadlessSyncCommand(
    args[0],
    isConfigured: args[1] != 'unconfigured',
    upload: transfer,
    download: transfer,
    emit: cliPrint,
  );
  exit(code);
}
