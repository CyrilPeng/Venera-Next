import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/failure_presentation.dart';
import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/network/request_scope.dart';

void main() {
  group('classifyFailureMessage', () {
    test('detects source script runtime errors', () {
      const message =
          'ReferenceError: res is not defined\n'
          '    at loadInfo (copy_manga.js:714:39)';
      expect(classifyFailureMessage(message), FailurePresentation.sourceScript);
    });

    test('detects receive timeout', () {
      expect(
        classifyFailureMessage(
          'DioException [receive timeout]: The request took longer than '
          '0:00:15.000000 to receive data.',
        ),
        FailurePresentation.networkTimeout,
      );
    });

    test('detects connection and TLS failures', () {
      expect(
        classifyFailureMessage(
          'DioException [unknown]: null\n'
          'Error: [RhttpConnectionException] Connection error. '
          '(tls handshake eof)',
        ),
        FailurePresentation.networkConnection,
      );
    });

    test('detects HTTP status errors', () {
      expect(
        classifyFailureMessage('Invalid Status Code: 500. Server error'),
        FailurePresentation.httpStatus,
      );
    });

    test('detects missing downloaded files', () {
      expect(
        classifyFailureMessage(
          'Local comic files are unavailable. Check the storage location.',
        ),
        FailurePresentation.fileMissing,
      );
    });

    test('detects storage busy and cancellation', () {
      expect(
        classifyFailureMessage('Local comic storage is busy. Try again later.'),
        FailurePresentation.storageBusy,
      );
      expect(
        classifyFailureMessage('Request cancelled'),
        FailurePresentation.cancelled,
      );
    });

    test('keeps readable messages as-is', () {
      expect(
        classifyFailureMessage('Download started'),
        FailurePresentation.unknown,
      );
    });
  });

  group('classifyFailure', () {
    test('uses structured failure kinds', () {
      expect(
        classifyFailure(const RequestCancelled()),
        FailurePresentation.cancelled,
      );
      expect(
        classifyFailure(
          OperationFailure.message('x', kind: FailureKind.unsupported),
        ),
        FailurePresentation.unsupported,
      );
    });

    test('classifies a missing FileSystemException', () {
      expect(
        classifyFailure(const FileSystemException('File not found', '/comic')),
        FailurePresentation.fileMissing,
      );
    });

    test('follows the cause of a wrapper failure', () {
      final error = OperationFailure(
        message: 'Invalid data',
        cause: const FileSystemException('No such file', '/comic'),
      );
      expect(classifyFailure(error), FailurePresentation.fileMissing);
    });
  });

  group('presentation', () {
    test('hides raw JavaScript diagnostics', () {
      const message =
          'ReferenceError: res is not defined\n'
          '    at loadInfo (copy_manga.js:714:39)';
      final presented = presentFailureMessage(message);
      expect(presented, isNotEmpty);
      expect(presented, isNot(contains('ReferenceError')));
      expect(presented, isNot(contains('copy_manga.js')));
    });

    test('preserves the HTTP status code in the readable message', () {
      final presented = presentFailureMessage(
        'Invalid Status Code: 502. Server-side error',
      );
      expect(presented, contains('502'));
    });

    test('rewrites only technical toast messages', () {
      expect(
        presentTechnicalFailureMessage('Download started'),
        'Download started',
      );
      final rewritten = presentTechnicalFailureMessage(
        'DioException [receive timeout]: took longer than 15s',
      );
      expect(rewritten, isNot(contains('DioException')));
    });

    test('falls back to a generic message for unknown diagnostics', () {
      final presented = presentFailureMessage(
        'Error: widget exploded\n#0 main (package:app/main.dart:1:1)',
      );
      expect(presented, isNot(contains('widget exploded')));
      expect(presented, isNot(contains('package:app')));
    });
  });
}
