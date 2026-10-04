import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/foundation/image_provider/reader_image_processing.dart';

void main() {
  test(
    'cancelled processing frees callbacks in late result exactly once',
    () async {
      final image = Completer<dynamic>();
      final signal = Completer<void>();
      final callback = _ResultCallback();
      final result = waitForReaderImageProcessingResult(
        image.future,
        () {},
        () => throw StateError('stopped'),
        cancelSignal: signal.future,
      );
      signal.complete();
      var finished = false;
      final observed = expectLater(result, throwsStateError).then((_) {
        finished = true;
      });
      await pumpEventQueue();
      expect(finished, isFalse);
      image.complete({'unused': callback});
      await observed;
      expect(callback.destroyed, 1);
    },
  );

  test(
    'stop after result arrival frees result callbacks exactly once',
    () async {
      final callback = _ResultCallback();
      final result = waitForReaderImageProcessingResult(
        Future.value({'unused': callback}),
        () {},
        () => throw StateError('stopped'),
        cancelSignal: Completer<void>().future,
      );
      await expectLater(result, throwsStateError);
      expect(callback.destroyed, 1);
    },
  );
  test('reader image processing waits for future result', () async {
    final cancelSignal = Completer<void>();
    final bytes = Uint8List.fromList([1, 2, 3]);
    var canceled = false;

    final result = await waitForReaderImageProcessingResult(
      Future<Uint8List>.value(bytes),
      () {
        canceled = true;
      },
      () {},
      cancelSignal: cancelSignal.future,
    );

    expect(result, same(bytes));
    expect(canceled, isFalse);
  });

  test('reader image processing cancels through stop signal', () async {
    final image = Completer<Uint8List>();
    final cancelSignal = Completer<void>();
    var canceled = false;
    var checkedStop = false;

    final result = waitForReaderImageProcessingResult(
      image.future,
      () {
        canceled = true;
      },
      () {
        checkedStop = true;
        throw StateError('stopped');
      },
      cancelSignal: cancelSignal.future,
    );

    cancelSignal.complete();
    final observed = expectLater(result, throwsA(isA<StateError>()));
    await pumpEventQueue();
    expect(canceled, isTrue);
    expect(checkedStop, isFalse);
    image.complete(Uint8List(0));
    await observed;
    expect(checkedStop, isTrue);
  });

  test('cancellation drains both image and asynchronous hook', () async {
    final image = Completer<dynamic>();
    final hook = Completer<dynamic>();
    final signal = Completer<void>();
    final imageReference = _ResultCallback();
    final hookReference = _ResultCallback();
    var finished = false;
    final result = waitForReaderImageProcessingResult(
      image.future,
      () => hook.future,
      () => throw StateError('stopped'),
      cancelSignal: signal.future,
    );
    final observed = expectLater(result, throwsStateError).then((_) {
      finished = true;
    });
    signal.complete();
    await pumpEventQueue();
    image.complete({'reference': imageReference});
    await pumpEventQueue();
    expect(finished, isFalse);
    hook.complete({'reference': hookReference});
    await observed;
    expect(imageReference.destroyed, 1);
    expect(hookReference.destroyed, 1);
  });

  test('late error graphs and hook errors preserve all failures', () async {
    final image = Completer<dynamic>();
    final hook = Completer<dynamic>();
    final signal = Completer<void>();
    final reference = _ResultCallback();
    final error = <String, dynamic>{'reference': reference};
    error['self'] = error;
    final result = waitForReaderImageProcessingResult(
      image.future,
      () => hook.future,
      () => throw StateError('stopped'),
      cancelSignal: signal.future,
    );
    final observed = expectLater(
      result,
      throwsA(
        isA<ReaderImageProcessingFailure>().having(
          (failure) => failure.failures.length,
          'failure count',
          3,
        ),
      ),
    );
    signal.complete();
    await pumpEventQueue();
    hook.completeError(StateError('hook failed'));
    await pumpEventQueue();
    image.completeError(error);
    await observed;
    expect(reference.destroyed, 1);
  });

  test('reader image processing keeps null result as empty bytes', () async {
    final cancelSignal = Completer<void>();

    final result = await waitForReaderImageProcessingResult(
      Future<void>.value(),
      () {},
      () {},
      cancelSignal: cancelSignal.future,
    );

    expect(result, isA<Uint8List>());
    expect(result, isEmpty);
  });

  test('reader image processing propagates future errors', () async {
    final cancelSignal = Completer<void>();
    var canceled = false;

    final result = waitForReaderImageProcessingResult(
      Future<Uint8List>.error(StateError('failed')),
      () {
        canceled = true;
      },
      () {},
      cancelSignal: cancelSignal.future,
    );

    await expectLater(result, throwsA(isA<StateError>()));
    expect(canceled, isFalse);
  });
}

class _ResultCallback extends JSInvokable {
  int destroyed = 0;
  @override
  dynamic invoke(List args, [dynamic thisVal]) => null;
  @override
  void destroy() => destroyed++;
}
