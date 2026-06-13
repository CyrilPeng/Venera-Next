import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/file_downloader.dart';

void main() {
  setUp(() {
    appdata.settings['proxy'] = 'direct';
  });

  tearDown(() {
    appdata.settings['proxy'] = 'system';
  });

  test('FileDownloader writes concurrent range blocks sequentially', () async {
    final dir = Directory.systemTemp.createTempSync('venera-downloader-');
    final bytes = List<int>.generate(96 * 1024, (index) => index % 251);
    final server = await _serveBytes(bytes);
    addTearDown(() async {
      await server.close(force: true);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    final savePath = '${dir.path}/download.bin';
    final downloader = FileDownloader(
      'http://127.0.0.1:${server.port}/download.bin',
      savePath,
      maxConcurrent: 4,
      chunkSize: 8 * 1024,
    );

    final statuses = await downloader.start().toList();
    final savedBytes = await File(savePath).readAsBytes();

    expect(statuses.last.isFinished, isTrue);
    expect(savedBytes, bytes);
    expect(File('$savePath.download').existsSync(), isFalse);
  });

  test('FileDownloader forwards range errors and closes file handle', () async {
    final dir = Directory.systemTemp.createTempSync('venera-downloader-');
    final bytes = List<int>.generate(32 * 1024, (index) => index % 251);
    final server = await _serveBytes(bytes, failRangeStarts: {8 * 1024});
    addTearDown(() async {
      await server.close(force: true);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    final savePath = '${dir.path}/download.bin';
    final downloader = FileDownloader(
      'http://127.0.0.1:${server.port}/download.bin',
      savePath,
      maxConcurrent: 2,
      chunkSize: 8 * 1024,
    );

    Object? error;
    try {
      await downloader.start().drain<void>();
    } catch (e) {
      error = e;
    }

    expect(error, isA<DioException>());
    expect(File('$savePath.download').existsSync(), isTrue);

    await File(savePath).delete();
    expect(File(savePath).existsSync(), isFalse);
  });

  test('FileDownloader closes stream when stopped during setup', () async {
    final dir = Directory.systemTemp.createTempSync('venera-downloader-');
    final bytes = List<int>.generate(16 * 1024, (index) => index % 251);
    final headGate = Completer<void>();
    final server = await _serveBytes(
      bytes,
      beforeHeadResponse: headGate.future,
    );
    addTearDown(() async {
      await server.close(force: true);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    final savePath = '${dir.path}/download.bin';
    final downloader = FileDownloader(
      'http://127.0.0.1:${server.port}/download.bin',
      savePath,
      maxConcurrent: 2,
      chunkSize: 8 * 1024,
    );

    final done = downloader.start().drain<void>();
    await pumpEventQueue();
    await downloader.stop();

    headGate.complete();

    await done.timeout(const Duration(seconds: 1));
    if (File(savePath).existsSync()) {
      await File(savePath).delete();
    }
    expect(File(savePath).existsSync(), isFalse);
  });

  test(
    'FileDownloader closes stream when stopped during active block',
    () async {
      final dir = Directory.systemTemp.createTempSync('venera-downloader-');
      final bytes = List<int>.generate(16 * 1024, (index) => index % 251);
      final rangePaused = Completer<void>();
      final rangeGate = Completer<void>();
      final server = await _serveBytes(
        bytes,
        pausedRangeStarts: {0},
        onPausedRangeStart: () {
          if (!rangePaused.isCompleted) {
            rangePaused.complete();
          }
        },
        beforePausedRangeFinish: rangeGate.future,
      );
      addTearDown(() async {
        if (!rangeGate.isCompleted) {
          rangeGate.complete();
        }
        await server.close(force: true);
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      });

      final savePath = '${dir.path}/download.bin';
      final downloader = FileDownloader(
        'http://127.0.0.1:${server.port}/download.bin',
        savePath,
        maxConcurrent: 1,
        chunkSize: 8 * 1024,
      );

      final done = downloader.start().drain<void>();

      await rangePaused.future.timeout(const Duration(seconds: 1));
      await downloader.stop();

      await done.timeout(const Duration(seconds: 1));
    },
  );
}

Future<HttpServer> _serveBytes(
  List<int> data, {
  Set<int> failRangeStarts = const {},
  Future<void>? beforeHeadResponse,
  Set<int> pausedRangeStarts = const {},
  void Function()? onPausedRangeStart,
  Future<void>? beforePausedRangeFinish,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final request in server) {
      await _handleRequest(
        request,
        data,
        failRangeStarts,
        beforeHeadResponse,
        pausedRangeStarts,
        onPausedRangeStart,
        beforePausedRangeFinish,
      );
    }
  }());
  return server;
}

Future<void> _handleRequest(
  HttpRequest request,
  List<int> data,
  Set<int> failRangeStarts,
  Future<void>? beforeHeadResponse,
  Set<int> pausedRangeStarts,
  void Function()? onPausedRangeStart,
  Future<void>? beforePausedRangeFinish,
) async {
  if (request.method == 'HEAD') {
    await beforeHeadResponse;
    request.response.headers.contentLength = data.length;
    await request.response.close();
    return;
  }

  var start = 0;
  var end = data.length - 1;
  final range = request.headers.value(HttpHeaders.rangeHeader);
  if (range != null) {
    final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range);
    if (match != null) {
      start = int.parse(match.group(1)!);
      end = int.parse(match.group(2)!);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${data.length}',
      );
    }
  }

  if (failRangeStarts.contains(start)) {
    request.response.statusCode = HttpStatus.internalServerError;
    await request.response.close();
    return;
  }

  var responseStarted = false;
  if (pausedRangeStarts.contains(start)) {
    var firstChunkEnd = start + 1024;
    if (firstChunkEnd > end + 1) {
      firstChunkEnd = end + 1;
    }
    request.response.add(data.sublist(start, firstChunkEnd));
    await request.response.flush();
    responseStarted = true;
    onPausedRangeStart?.call();
    await beforePausedRangeFinish;
    start = firstChunkEnd;
  }

  final body = data.sublist(start, end + 1);
  if (!responseStarted) {
    request.response.headers.contentLength = body.length;
  }
  request.response.add(body);
  await request.response.close();
}
