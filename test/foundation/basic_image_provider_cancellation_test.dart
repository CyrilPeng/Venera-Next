import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/foundation/image_provider/cached_image.dart';
import 'package:venera_next/foundation/image_provider/image_provider_lifecycle.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await pumpEventQueue();
    expect(BaseImageProvider.debugActiveLoadCount, 0);
    expect(CachedImageProvider.loadingCount, 0);
  });

  test('cached late read failure reaches shutdown without fallback', () async {
    final read = Completer<Uint8List>();
    final file = _ControlledFile(read: read);
    final provider = _CachedProvider(file);
    final loading = _start<CachedImageProvider>(provider);
    await pumpEventQueue();
    expect(file.reads, 1);

    final preparation = _Preparation();
    await preparation.expectPending();
    expect(CachedImageProvider.loadingCount, 1);
    final error = FileSystemException('late thumbnail read', file.path);
    final stack = StackTrace.fromString('thumbnail native read stack');
    read.completeError(error, stack);

    await _expectFailure(loading, preparation, error, stack);
    expect(file.reads, 1);
    expect(provider.fallbacks, 0);
  });

  test('cached shutdown waits for accepted read and skips decode', () async {
    final read = Completer<Uint8List>();
    final file = _ControlledFile(read: read);
    final provider = _CachedProvider(file);
    final loading = _start<CachedImageProvider>(provider);
    await pumpEventQueue();
    expect(file.reads, 1);

    final preparation = _Preparation();
    await preparation.expectPending();
    read.complete(Uint8List.fromList([1, 2, 3]));
    await _expectSuccessfulCancellation(loading, preparation);
    expect(provider.fallbacks, 0);
    expect(file.reads, 1);
  });

  for (final fails in [false, true]) {
    test('cached shutdown drains accepted fallback; fails=$fails', () async {
      final read = Completer<Uint8List>();
      final fallback = Completer<Uint8List?>();
      final file = _ControlledFile(read: read);
      final provider = _CachedProvider(file, fallbackResult: fallback.future);
      final loading = _start<CachedImageProvider>(provider);
      await pumpEventQueue();
      read.completeError(
        FileSystemException('primary thumbnail read', file.path),
      );
      await pumpEventQueue();
      expect(provider.fallbacks, 1);

      final preparation = _Preparation();
      await preparation.expectPending();
      expect(CachedImageProvider.loadingCount, 1);
      if (fails) {
        final error = StateError('late fallback failure');
        final stack = StackTrace.fromString('fallback result stack');
        fallback.completeError(error, stack);
        await _expectFailure(loading, preparation, error, stack);
      } else {
        fallback.complete(Uint8List.fromList([1, 2, 3]));
        await _expectSuccessfulCancellation(loading, preparation);
      }
      expect(file.reads, 1);
      expect(provider.fallbacks, 1);
    });
  }

  test('queued cached cancellation never creates its local file', () async {
    final releaseSlots = Completer<void>();
    final holders = List.generate(
      9,
      (_) => CachedImageProvider.debugRunWithThumbnailSlot(
        () => releaseSlots.future,
      ),
    );
    addTearDown(() async {
      if (!releaseSlots.isCompleted) releaseSlots.complete();
      await Future.wait(holders);
    });
    await pumpEventQueue();
    expect(CachedImageProvider.loadingCount, 9);

    final file = _ControlledFile();
    final provider = _CachedProvider(file);
    final loading = _start<CachedImageProvider>(provider);
    await pumpEventQueue();
    expect(BaseImageProvider.debugActiveLoadCount, 1);
    final preparation = _Preparation();
    await _expectSuccessfulCancellation(loading, preparation);
    expect(provider.fileCreations, 0);
    expect(provider.fallbacks, 0);
    expect(file.reads, 0);
    expect(CachedImageProvider.loadingCount, 9);
    releaseSlots.complete();
    await Future.wait(holders);
  });

  for (final stage in ['exists', 'length', 'read']) {
    for (final fails in [false, true]) {
      test('reader shutdown drains $stage; fails=$fails', () async {
        final exists = stage == 'exists' ? Completer<bool>() : null;
        final length = stage == 'length' ? Completer<int>() : null;
        final read = stage == 'read' ? Completer<Uint8List>() : null;
        final file = _ControlledFile(
          exists: exists,
          length: length,
          read: read,
        );
        final provider = _ReaderProvider(file);
        final loading = _start<ReaderImageProvider>(provider);
        await pumpEventQueue();
        expect(file.existenceChecks, 1);
        expect(file.lengthChecks, stage == 'exists' ? 0 : 1);
        expect(file.reads, stage == 'read' ? 1 : 0);

        final preparation = _Preparation();
        await preparation.expectPending();
        if (fails) {
          final error = FileSystemException('late reader $stage', file.path);
          final stack = StackTrace.fromString('reader native $stage stack');
          if (exists != null) exists.completeError(error, stack);
          if (length != null) length.completeError(error, stack);
          if (read != null) read.completeError(error, stack);
          await _expectFailure(loading, preparation, error, stack);
        } else {
          exists?.complete(true);
          length?.complete(3);
          read?.complete(Uint8List.fromList([1, 2, 3]));
          await _expectSuccessfulCancellation(loading, preparation);
        }
        expect(provider.fileCreations, 1);
        expect(file.existenceChecks, 1);
        expect(file.lengthChecks, stage == 'exists' ? 0 : 1);
        expect(file.reads, stage == 'read' ? 1 : 0);
      });
    }
  }

  for (final byteCount in [0, 1]) {
    test(
      'reader retains late integrity failure for $byteCount bytes',
      () async {
        final read = Completer<Uint8List>();
        final file = _ControlledFile(read: read);
        final provider = _ReaderProvider(file);
        final loading = _start<ReaderImageProvider>(provider);
        await pumpEventQueue();
        expect(file.reads, 1);
        final preparation = _Preparation();
        await preparation.expectPending();
        read.complete(Uint8List(byteCount));
        await preparation.done;
        await pumpEventQueue();

        final failure = preparation.failure! as ImageProviderPreparationFailure;
        expect(failure.failures, hasLength(1));
        final original = failure.failures.single;
        expect(
          original.error,
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            'Incomplete file read: expected 3 bytes, got $byteCount',
          ),
        );
        expect(loading.failures.single.error, same(original.error));
        expect(loading.failures.single.stack, same(original.stack));
        expect(loading.decodes, 0);
        expect(file.lengthChecks, 1);
        expect(file.reads, 1);
      },
    );
  }
}

