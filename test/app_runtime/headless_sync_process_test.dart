import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final scenario in [
    ('up', 'success', 0, ['running', 'success']),
    ('down', 'noop', 0, ['running', 'success']),
    ('up', 'failure', 1, ['running', 'error']),
    ('down', 'throw', 1, ['running', 'error']),
    ('up', 'unconfigured', 1, ['error']),
    ('invalid', 'success', 1, ['error']),
  ]) {
    test('sync protocol subprocess: ${scenario.$1}/${scenario.$2}', () async {
      final result = await Process.run('dart', [
        'test/fixtures/headless_sync_probe.dart',
        scenario.$1,
        scenario.$2,
      ], runInShell: Platform.isWindows);
      expect(result.exitCode, scenario.$3, reason: '${result.stderr}');
      final lines = const LineSplitter().convert(result.stdout as String);
      expect(lines, isNotEmpty);
      final messages = <Map<String, dynamic>>[];
      for (final line in lines) {
        expect(line, startsWith('[CLI PRINT] '));
        messages.add(
          jsonDecode(line.substring('[CLI PRINT] '.length))
              as Map<String, dynamic>,
        );
      }
      expect(messages.map((message) => message['status']), scenario.$4);
      expect(
        messages.where((message) => message['status'] != 'running'),
        hasLength(1),
      );
      expect(result.stderr, isEmpty);
    });
  }
}
