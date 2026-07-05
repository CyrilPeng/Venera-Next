import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/image_processing.dart';

void main() {
  test('image script scheduler limits concurrent tasks', () async {
    var active = 0;
    var maxActive = 0;
    final started = <Completer<void>>[];
    final release = <Completer<void>>[];

    final tasks = List.generate(5, (index) {
      final startedCompleter = Completer<void>();
      final releaseCompleter = Completer<void>();
      started.add(startedCompleter);
      release.add(releaseCompleter);

      return debugRunWithImageScriptSlot(() async {
        active++;
        if (active > maxActive) {
          maxActive = active;
        }
        startedCompleter.complete();
        await releaseCompleter.future;
        active--;
        return index;
      });
    });

    await Future.wait(
      started
          .take(4)
          .map(
            (completer) => completer.future.timeout(const Duration(seconds: 1)),
          ),
    );
    await pumpEventQueue();

    expect(started[4].isCompleted, isFalse);
    expect(maxActive, 4);

    release[0].complete();
    await started[4].future.timeout(const Duration(seconds: 1));

    expect(maxActive, 4);

    for (final completer in release.skip(1)) {
      completer.complete();
    }

    expect(await Future.wait(tasks), [0, 1, 2, 3, 4]);
    expect(active, 0);
  });
}
