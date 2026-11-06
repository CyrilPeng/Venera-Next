import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/import_export/pdf.dart';

final class _Output implements StreamConsumer<List<int>> {
  _Output(this.failClose);
  final bool failClose;
  int closes = 0;
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final _ in stream) {}
  }

  @override
  Future<void> close() async {
    closes++;
    if (failClose) throw StateError('secondary close failure');
  }
}

final class _OutputFile extends Fake implements File {
  _OutputFile(this.consumer);
  final _Output consumer;
  @override
  IOSink openWrite({
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
  }) => IOSink(consumer, encoding: encoding);
}

final class _OutputOverride extends IOOverrides {
  _OutputOverride(this.path, this.consumer);
  final String path;
  final _Output consumer;
  @override
  File createFile(String value) =>
      value == path ? _OutputFile(consumer) : super.createFile(value);
}

void main() {
  for (final failClose in [false, true]) {
    test(
      'PDF decode failure closes output and retains its cause; closeError=$failClose',
      () async {
        final temporary = Directory.systemTemp.createTempSync(
          'venera-pdf-output-',
        );
        try {
          final input = File('${temporary.path}/page')
            ..writeAsBytesSync([1, 2, 3]);
          final path = '${temporary.path}/output.pdf';
          final consumer = _Output(failClose);
          final cause = StateError('primary decode failure');
          await expectLater(
            IOOverrides.runWithIOOverrides(
              () => PdfGenerator(
                title: 'test',
                author: 'test',
                imagePaths: [input.path],
                outputPath: path,
                decodeImage: (_) async => throw cause,
              ).generate(),
              _OutputOverride(path, consumer),
            ),
            throwsA(same(cause)),
          );
          expect(consumer.closes, 1);
        } finally {
          temporary.deleteSync(recursive: true);
        }
      },
    );
  }
}
