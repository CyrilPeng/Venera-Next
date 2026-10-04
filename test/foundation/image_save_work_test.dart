import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/image_save_work.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/network/request_scope.dart';

final _png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);

void main() {
  test('captures save name and exposes the owned request scope', () async {
    final source = Completer<Uint8List>();
    final deliveries = <String>[];
    final work = ImageSaveWork(
      deliver: (bytes, name, _) async {
        expect(bytes, same(_png));
        deliveries.add(name);
        return true;
      },
      onError: (error, stack) => fail('$error'),
    );
    var currentName = '1';
    final result = work.save(
      name: currentName,
      read: (scope) {
        expect(RequestScope.current, same(scope));
        return source.future;
      },
    );
    currentName = '2';
    expect(work.isBusy, isTrue);
    source.complete(_png);
    expect(await result, isTrue);
    expect(deliveries, ['1.png']);
    expect(work.isBusy, isFalse);
    await work.dispose();
  });

  test(
    'preparation cancels admission but waits for the original read',
    () async {
      final source = Completer<Uint8List>();
      var deliveries = 0;
      late RequestScope request;
      final work = ImageSaveWork(
        deliver: (_, _, _) async {
          deliveries++;
          return true;
        },
        onError: (error, stack) => fail('$error'),
      );
      final save = work.save(
        name: 'image',
        read: (scope) {
          request = scope;
          return source.future;
        },
      );
      var prepared = false;
      final preparing = work.prepareForExit().then((release) {
        prepared = true;
        return release;
      });
      expect(request.isCancelled, isTrue);
      await pumpEventQueue();
      expect(prepared, isFalse);
      expect(
        await work.save(name: 'blocked', read: (_) async => _png),
        isFalse,
      );
      source.complete(_png);
      expect(await save, isFalse);
      final release = await preparing;
      expect(deliveries, 0);
      release();
      expect(await work.save(name: 'new', read: (_) async => _png), isTrue);
      expect(deliveries, 1);
      await work.dispose();
    },
  );

  for (final disposeOwner in [false, true]) {
    test(
      'queued save checks cancellation before native dispatch; dispose=$disposeOwner',
      () async {
        final queued = Completer<void>();
        final turn = Completer<void>();
        var nativeCalls = 0;
        final work = ImageSaveWork(
          deliver: (_, _, checkStop) async {
            if (!queued.isCompleted) queued.complete();
            await turn.future;
            checkStop();
            nativeCalls++;
            return true;
          },
          onError: (error, _) => fail('Cancellation reached UI: $error'),
        );
        final saving = work.save(name: 'image', read: (_) async => _png);
        await queued.future;
        var drained = false;
        late void Function() release;
        final Future<void> closing;
        if (disposeOwner) {
          closing = work.dispose().then((_) => drained = true);
        } else {
          closing = work.prepareForExit().then((resume) {
            release = resume;
            drained = true;
          });
        }
        await pumpEventQueue();
        expect(drained, isFalse);
        expect(nativeCalls, 0);
        turn.complete();
        expect(await saving, isFalse);
        await closing;
        expect(nativeCalls, 0);
        if (!disposeOwner) {
          release();
          expect(
            await work.save(name: 'retry', read: (_) async => _png),
            isTrue,
          );
          expect(nativeCalls, 1);
          await work.dispose();
        }
      },
    );
  }

  test('accepted platform delivery settles before disposal', () async {
    final delivered = Completer<void>();
    final platform = Completer<bool>();
    final work = ImageSaveWork(
      deliver: (_, _, checkStop) {
        checkStop();
        delivered.complete();
        return platform.future;
      },
      onError: (error, stack) => fail('$error'),
    );
    final saving = work.save(name: 'image', read: (_) async => _png);
    await delivered.future;
    var closed = false;
    final close = work.dispose();
    expect(work.dispose(), same(close));
    unawaited(close.then((_) => closed = true));
    await pumpEventQueue();
    expect(closed, isFalse);
    expect(await work.save(name: 'late', read: (_) async => _png), isFalse);
    platform.complete(true);
    expect(await saving, isTrue);
    await close;
    expect(closed, isTrue);
  });

  for (final duringDelivery in [false, true]) {
    test(
      'late failure retains original stack; delivery=$duringDelivery',
      () async {
        final read = Completer<Uint8List>();
        final platform = Completer<bool>();
        final delivered = Completer<void>();
        final uiErrors = <Object>[];
        final error = StateError('late failure');
        final stack = StackTrace.fromString('original image save stack');
        final work = ImageSaveWork(
          deliver: (_, _, _) {
            delivered.complete();
            return platform.future;
          },
          onError: (error, _) => uiErrors.add(error),
        );
        final saving = work.save(name: 'image', read: (_) => read.future);
        if (duringDelivery) {
          read.complete(_png);
          await delivered.future;
        }
        final preparing = work.prepareForExit();
        final checked = expectLater(
          preparing,
          throwsA(
            isA<ImageWorkFailure>().having(
              (failure) => failure.failures,
              'original failure',
              [(error: error, stack: stack)],
            ),
          ),
        );
        if (duringDelivery) {
          platform.completeError(error, stack);
        } else {
          read.completeError(error, stack);
        }
        expect(await saving, isFalse);
        await checked;
        expect(uiErrors, isEmpty);
        final release = await work.prepareForExit();
        release();
        await work.dispose();
      },
    );
  }

  test('ordinary failure belongs to current UI and can retry', () async {
    final error = StateError('read failed');
    final stack = StackTrace.fromString('original read');
    final seen = <({Object error, StackTrace stack})>[];
    final work = ImageSaveWork(
      deliver: (_, _, _) async => true,
      onError: (error, stack) => seen.add((error: error, stack: stack)),
    );
    expect(
      await work.save(name: 'bad', read: (_) => Future.error(error, stack)),
      isFalse,
    );
    expect(seen, [(error: error, stack: stack)]);
    final release = await work.prepareForExit();
    release();
    expect(await work.save(name: 'good', read: (_) async => _png), isTrue);
    await work.dispose();
  });

  test('error-reporting failure preserves both causes', () async {
    final original = StateError('read');
    final reporting = StateError('report');
    final work = ImageSaveWork(
      deliver: (_, _, _) async => true,
      onError: (_, _) => throw reporting,
    );
    expect(
      await work.save(name: 'bad', read: (_) async => throw original),
      isFalse,
    );
    await expectLater(
      work.prepareForExit(),
      throwsA(
        isA<ImageWorkFailure>().having(
          (failure) => failure.failures.map((entry) => entry.error).toList(),
          'both errors',
          [original, reporting],
        ),
      ),
    );
    await work.dispose();
  });

  test(
    'concurrent saves keep busy until both finish and listeners detach',
    () async {
      final first = Completer<Uint8List>();
      final second = Completer<Uint8List>();
      final states = <bool>[];
      final work = ImageSaveWork(
        deliver: (_, _, _) async => true,
        onError: (_, _) {},
      );
      final remove = work.addListener(() => states.add(work.isBusy));
      final one = work.save(name: 'one', read: (_) => first.future);
      final two = work.save(name: 'two', read: (_) => second.future);
      first.complete(_png);
      await one;
      expect(work.isBusy, isTrue);
      second.complete(_png);
      await two;
      expect(states, [true, true, true, false]);
      remove();
      await work.save(name: 'three', read: (_) async => _png);
      expect(states, hasLength(4));
      await work.dispose();
    },
  );

  test('notification failure does not abandon accepted work', () async {
    final error = StateError('observer');
    final work = ImageSaveWork(
      deliver: (_, _, _) async => true,
      onError: (_, _) {},
    );
    work.addListener(() => throw error);
    expect(await work.save(name: 'image', read: (_) async => _png), isTrue);
    expect(work.isBusy, isFalse);
    await expectLater(work.prepareForExit(), throwsA(isA<ImageWorkFailure>()));
    await work.dispose();
  });
}
