import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final failures in [
    <String>{},
    {'close'},
    {'dispose'},
    {'flush'},
    {'close', 'dispose', 'flush'},
    {'command'},
    {'command', 'close', 'flush'},
    {'close', 'dispose', 'flush', 'report'},
    {'close', 'dispose', 'flush', 'emit'},
    {'close', 'dispose', 'flush', 'report', 'emit'},
  ]) {
    test('shutdown protocol subprocess: $failures', () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera-headless-shutdown-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final traceFile = File('${directory.path}/trace.json');
      final result = await Process.run('dart', [
        'test/fixtures/headless_shutdown_probe.dart',
        failures.isEmpty ? 'none' : failures.join(','),
        traceFile.path,
      ], runInShell: Platform.isWindows);

      expect(
        result.exitCode,
        failures.isEmpty ? 0 : 1,
        reason: '${result.stderr}',
      );
      expect(result.stderr, isEmpty);
      final messages = const LineSplitter()
          .convert(result.stdout as String)
          .map((line) {
            expect(line, startsWith('[CLI PRINT] '));
            return jsonDecode(line.substring('[CLI PRINT] '.length))
                as Map<String, dynamic>;
          })
          .toList();
      final failedStages = [
        'close',
        'dispose',
        'flush',
      ].where(failures.contains).toList();
      expect(messages.map((message) => message['status']), [
        'running',
        failures.contains('command') ? 'error' : 'success',
        if (!failures.contains('emit'))
          for (final _ in failedStages) 'error',
      ]);
      expect(
        messages[1]['message'],
        failures.contains('command')
            ? contains('command denied')
            : 'Upload complete.',
      );
      if (!failures.contains('emit')) {
        for (var index = 0; index < failedStages.length; index++) {
          expect(
            messages[index + 2]['message'],
            contains('${failedStages[index]} failed'),
          );
        }
      }

      final trace =
          jsonDecode(await traceFile.readAsString()) as Map<String, dynamic>;
      expect(trace['bindingsDuringClose'], isTrue);
      expect(trace['stagesDuringClose'], ['close started']);
      expect(trace['bindingsAfterClose'], isFalse);
      expect(trace['pendingChanges'], 1);
      expect(trace['persistedChanges'], failures.contains('flush') ? 0 : 1);
      expect(trace['events'], [
        'close started',
        'late source change',
        'close finished',
        'disposed',
        'flush started',
        if (!failures.contains('flush')) 'flush finished',
      ]);
      expect(trace['reported'], [
        for (final stage in failedStages) 'Bad state: $stage failed',
      ]);
    });
  }
}
