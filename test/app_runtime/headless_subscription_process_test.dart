import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final scenario in [
    'success',
    'partial',
    'incomplete',
    'unconfigured',
    'missing',
    'read-error',
  ]) {
    test('subscription subprocess: $scenario', () async {
      final result = await Process.run('dart', [
        'test/fixtures/headless_subscription_probe.dart',
        scenario,
      ], runInShell: Platform.isWindows);
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
      expect(messages.where((m) => m['status'] != 'running'), hasLength(1));
      expect(
        messages.last['status'],
        scenario == 'success' ? 'success' : 'error',
      );
      if (scenario == 'success' || scenario == 'partial') {
        expect(messages.last['data'], [
          {'id': 'updated'},
        ]);
      }
      expect(result.stderr, isEmpty);
    });
  }
}
