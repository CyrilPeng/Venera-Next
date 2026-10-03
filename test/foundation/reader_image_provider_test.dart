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
      await expectLater(result, throwsStateError);
      image.complete({'unused': callback});
      await pumpEventQueue();
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

    await expectLater(result, throwsA(isA<StateError>()));
    expect(canceled, isTrue);
    expect(checkedStop, isTrue);
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
