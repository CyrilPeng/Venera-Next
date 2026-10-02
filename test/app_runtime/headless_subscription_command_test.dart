import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/headless_subscription_command.dart';

const comic = {'id': 'id', 'type': 'source', 'name': '漫画'};
const selected = (id: 'id', sourceKey: 'source');
HeadlessSubscriptionProgress progress({
  int current = 1,
  int total = 1,
  int errors = 0,
  String? error,
}) => HeadlessSubscriptionProgress(
  total: total,
  current: current,
  updated: errors == 0 ? current : 0,
  errors: errors,
  comic: comic,
  errorMessage: error,
);

class Harness {
  final messages = <Map<String, dynamic>>[];
  final calls = <String>[];
  final reported = <Object>[];
  Future<HeadlessSubscriptionProgress?> Function() single = () async =>
      progress();
  Stream<HeadlessSubscriptionProgress> Function() batch = () =>
      Stream.value(progress());
  Future<Object?> Function() read = () async => [comic];
  Future<int> run({
    String? folder = 'follow',
    HeadlessComicSelector? selector,
  }) => runHeadlessSubscriptionCommand(
    folder: folder,
    selected: selector,
    updateSelected: (folder, selector) {
      expect(folder, 'follow');
      expect(selector, selected);
      calls.add('single');
      return single();
    },
    updateAll: (folder) {
      expect(folder, 'follow');
      calls.add('batch');
      return batch();
    },
    readUpdatedComics: (folder) {
      expect(folder, 'follow');
      calls.add('read');
      return read();
    },
    emit: messages.add,
    reportError: (error, stack) => reported.add(error),
  );
  void terminal(String status) {
    expect(messages.where((m) => m['status'] != 'running'), hasLength(1));
    expect(messages.last['status'], status);
  }
}

void main() {
  test('missing folder invokes no service', () async {
    final h = Harness();
    expect(await h.run(folder: null), 1);
    expect(h.calls, isEmpty);
    h.terminal('error');
  });
  test('missing selected comic does not read the result list', () async {
    final h = Harness()..single = () async => null;
    expect(await h.run(selector: selected), 1);
    expect(h.calls, ['single']);
    h.terminal('error');
    expect(h.messages.last['message'], 'Subscribed comic not found.');
  });
  for (final selector in [null, selected]) {
    for (final failed in [false, true]) {
      test(
        'single=$selector failure=$failed retains protocol and list',
        () async {
          final result = progress(
            errors: failed ? 1 : 0,
            error: failed ? 'failed' : null,
          );
          final h = Harness();
          h.single = () async => result;
          h.batch = () => Stream.value(result);
          expect(await h.run(selector: selector), failed ? 1 : 0);
          expect(h.calls, [selector == null ? 'batch' : 'single', 'read']);
          expect(h.messages[1], {
            'status': 'running',
            'message': failed ? 'ProgressError' : 'Progress',
            'data': {
              'current': 1,
              'total': 1,
              'comic': comic,
              if (failed) 'error': 'failed',
            },
          });
          expect(h.messages[2]['data'], {
            'total': 1,
            'updated': failed ? 0 : 1,
            'errors': failed ? 1 : 0,
          });
          expect(h.messages.last['data'], [comic]);
          h.terminal(failed ? 'error' : 'success');
        },
      );
    }
  }
  test('empty folder emits zero summary, empty stream is incomplete', () async {
    final h = Harness()
      ..batch = () => Stream.value(progress(current: 0, total: 0));
    expect(await h.run(), 0);
    h.terminal('success');
    final cancelled = Harness()..batch = () => const Stream.empty();
    expect(await cancelled.run(), 1);
    cancelled.terminal('error');
    expect(cancelled.calls, ['batch']);
  });
  test('early stream close does not report success or read the list', () async {
    final h = Harness()
      ..batch = () => Stream.value(progress(current: 1, total: 2));
    expect(await h.run(), 1);
    h.terminal('error');
    expect(h.messages.last['message'], 'Subscription update did not complete.');
    expect(h.calls, ['batch']);
  });
  for (final phase in ['single', 'batch', 'read']) {
    test(
      '$phase exception is reported with original error and one terminal result',
      () async {
        final error = StateError(phase);
        final h = Harness();
        if (phase == 'single') h.single = () async => throw error;
        if (phase == 'batch') h.batch = () => Stream.error(error);
        if (phase == 'read') h.read = () async => throw error;
        expect(await h.run(selector: phase == 'single' ? selected : null), 1);
        expect(h.reported.single, same(error));
        h.terminal('error');
        expect(h.messages.last['message'], contains(phase));
      },
    );
  }
  test(
    'result read waits for all progress and terminal output waits for read',
    () async {
      final stream = StreamController<HeadlessSubscriptionProgress>();
      final readStarted = Completer<void>();
      final result = Completer<Object?>();
      final h = Harness();
      h.batch = () => stream.stream;
      h.read = () {
        readStarted.complete();
        return result.future;
      };
      final run = h.run();
      stream.add(progress(current: 0, total: 1));
      await Future<void>.delayed(Duration.zero);
      expect(h.calls, ['batch']);
      stream.add(progress());
      await stream.close();
      await readStarted.future;
      expect(h.messages.where((m) => m['status'] != 'running'), isEmpty);
      result.complete([comic]);
      expect(await run, 0);
      h.terminal('success');
    },
  );
}
