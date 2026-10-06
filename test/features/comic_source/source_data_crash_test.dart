import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/features/comic_source/source_data_storage.dart';
import 'package:venera_next/features/comic_source/source_mutation_failure.dart';

import '../../support/dart_vm.dart';

void main() {
  for (final phase in ['recorded', 'partial', 'prepared', 'replaced']) {
    test(
      'source data remains complete after process termination at $phase',
      () async {
        final root = Directory.systemTemp.createTempSync('source-data-crash-');
        Process? child;
        Future<String>? errors;
        Future<String>? output;
        var exited = false;
        try {
          final target = File('${root.path}/comic_source/test.data');
          await const SourceDataStorage().write(
            root.path,
            'test',
            '{"token":"old"}',
          );
          child = await Process.start(dartExecutable(), [
            '--packages=${p.absolute('.dart_tool/package_config.json')}',
            'test/fixtures/source_data_crash_probe.dart',
            root.path,
            phase,
          ]);
          errors = child.stderr.transform(utf8.decoder).join();
          output = child.stdout.transform(utf8.decoder).join();
          final exitCode = child.exitCode.then((value) {
            exited = true;
            return value;
          });
          final ready = File('${root.path}/ready.json');
          final deadline = DateTime.now().add(const Duration(seconds: 30));
          while (!ready.existsSync() &&
              !exited &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          if (!ready.existsSync()) {
            if (!exited) child.kill(ProcessSignal.sigkill);
            await exitCode.timeout(const Duration(seconds: 10));
            fail('Probe did not reach $phase: ${await errors}');
          }
          expect(jsonDecode(ready.readAsStringSync()), {
            'pid': child.pid,
            'phase': phase,
          });
          // The holder is a separate live process, not a mock or stale marker.
          await expectLater(
            const SourceDataStorage().recover(root.path),
            throwsA(isA<SourceMutationFailure>()),
          );
          expect(child.kill(ProcessSignal.sigkill), isTrue);
          expect(await exitCode.timeout(const Duration(seconds: 10)), isNot(0));
          expect(await errors, isEmpty);
          expect(await output, isEmpty);
          expect(jsonDecode(await target.readAsString()), {
            'token': phase == 'replaced' ? 'new' : 'old',
          });
          final residues = target.parent
              .listSync()
              .whereType<Directory>()
              .toList();
          expect(residues, hasLength(phase == 'recorded' ? 0 : 1));
          if (phase == 'recorded') {
            await const SourceDataStorage().recover(root.path);
            expect(jsonDecode(await target.readAsString()), {'token': 'old'});
            return;
          }
          final residue = residues.single;
          final staged = File('${residue.path}/contents');
          if (phase == 'partial') {
            expect(await staged.readAsString(), '{"token":');
          }
          if (phase == 'prepared') {
            expect(jsonDecode(await staged.readAsString()), {'token': 'new'});
          }
          if (phase == 'replaced') expect(await staged.exists(), isFalse);
          // A new process/storage instance uses another owned temporary directory.
          // Ordinary writes never reclaim another operation's staging.
          await const SourceDataStorage().write(
            root.path,
            'test',
            '{"token":"retry"}',
          );
          expect(jsonDecode(await target.readAsString()), {'token': 'retry'});
          expect(residue.existsSync(), isTrue);
          expect(target.parent.listSync().whereType<Directory>(), hasLength(1));
          await child.stdin.close();
          await ready.delete();
          // Interrupt the recovery process too, after its file cleanup but
          // before removing the directory/acknowledging the durable intent.
          child = await Process.start(dartExecutable(), [
            '--packages=${p.absolute('.dart_tool/package_config.json')}',
            'test/fixtures/source_data_crash_probe.dart',
            root.path,
            'recover-cleanup',
          ]);
          errors = child.stderr.transform(utf8.decoder).join();
          output = child.stdout.transform(utf8.decoder).join();
          exited = false;
          final recoveryExit = child.exitCode.then((code) {
            exited = true;
            return code;
          });
          final recoveryDeadline = DateTime.now().add(
            const Duration(seconds: 30),
          );
          while (!ready.existsSync() &&
              !exited &&
              DateTime.now().isBefore(recoveryDeadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          if (!ready.existsSync()) {
            if (!exited) child.kill(ProcessSignal.sigkill);
            await recoveryExit;
            fail('Recovery probe failed: ${await errors}');
          }
          expect(child.kill(ProcessSignal.sigkill), isTrue);
          expect(
            await recoveryExit.timeout(const Duration(seconds: 10)),
            isNot(0),
          );
          expect(await errors, isEmpty);
          expect(await output, isEmpty);
          expect(staged.existsSync(), isFalse);
          await const SourceDataStorage().recover(root.path);
          expect(residue.existsSync(), isFalse);
          expect(jsonDecode(await target.readAsString()), {'token': 'retry'});
        } finally {
          if (child != null) {
            if (!exited) child.kill(ProcessSignal.sigkill);
            await child.exitCode.timeout(const Duration(seconds: 10));
            await child.stdin.close();
            await errors;
            await output;
          }
          await root.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}