class _ControlledFile extends Fake implements File {
  _ControlledFile({
    Completer<bool>? exists,
    Completer<int>? length,
    Completer<Uint8List>? read,
  }) : _exists = exists,
       _length = length,
       _read = read;

  final Completer<bool>? _exists;
  final Completer<int>? _length;
  final Completer<Uint8List>? _read;
  int existenceChecks = 0;
  int lengthChecks = 0;
  int reads = 0;

  @override
  String get path => 'controlled-local-image.jpg';

  @override
  Future<bool> exists() {
    existenceChecks++;
    return _exists?.future ?? Future.value(true);
  }

  @override
  Future<int> length() {
    lengthChecks++;
    return _length?.future ?? Future.value(3);
  }

  @override
  Future<Uint8List> readAsBytes() {
    reads++;
    return _read?.future ?? Future.value(Uint8List.fromList([1, 2, 3]));
  }
}

class _CachedProvider extends CachedImageProvider {
  _CachedProvider(this.file, {Future<Uint8List?>? fallbackResult})
    : _fallbackResult = fallbackResult,
      super('file://${file.path}');

  final File file;
  final Future<Uint8List?>? _fallbackResult;
  int fileCreations = 0;
  int fallbacks = 0;

  @override
  File createLocalFile(String path) {
    expect(path, file.path);
    fileCreations++;
    return file;
  }

  @override
  FutureOr<Uint8List?> Function() get fallback => () {
    fallbacks++;
    return _fallbackResult ?? Uint8List.fromList([4, 5, 6]);
  };
}

class _ReaderProvider extends ReaderImageProvider {
  _ReaderProvider(this.file)
    : super('file://${file.path}', null, 'comic', 'episode', 1);

  final File file;
  int fileCreations = 0;

  @override
  File createLocalFile(String path) {
    expect(path, file.path);
    fileCreations++;
    return file;
  }
}

_Loading _start<T extends BaseImageProvider<T>>(T provider) {
  final loading = _Loading();
  loading.completer = provider.loadImage(provider, (
    buffer, {
    getTargetSize,
  }) async {
    loading.decodes++;
    buffer.dispose();
    throw StateError('cancelled local load must not reach decode');
  });
  loading.listener = ImageStreamListener(
    (image, _) {
      image.dispose();
      fail('cancelled local load must not deliver an image');
    },
    onError: (Object error, StackTrace? stack) {
      loading.failures.add((error: error, stack: stack));
    },
  );
  loading.completer.addListener(loading.listener);
  addTearDown(loading.dispose);
  return loading;
}

class _Loading {
  late final ImageStreamCompleter completer;
  late final ImageStreamListener listener;
  final failures = <({Object error, StackTrace? stack})>[];
  int decodes = 0;
  bool disposed = false;

  void dispose() {
    if (disposed) return;
    disposed = true;
    completer.removeListener(listener);
  }
}

class _Preparation {
  _Preparation() {
    done = BaseImageProvider.prepareForExit().then<void>(
      (release) {
        releaseHold = release;
        finished = true;
      },
      onError: (Object error, StackTrace stack) {
        failure = error;
        finished = true;
      },
    );
    addTearDown(() => releaseHold?.call());
  }

  late final Future<void> done;
  VoidCallback? releaseHold;
  Object? failure;
  bool finished = false;

  Future<void> expectPending() async {
    await pumpEventQueue();
    expect(finished, isFalse);
    expect(BaseImageProvider.debugActiveLoadCount, 1);
  }
}

Future<void> _expectSuccessfulCancellation(
  _Loading loading,
  _Preparation preparation,
) async {
  await preparation.done;
  expect(preparation.failure, isNull);
  expect(preparation.releaseHold, isNotNull);
  expect(BaseImageProvider.debugActiveLoadCount, 0);
  expect(loading.decodes, 0);
  expect(loading.failures, isEmpty);
  loading.dispose();
  preparation.releaseHold!();
  await pumpEventQueue();
  expect(loading.decodes, 0);
}

Future<void> _expectFailure(
  _Loading loading,
  _Preparation preparation,
  Object error,
  StackTrace stack,
) async {
  await preparation.done;
  await pumpEventQueue();
  final failure = preparation.failure! as ImageProviderPreparationFailure;
  expect(failure.failures, hasLength(1));
  expect(failure.failures.single.error, same(error));
  expect(failure.failures.single.stack, same(stack));
  expect(loading.failures, hasLength(1));
  expect(loading.failures.single.error, same(error));
  expect(loading.failures.single.stack, same(stack));
  expect(loading.decodes, 0);
  expect(BaseImageProvider.debugActiveLoadCount, 0);
  loading.dispose();
  final release = await BaseImageProvider.prepareForExit();
  release();
}
