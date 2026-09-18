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
