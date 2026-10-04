import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/file_system.dart';

class _UnreliableFile implements File {
  _UnreliableFile(this.responses, {this.size = 3});
  final List<List<int>> responses;
  final int size;
  int reads = 0;
  @override
  String get path => 'content://test/page.jpg';
  @override
  Future<int> length() async => size;
  @override
  Future<Uint8List> readAsBytes() async =>
      Uint8List.fromList(responses[(reads++).clamp(0, responses.length - 1)]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final size in [0, 1, 3]) {
    test(
      'cancelled byte read preserves integrity failure for $size bytes',
      () async {
        final bytes = Completer<Uint8List>();
        final file = _PendingFile(bytes.future);
        final cancellation = StateError('cancelled');
        var cancelled = false;
        final reading = readFileBytesChecked(
          file,
          requireNonEmpty: true,
          checkStop: () {
            if (cancelled) throw cancellation;
          },
          canRetry: () => !cancelled,
        );
        final expected = expectLater(
          reading,
          throwsA(size < 3 ? isA<FileSystemException>() : same(cancellation)),
        );
        await pumpEventQueue();
        expect(file.reads, 1);
        cancelled = true;
        bytes.complete(Uint8List(size));
        await expected;
        expect(file.reads, 1);
      },
    );
  }

  test(
    'cancellation during length lookup does not start a byte read',
    () async {
      final length = Completer<int>();
      final file = _PendingFile(
        Future.value(Uint8List(3)),
        size: length.future,
      );
      var cancelled = false;
      final cancellation = StateError('cancelled');
      final reading = readFileBytesChecked(
        file,
        checkStop: () {
          if (cancelled) throw cancellation;
        },
      );
      final expected = expectLater(reading, throwsA(same(cancellation)));
      cancelled = true;
      length.complete(3);
      await expected;
      expect(file.reads, 0);
    },
  );

  test('declining a retry retains a late read failure and its stack', () async {
    final failedRead = Completer<Uint8List>();
    final file = _PendingFile(failedRead.future);
    final failure = FileSystemException('late native read', file.path);
    final stack = StackTrace.fromString('original read stack');
    var cancelled = false;
    var retryChecks = 0;
    final pending = readFileBytesChecked(
      file,
      checkStop: () {
        if (cancelled) throw StateError('cancelled');
      },
      canRetry: () {
        retryChecks++;
        return !cancelled;
      },
    );
    Object? observed;
    StackTrace? observedStack;
    final checked = pending.then<void>(
      (_) => fail('read should fail'),
      onError: (Object error, StackTrace trace) {
        observed = error;
        observedStack = trace;
      },
    );
    await pumpEventQueue();
    cancelled = true;
    failedRead.completeError(failure, stack);
    await checked;
    expect(observed, same(failure));
    expect(observedStack, same(stack));
    expect(file.reads, 1);
    expect(retryChecks, 1);
  });

  test('recovers from empty and short SAF reads', () async {
    final file = _UnreliableFile([
      [],
      [1],
      [1, 2, 3],
    ]);
    expect(await readFileBytesChecked(file, requireNonEmpty: true), [1, 2, 3]);
    expect(file.reads, 3);
  });

  test('persistent read failure stops after three attempts', () async {
    final file = _UnreliableFile([[]]);
    await expectLater(
      readFileBytesChecked(file),
      throwsA(isA<FileSystemException>()),
    );
    expect(file.reads, 3);
  });

  test('permits empty metadata but rejects empty images', () async {
    expect(await readFileBytesChecked(_UnreliableFile([[]], size: 0)), isEmpty);
    await expectLater(
      readFileBytesChecked(
        _UnreliableFile([[]], size: 0),
        requireNonEmpty: true,
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('cancellation interrupts a retry delay', () async {
    final cancel = Completer<void>();
    var stopped = false;
    final file = _UnreliableFile([[]]);
    final result = readFileBytesChecked(
      file,
      cancelSignal: cancel.future,
      checkStop: () {
        if (stopped) throw StateError('cancelled');
      },
    );
    final expectation = expectLater(result, throwsStateError);
    await pumpEventQueue();
    stopped = true;
    cancel.complete();
    await expectation;
    expect(file.reads, 1);
  });

  test(
    'directory copy waits for nested files and propagates read failures',
    () async {
      final root = Directory.systemTemp.createTempSync('checked-copy-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = Directory('${root.path}/source')..createSync();
      Directory('${source.path}/chapter').createSync();
      File('${source.path}/chapter/1.jpg').writeAsBytesSync([1, 2, 3]);
      final target = Directory('${root.path}/target');
      await copyDirectory(source, target, requireNonEmpty: (_) => true);
      expect(File('${target.path}/chapter/1.jpg').readAsBytesSync(), [1, 2, 3]);
      File('${source.path}/chapter/2.jpg').createSync();
      await expectLater(
        copyDirectory(source, target, requireNonEmpty: (_) => true),
        throwsA(isA<FileSystemException>()),
      );
      expect(File('${target.path}/chapter/2.jpg').existsSync(), isFalse);
    },
  );
}

class _PendingFile extends Fake implements File {
  _PendingFile(this.result, {this.size});
  final Future<Uint8List> result;
  final Future<int>? size;
  int reads = 0;
  @override
  String get path => 'pending.bin';
  @override
  Future<int> length() async => size == null ? 3 : await size!;
  @override
  Future<Uint8List> readAsBytes() {
    reads++;
    return result;
  }
}
