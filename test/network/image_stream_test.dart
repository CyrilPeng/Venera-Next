import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/network/image_stream.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/request_scope.dart';

void main() {
  test(
    'cancels a stalled subscription without waiting for another event',
    () async {
      final scope = RequestScope();
      var cancelled = false;
      final source = StreamController<ImageDownloadProgress>(
        onCancel: () => cancelled = true,
      );
      final result = readImageStream(
        source.stream,
        cancelSignal: scope.whenCancelled,
        checkStop: scope.check,
      );
      final expectation = expectLater(result, throwsA(isA<RequestCancelled>()));
      scope.cancel();
      await expectation;
      expect(cancelled, true);
      await source.close();
      scope.dispose();
    },
  );

  test(
    'returns final bytes and unsubscribes after reporting progress',
    () async {
      final scope = RequestScope();
      var cancelled = false;
      final source = StreamController<ImageDownloadProgress>(
        onCancel: () => cancelled = true,
      );
      final progress = <int>[];
      final result = readImageStream(
        source.stream,
        cancelSignal: scope.whenCancelled,
        checkStop: scope.check,
        onProgress: (event) => progress.add(event.currentBytes),
      );
      final bytes = Uint8List.fromList([1, 2]);
      source.add(const ImageDownloadProgress(currentBytes: 1, totalBytes: 2));
      source.add(
        ImageDownloadProgress(
          currentBytes: 2,
          totalBytes: 2,
          imageBytes: bytes,
        ),
      );
      expect(await result, same(bytes));
      expect(progress, [1, 2]);
      expect(cancelled, true);
      await source.close();
      scope.dispose();
    },
  );

  test(
    'propagates errors and does not publish queued events after cancellation',
    () async {
      final scope = RequestScope();
      final failed = readImageStream(
        Stream.error(StateError('offline')),
        cancelSignal: scope.whenCancelled,
        checkStop: scope.check,
      );
      await expectLater(failed, throwsStateError);
      final source = StreamController<ImageDownloadProgress>();
      var notified = false;
      final pending = readImageStream(
        source.stream,
        cancelSignal: scope.whenCancelled,
        checkStop: scope.check,
        onProgress: (_) => notified = true,
      );
      final expectation = expectLater(
        pending,
        throwsA(isA<RequestCancelled>()),
      );
      source.add(const ImageDownloadProgress(currentBytes: 1, totalBytes: 2));
      scope.cancel();
      await expectation;
      expect(notified, false);
      await source.close();
      scope.dispose();
    },
  );
}
