import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/image_provider/cached_image.dart';

void main() {
  test('cached image provider limits concurrent thumbnail loads', () async {
    var active = 0;
    var maxActive = 0;
    final started = <Completer<void>>[];
    final release = <Completer<void>>[];

    final tasks = List.generate(11, (index) {
      final startedCompleter = Completer<void>();
      final releaseCompleter = Completer<void>();
      started.add(startedCompleter);
      release.add(releaseCompleter);

      return CachedImageProvider.debugRunWithThumbnailSlot(() async {
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
          .take(9)
          .map(
            (completer) => completer.future.timeout(const Duration(seconds: 1)),
          ),
    );
    await pumpEventQueue();

    expect(started[9].isCompleted, isFalse);
    expect(maxActive, 9);
    expect(CachedImageProvider.loadingCount, 9);

    release[0].complete();
    await started[9].future.timeout(const Duration(seconds: 1));

    expect(maxActive, 9);

    for (final completer in release.skip(1)) {
      completer.complete();
    }

    expect(await Future.wait(tasks), List.generate(11, (index) => index));
    expect(active, 0);
    expect(CachedImageProvider.loadingCount, 0);
  });

  test('queued thumbnail load checks stop before running task', () async {
    final release = List.generate(9, (_) => Completer<void>());
    final holders = release.map((completer) {
      return CachedImageProvider.debugRunWithThumbnailSlot(() async {
        await completer.future;
      });
    }).toList();
    await pumpEventQueue();

    var ran = false;
    final queued = CachedImageProvider.debugRunWithThumbnailSlot(
      () async {
        ran = true;
      },
      checkStop: () {
        throw StateError('stopped');
      },
    );
    await pumpEventQueue();

    expect(ran, isFalse);

    release.first.complete();
    await expectLater(queued, throwsA(isA<StateError>()));
    expect(ran, isFalse);

    for (final completer in release.skip(1)) {
      completer.complete();
    }
    await Future.wait(holders);

    expect(CachedImageProvider.loadingCount, 0);
  });

  test('cached image provider uses fallback after primary load fails', () async {
    final chunkEvents = StreamController<ImageChunkEvent>.broadcast();
    addTearDown(chunkEvents.close);

    final provider = CachedImageProvider(
      'file://missing-cover.jpg',
      fallback: () => Uint8List.fromList([1, 2, 3]),
    );

    final data = await provider.load(chunkEvents, () {});

    expect(data, [1, 2, 3]);
  });
}
