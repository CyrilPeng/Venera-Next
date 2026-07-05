import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';

void main() {
  test('retry delay completes when cancel signal fires', () async {
    final cancel = Completer<void>();
    var completed = false;

    final wait =
        BaseImageProvider.debugWaitForRetryDelay(
          const Duration(seconds: 30),
          cancel.future,
        ).then((_) {
          completed = true;
        });

    await pumpEventQueue();
    expect(completed, isFalse);

    cancel.complete();
    await wait.timeout(const Duration(seconds: 1));

    expect(completed, isTrue);
  });

  test('retry delay still completes normally without cancel', () async {
    await BaseImageProvider.debugWaitForRetryDelay(
      Duration.zero,
      Completer<void>().future,
    ).timeout(const Duration(seconds: 1));
  });
}
