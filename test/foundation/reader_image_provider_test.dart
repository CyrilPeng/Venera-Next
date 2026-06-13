import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';

void main() {
  test('reader image processing waits for future result', () async {
    final cancelSignal = Completer<void>();
    final bytes = Uint8List.fromList([1, 2, 3]);
    var canceled = false;

    final result = await debugWaitForReaderImageProcessingResult(
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

    final result = debugWaitForReaderImageProcessingResult(
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

    final result = await debugWaitForReaderImageProcessingResult(
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

    final result = debugWaitForReaderImageProcessingResult(
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
