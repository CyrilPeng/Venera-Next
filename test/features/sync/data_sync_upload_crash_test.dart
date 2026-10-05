import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _operationId = '4a112222-3333-4444-8555-666666666666';
const _snapshot = [0, 1, 127, 255, 80, 75, 3, 4, 10];

void main() {
  for (final phase in ['preparing', 'snapshotWritten']) {
    test(
      'interrupted $phase is proven not applied without a remote request',
      () async {
        final fixture = await _Fixture.create();
        try {
          await fixture.killAt(phase);
          final result = await fixture.run('recover');
          expect(result['failure'], isNull);
          expect(result['state'], 'notApplied');
          expect((result['record'] as Map)['terminal'], isTrue);
          expect(fixture.puts, isEmpty);
          expect(fixture.gets, isEmpty);
          expect(fixture.objects, isEmpty);
          expect((await fixture.run('acknowledge'))['record'], isNull);
        } finally {
          await fixture.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }

  test('v3 intent without upload journal is proven not applied', () async {
    final fixture = await _Fixture.create();
    try {
      final result = await fixture.run('recover');
      expect(result['failure'], isNull);
      expect(result['state'], 'notApplied');
      expect((result['record'] as Map)['terminal'], isTrue);
      expect(fixture.puts, isEmpty);
      expect(fixture.gets, isEmpty);
      expect(
        File(p.join(fixture.root.path, 'version.calls')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(fixture.root.path, 'export.calls')).existsSync(),
        isFalse,
      );
    } finally {
      await fixture.close();
    }
  });

  for (final phase in [
    'prepared',
    'putPending',
    'confirmed',
    'retentionCompleted',
    'timeSaved',
    'remoteClosed',
    'sourceCleaned',
    'terminal',
  ]) {
    test(
      'real upload process killed at $phase resumes the same operation',
      () async {
        final fixture = await _Fixture.create();
        try {
          if (phase == 'retentionCompleted') {
            final day =
                DateTime.utc(2026, 10, 5, 12).millisecondsSinceEpoch ~/
                86400000;
            fixture.objects['$day-7.venera'] = _Archive([7, 7, 7]);
          }
          await fixture.killAt(phase);
          final recovered = await fixture.run('recover');
          fixture.expectApplied(recovered);
          expect(fixture.puts, hasLength(1));
          expect(fixture.objects.values.single.bytes, _snapshot);
          fixture.expectPreparedOnce();
          final names = fixture.objects.keys.toList();
          final stable = await fixture.run('recover');
          expect(stable, recovered);
          expect(fixture.objects.keys, names);
          expect(fixture.puts, hasLength(1));
          final acknowledged = await fixture.run('acknowledge');
          expect(acknowledged['record'], isNull);
        } finally {
          await fixture.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }

  test(
    'server stores PUT before killed client receives acknowledgement',
    () async {
      final fixture = await _Fixture.create();
      try {
        fixture.holdPut = true;
        final child = await fixture.start('upload');
        await fixture.putStored.future.timeout(const Duration(seconds: 30));
        final name = fixture.objects.keys.single;
        await child.kill();
        fixture.holdPut = false;
        fixture.releasePut.complete();
        final recovered = await fixture.run('recover');
        fixture.expectApplied(recovered);
        expect((recovered['record'] as Map)['remoteName'], name);
        expect(fixture.puts, [name]);
        expect(fixture.gets, contains(name));
        fixture.expectPreparedOnce();
      } finally {
        await fixture.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  for (final status in [401, 403, 500, 503]) {
    test(
      'recovery HTTP $status is not evidence of a missing archive',
      () async {
        final fixture = await _Fixture.create();
        try {
          await fixture.killAt('putPending');
          fixture.probeStatus = status;
          final failed = await fixture.run('recover');
          expect(failed['failure'], isNotNull);
          expect(failed['state'], 'recoveryRequired');
          expect(fixture.puts, isEmpty);
          fixture.probeStatus = null;
          fixture.expectApplied(await fixture.run('recover'));
          expect(fixture.puts, hasLength(1));
          fixture.expectPreparedOnce();
        } finally {
          await fixture.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }

  for (final sameContent in [true, false]) {
    test(
      'conditional PUT race with ${sameContent ? 'matching' : 'different'} content',
      () async {
        final fixture = await _Fixture.create();
        try {
          await fixture.killAt('putPending');
          fixture.racePutBytes = sameContent ? _snapshot : [9, 9, 9];
          final result = await fixture.run('recover');
          if (sameContent) {
            fixture.expectApplied(result);
          } else {
            expect(result['failure'], isNotNull);
            expect(result['state'], 'recoveryRequired');
            expect(fixture.objects.values.single.bytes, [9, 9, 9]);
          }
          expect(fixture.puts, hasLength(1));
          expect(fixture.gets.length, greaterThanOrEqualTo(2));
          fixture.expectPreparedOnce();
        } finally {
          await fixture.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }

  for (final removeSource in [true, false]) {
    test(
      'missing remote and ${removeSource ? 'missing' : 'corrupt'} snapshot never re-export',
      () async {
        final fixture = await _Fixture.create();
        try {
          await fixture.killAt('putPending');
          final snapshot = File(
            p.join(
              fixture.root.path,
              'data',
              '.data-sync-upload-$_operationId',
              'snapshot.venera',
            ),
          );
          expect(snapshot.existsSync(), isTrue);
          if (removeSource) {
            snapshot.deleteSync();
          } else {
            snapshot.writeAsBytesSync([8, 8, 8], flush: true);
          }
          final result = await fixture.run('recover');
          expect(result['failure'], isNotNull);
          expect(result['state'], 'recoveryRequired');
          expect(fixture.puts, isEmpty);
          fixture.expectPreparedOnce();
        } finally {
          await fixture.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }

  test(
    'archive removed after durable confirmation is never rebuilt',
    () async {
      final fixture = await _Fixture.create();
      try {
        await fixture.killAt('confirmed');
        expect(fixture.objects, hasLength(1));
        fixture.objects.clear();
        final result = await fixture.run('recover');
        expect(result['state'], 'applied');
        expect(fixture.puts, hasLength(1));
        expect(fixture.objects, isEmpty);
        fixture.expectPreparedOnce();
      } finally {
        await fixture.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'retention DELETE applied before killed client receives acknowledgement',
    () async {
      final fixture = await _Fixture.create();
      try {
        final day =
            DateTime.utc(2026, 10, 5, 12).millisecondsSinceEpoch ~/ 86400000;
        final old = '$day-7.venera';
        fixture.objects[old] = _Archive([7, 7, 7]);
        fixture.holdDelete = true;
        final child = await fixture.start('upload');
        await fixture.deleteStored.future.timeout(const Duration(seconds: 30));
        expect(fixture.objects.containsKey(old), isFalse);
        await child.kill();
        fixture.holdDelete = false;
        fixture.releaseDelete.complete();
        fixture.expectApplied(await fixture.run('recover'));
        expect(fixture.deletes, [old]);
        expect(fixture.puts, hasLength(1));
        fixture.expectPreparedOnce();
      } finally {
        await fixture.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

class _Archive {
  _Archive(List<int> bytes) : bytes = List<int>.of(bytes);
  final List<int> bytes;
  String get etag => '"${crypto.sha256.convert(bytes)}"';
}

class _Fixture {
  _Fixture(this.root, this.server);
  final Directory root;
  final HttpServer server;
  final objects = <String, _Archive>{};
  final gets = <String>[];
  final puts = <String>[];
  final deletes = <String>[];
  final children = <_Probe>[];
  final putStored = Completer<void>();
  final deleteStored = Completer<void>();
  final releasePut = Completer<void>();
  final releaseDelete = Completer<void>();
  final protocolErrors = <String>[];
  bool holdPut = false;
  bool holdDelete = false;
  int? probeStatus;
  List<int>? racePutBytes;

  Uri get endpoint => Uri.parse('http://127.0.0.1:${server.port}/');

  static Future<_Fixture> create() async {
    final root = Directory.systemTemp.createTempSync('sync-upload-crash-');
    Directory(p.join(root.path, 'data')).createSync();
    File(
      p.join(root.path, 'incoming.venera'),
    ).writeAsBytesSync(_snapshot, flush: true);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _Fixture(root, server);
    server.listen((request) async {
      try {
        await fixture.serve(request);
      } on SocketException {
        // The parent intentionally killed the client holding this connection.
      } on HttpException {
        // An acknowledgement can arrive after that connection has closed.
      }
    });
    return fixture;
  }

  Future<void> serve(HttpRequest request) async {
    final name = request.uri.pathSegments
        .where((part) => part.isNotEmpty)
        .join('/');
    final response = request.response;
    if (request.method == 'GET' && name.isEmpty) {
      response.write(jsonEncode(objects.keys.toList()));
    } else if (request.method == 'GET') {
      gets.add(name);
      final archive = objects[name];
      if (probeStatus != null) {
        response.statusCode = probeStatus!;
      } else if (archive == null) {
        response.statusCode = 404;
      } else {
        response.headers.set(HttpHeaders.etagHeader, archive.etag);
        response.contentLength = archive.bytes.length;
        response.add(archive.bytes);
      }
    } else if (request.method == 'PUT') {
      puts.add(name);
      final bytes = await request.fold<List<int>>(
        [],
        (all, part) => all..addAll(part),
      );
      if (request.headers.value(HttpHeaders.ifNoneMatchHeader) != '*') {
        protocolErrors.add('PUT without If-None-Match: *');
        response.statusCode = 400;
      } else {
        if (racePutBytes != null) {
          objects[name] = _Archive(racePutBytes!);
          racePutBytes = null;
        }
        if (objects.containsKey(name)) {
          response.statusCode = 412;
        } else {
          objects[name] = _Archive(bytes);
          response.statusCode = 201;
          if (!putStored.isCompleted) putStored.complete();
          if (holdPut) await releasePut.future;
        }
      }
    } else if (request.method == 'DELETE') {
      deletes.add(name);
      final archive = objects[name];
      final tag = request.headers.value(HttpHeaders.ifMatchHeader);
      if (tag == null) {
        protocolErrors.add('DELETE without If-Match');
        response.statusCode = 400;
      } else if (archive == null) {
        response.statusCode = 404;
      } else if (tag != archive.etag) {
        response.statusCode = 412;
      } else {
        objects.remove(name);
        response.statusCode = 204;
        if (!deleteStored.isCompleted) deleteStored.complete();
        if (holdDelete) await releaseDelete.future;
      }
    } else {
      protocolErrors.add('Unexpected method ${request.method}');
      response.statusCode = 405;
    }
    await response.close();
  }

  Future<_Probe> start(String command, [String phase = '']) async {
    final process = await Process.start(_dartExecutable(), [
      '--packages=${p.absolute('.dart_tool/package_config.json')}',
      'test/fixtures/data_sync_upload_crash_probe.dart',
      root.path,
      endpoint.toString(),
      command,
      phase,
    ]);
    final probe = _Probe(process);
    children.add(probe);
    return probe;
  }

  Future<void> killAt(String phase) async {
    final ready = File(p.join(root.path, 'ready.json'));
    if (ready.existsSync()) ready.deleteSync();
    final child = await start('upload', phase);
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!ready.existsSync() &&
        !child.exited &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (!ready.existsSync()) {
      await child.stop();
      fail(
        'Upload probe did not reach $phase: ${await child.errors}\n${await child.output}',
      );
    }
    final marker = jsonDecode(ready.readAsStringSync()) as Map;
    expect(marker['pid'], child.process.pid);
    expect(marker['phase'], phase);
    await child.kill();
  }

  Future<Map<String, dynamic>> run(String command) async {
    final child = await start(command);
    final code = await child.exitCode.timeout(const Duration(seconds: 30));
    final output = await child.output;
    final errors = await child.errors;
    expect(code, 0, reason: '$command failed: $errors\n$output');
    expect(errors, isEmpty);
    return jsonDecode(output) as Map<String, dynamic>;
  }

  void expectApplied(Map<String, dynamic> result) {
    expect(result['failure'], isNull);
    expect(result['state'], 'applied');
    final record = result['record'] as Map;
    expect(record['terminal'], isTrue);
    expect(record['version'], 8);
    expect(record['sha256'], crypto.sha256.convert(_snapshot).toString());
    expect(record['length'], _snapshot.length);
    expect(
      File(p.join(root.path, 'sync-time')).readAsStringSync(),
      '${record['committedAt']}',
    );
    expect(protocolErrors, isEmpty);
  }

  void expectPreparedOnce() {
    for (final operation in ['version', 'export']) {
      expect(File(p.join(root.path, '$operation.calls')).readAsLinesSync(), [
        operation,
      ]);
    }
  }

  Future<void> close() async {
    if (!releasePut.isCompleted) releasePut.complete();
    if (!releaseDelete.isCompleted) releaseDelete.complete();
    for (final child in children) {
      await child.stop();
    }
    await server.close(force: true);
    root.deleteSync(recursive: true);
  }
}

class _Probe {
  _Probe(this.process) {
    errors = process.stderr.transform(utf8.decoder).join();
    output = process.stdout.transform(utf8.decoder).join();
    exitCode = process.exitCode.then((code) {
      exited = true;
      return code;
    });
  }
  final Process process;
  late final Future<String> errors;
  late final Future<String> output;
  late final Future<int> exitCode;
  bool exited = false;

  Future<void> kill() async {
    expect(process.kill(ProcessSignal.sigkill), isTrue);
    expect(await exitCode.timeout(const Duration(seconds: 10)), isNot(0));
    expect(await errors, isEmpty);
  }

  Future<void> stop() async {
    if (!exited) process.kill(ProcessSignal.sigkill);
    await exitCode.timeout(const Duration(seconds: 10));
    await process.stdin.close();
    await errors;
    await output;
  }
}

String _dartExecutable() {
  final executable = Platform.isWindows ? 'dart.exe' : 'dart';
  var directory = File(Platform.resolvedExecutable).parent;
  while (true) {
    for (final relative in [
      'bin/cache/dart-sdk/bin/$executable',
      'bin/$executable',
    ]) {
      final candidate = File(p.join(directory.path, relative));
      if (candidate.existsSync()) {
        final vm = File(
          p.join(
            candidate.parent.path,
            Platform.isWindows ? 'dartvm.exe' : 'dartvm',
          ),
        );
        return vm.existsSync() ? vm.path : candidate.path;
      }
    }
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  throw StateError('Cannot locate the Dart SDK executable without a shell');
}
