import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final scenario in [
    'success',
    'check-failure',
    'throw',
    'partial',
    'invalid',
  ]) {
    test('source command subprocess: $scenario', () async {
      final result = await Process.run(
        'dart',
        [
          'test/fixtures/headless_source_probe.dart',
          '--headless',
          'updatescript',
          if (scenario != 'invalid') 'all',
        ],
        environment: {'VENERA_PROBE_SCENARIO': scenario},
        runInShell: Platform.isWindows,
      );
      expect(
        result.exitCode,
        scenario == 'success' ? 0 : 1,
        reason: '${result.stderr}',
      );
      final messages = const LineSplitter()
          .convert(result.stdout as String)
          .map((line) {
            expect(line, startsWith('[CLI PRINT] '));
            return jsonDecode(line.substring('[CLI PRINT] '.length))
                as Map<String, dynamic>;
          })
          .toList();
      expect(messages, isNotEmpty);
      expect(messages.where((m) => m['status'] != 'running'), hasLength(1));
      expect(
        messages.last['status'],
        scenario == 'success' ? 'success' : 'error',
      );
      if (scenario == 'invalid') expect(messages, hasLength(1));
      if (scenario == 'partial') {
        expect(messages.last['data'], {'total': 2, 'updated': 1, 'errors': 1});
      }
      expect(result.stderr, isEmpty);
    });
  }
}
