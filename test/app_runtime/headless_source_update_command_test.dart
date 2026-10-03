import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/headless_source_update_command.dart';
import 'package:venera_next/features/comic_source/source_failure.dart';

void main() {
  test('cancelled updates never count as successful updates', () async {
    final messages = <Map<String, dynamic>>[];
    final code = await runHeadlessSourceUpdateCommand(
      checkUpdates: () async => HeadlessSourceUpdateCheck(
        updates: [
          HeadlessSourceUpdate(
            key: 'cancelled',
            name: 'Cancelled',
            version: '1',
            url: 'url',
            update: () async =>
                throw const SourceFailure(SourceFailureCode.cancelled),
          ),
          HeadlessSourceUpdate(
            key: 'next',
            name: 'Next',
            version: '1',
            url: 'url',
            update: () async {},
          ),
        ],
      ),
      emit: messages.add,
    );
    expect(code, 1);
    expect(messages.last['data'], {'total': 2, 'updated': 1, 'errors': 1});
    expect(
      messages.singleWhere(
        (message) => message['message'] == 'ProgressError',
      )['data']['error'],
      'Source update cancelled.',
    );
  });

  for (final failures in <List<String>>[
    [],
    ['network unavailable'],
  ]) {
    test('empty update list with check failures $failures', () async {
      final messages = <Map<String, dynamic>>[];
      final code = await runHeadlessSourceUpdateCommand(
        checkUpdates: () async =>
            HeadlessSourceUpdateCheck(updates: [], failures: failures),
        emit: messages.add,
      );
      expect(code, failures.isEmpty ? 0 : 1);
      expect(messages.last['status'], failures.isEmpty ? 'success' : 'error');
      if (failures.isNotEmpty) {
        expect(messages.last['data']['checkErrors'], failures);
      }
      expect(messages.where((m) => m['status'] != 'running'), hasLength(1));
    });
  }
  test('check exception emits a single failure terminal result', () async {
    final messages = <Map<String, dynamic>>[];
    expect(
      await runHeadlessSourceUpdateCommand(
        checkUpdates: () async => throw StateError('check failed'),
        emit: messages.add,
      ),
      1,
    );
    expect(messages.map((m) => m['status']), ['running', 'error']);
    expect(messages.last['message'], contains('check failed'));
  });
  for (final failUpdate in [false, true]) {
    for (final failCheck in [false, true]) {
      test(
        'snapshot and continuation: update=$failUpdate check=$failCheck',
        () async {
          final messages = <Map<String, dynamic>>[];
          final called = <int>[];
          final updates = <HeadlessSourceUpdate>[];
          final failures = failCheck ? ['check failed'] : <String>[];
          for (var index = 0; index < 3; index++) {
            final id = index;
            updates.add(
              HeadlessSourceUpdate(
                key: '$id',
                name: 'source $id',
                version: '1',
                url: 'url',
                update: () async {
                  called.add(id);
                  updates.clear();
                  failures.clear();
                  if (id == 1 && failUpdate) throw StateError('update failed');
                },
              ),
            );
          }
          final snapshot = HeadlessSourceUpdateCheck(
            updates: updates,
            failures: failures,
          );
          final code = await runHeadlessSourceUpdateCommand(
            checkUpdates: () async => snapshot,
            emit: messages.add,
          );
          expect(called, [0, 1, 2]);
          expect(code, failUpdate || failCheck ? 1 : 0);
          expect(messages.last['data'], {
            'total': 3,
            'updated': failUpdate ? 2 : 3,
            'errors': failUpdate ? 1 : 0,
            if (failCheck) 'checkErrors': ['check failed'],
          });
          expect(
            messages.where((m) => m['message'] == 'ProgressError'),
            hasLength(failUpdate ? 1 : 0),
          );
          expect(messages.where((m) => m['status'] != 'running'), hasLength(1));
        },
      );
    }
  }
}
