import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const _databases = ['history.db', 'local_favorite.db', 'cookie.db'];
const _metadata = ['appdata.json', 'syncdata.json'];

void main() {
  for (final checkpoint in [
    (phase: 'prepared', applied: false),
    (phase: 'targetRemoved:history.db', applied: false),
    (phase: 'replaced:history.db', applied: false),
    (phase: 'replaced:comic_source', applied: false),
    (phase: 'metadataWritten:appdata.json', applied: false),
    (phase: 'beforeApplied', applied: false),
    (phase: 'applied', applied: true),
    (phase: 'cleanupResource', applied: true),
    (phase: 'cleaned', applied: true),
  ]) {
    test(
      'killed import at ${checkpoint.phase} recovers one complete image and retains receipt until acknowledgement',
      () async {
        final fixture = _ImportFixture.create();
        try {
          final interrupted = await _killAt(
            fixture.root,
            'apply',
            checkpoint.phase,
          );
          fixture.expectInterrupted(checkpoint.phase);
          final receipts = await _runProbe(fixture.root, 'recover');
          _expectReceipt(receipts, interrupted.id, checkpoint.applied);
          fixture.expectImage(checkpoint.applied);
          final stableImage = _image(fixture.data);
          expect(await _runProbe(fixture.root, 'recover'), receipts);
          expect(_image(fixture.data), stableImage);
          expect(
            await _runProbe(fixture.root, 'acknowledge', interrupted.id),
            isEmpty,
          );
          expect(await _runProbe(fixture.root, 'recover'), isEmpty);
          expect(_image(fixture.data), stableImage);
        } finally {
          fixture.root.deleteSync(recursive: true);
        }
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }

  test(
    'recovery survives another process kill during rollback',
    () async {
      final fixture = _ImportFixture.create();
      try {
        final original = await _killAt(
          fixture.root,
          'apply',
          'replaced:comic_source',
        );
        final rollback = await _killAt(fixture.root, 'recover', 'restored');
        expect(rollback.id, original.id);
        final receipts = await _runProbe(fixture.root, 'recover');
        _expectReceipt(receipts, original.id, false);
        fixture.expectImage(false);
        expect(await _runProbe(fixture.root, 'recover'), receipts);
        fixture.expectImage(false);
        expect(
          await _runProbe(fixture.root, 'acknowledge', original.id),
          isEmpty,
        );
      } finally {
        fixture.root.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'committed cleanup survives another kill and preserves later live writes',
    () async {
      final fixture = _ImportFixture.create();
      try {
        final original = await _killAt(fixture.root, 'apply', 'applied');
        fixture.expectImage(true);
        final db = sqlite3.open(p.join(fixture.data.path, 'history.db'));
        try {
          db.execute('INSERT INTO marker(value) VALUES (?)', [
            'later local edit',
          ]);
        } finally {
          db.dispose();
        }
        File(p.join(fixture.data.path, 'appdata.json')).writeAsStringSync(
          jsonEncode({
            'settings': {'dataVersion': 9},
            'later': 'local edit',
          }),
          flush: true,
        );
        File(
          p.join(fixture.data.path, 'comic_source', 'later.txt'),
        ).writeAsStringSync('later local file', flush: true);
        final edited = _image(fixture.data);
        final cleanup = await _killAt(
          fixture.root,
          'recover',
          'cleanupResource',
        );
        expect(cleanup.id, original.id);
        final receipts = await _runProbe(fixture.root, 'recover');
        _expectReceipt(receipts, original.id, true);
        expect(_image(fixture.data), edited);
        expect(await _runProbe(fixture.root, 'recover'), receipts);
        expect(_image(fixture.data), edited);
        expect(
          await _runProbe(fixture.root, 'acknowledge', original.id),
          isEmpty,
        );
        expect(_image(fixture.data), edited);
      } finally {
        fixture.root.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

void _expectReceipt(List<Object?> receipts, String id, bool applied) {
  expect(receipts, [
    {
      'id': id,
      'syncOperationId': 'crash-probe-sync-operation',
      'state': applied ? 'applied' : 'notApplied',
      'committedAt': applied ? 123456789 : null,
    },
  ]);
}

class _ImportFixture {
  _ImportFixture(this.root, this.data, this.oldImage, this.newImage);
  final Directory root;
  final Directory data;
  final Map<String, String> oldImage;
  final Map<String, String> newImage;

  factory _ImportFixture.create() {
    final root = Directory.systemTemp.createTempSync('app-import-crash-');
    final data = Directory(p.join(root.path, 'data'))..createSync();
    final incoming = Directory(p.join(root.path, 'incoming'))..createSync();
    for (final directory in [data, incoming]) {
      final label = identical(directory, data) ? 'old' : 'new';
      for (final name in _databases) {
        final db = sqlite3.open(p.join(directory.path, name));
        try {
          db.execute('PRAGMA journal_mode=DELETE');
          db.execute('CREATE TABLE marker(value TEXT NOT NULL)');
          db.execute('INSERT INTO marker(value) VALUES (?)', ['$label:$name']);
        } finally {
          db.dispose();
        }
      }
      final sources = Directory(
        p.join(directory.path, 'comic_source', 'nested'),
      )..createSync(recursive: true);
      File(
        p.join(sources.parent.path, '$label.js'),
      ).writeAsStringSync('$label script', flush: true);
      File(
        p.join(sources.path, '$label.bin'),
      ).writeAsBytesSync([label == 'old' ? 7 : 8, 0, 255], flush: true);
      for (final name in _metadata) {
        File(p.join(directory.path, name)).writeAsStringSync(
          jsonEncode({
            'settings': {'dataVersion': label == 'old' ? 7 : 8},
            'marker': '$label:$name',
          }),
          flush: true,
        );
        if (label == 'old') {
          for (final suffix in ['.bak', '.tmp']) {
            File(
              p.join(directory.path, '$name$suffix'),
            ).writeAsStringSync('old:$name$suffix', flush: true);
          }
        }
      }
    }
    final oldImage = _image(data);
    final newImage = _image(incoming);
    for (final name in _metadata) {
      newImage['$name.bak'] = oldImage[name]!;
    }
    return _ImportFixture(root, data, oldImage, newImage);
  }

  void expectImage(bool applied) {
    expect(_image(data), applied ? newImage : oldImage);
    for (final name in _databases) {
      final db = sqlite3.open(p.join(data.path, name));
      try {
        expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
        expect(
          db.select('SELECT value FROM marker').single['value'],
          '${applied ? 'new' : 'old'}:$name',
        );
      } finally {
        db.dispose();
      }
    }
  }

  void expectInterrupted(String phase) {
    final actual = _image(data);
    switch (phase) {
      case 'prepared':
        expect(actual, oldImage);
      case 'targetRemoved:history.db':
        expect(actual.containsKey('history.db'), isFalse);
        expect(actual['local_favorite.db'], oldImage['local_favorite.db']);
        expect(actual['appdata.json'], oldImage['appdata.json']);
      case 'replaced:history.db':
        expect(actual['history.db'], newImage['history.db']);
        expect(actual['local_favorite.db'], oldImage['local_favorite.db']);
        expect(actual['appdata.json'], oldImage['appdata.json']);
      case 'replaced:comic_source':
        for (final name in _databases) {
          expect(actual[name], newImage[name]);
        }
        expect(actual['comic_source/new.js'], newImage['comic_source/new.js']);
        expect(actual.containsKey('comic_source/old.js'), isFalse);
        expect(actual['appdata.json'], oldImage['appdata.json']);
      case 'metadataWritten:appdata.json':
        expect(actual['appdata.json'], newImage['appdata.json']);
        expect(actual['appdata.json.bak'], oldImage['appdata.json']);
        expect(actual.containsKey('appdata.json.tmp'), isFalse);
        expect(actual['syncdata.json'], oldImage['syncdata.json']);
        expect(actual['syncdata.json.bak'], oldImage['syncdata.json.bak']);
        expect(actual['syncdata.json.tmp'], oldImage['syncdata.json.tmp']);
      case 'beforeApplied':
      case 'applied':
      case 'cleanupResource':
      case 'cleaned':
        expect(actual, newImage);
      default:
        fail('Unknown interruption checkpoint: $phase');
    }
  }
}

Map<String, String> _image(Directory data) {
  final image = <String, String>{};
  for (final entity in data.listSync(recursive: true, followLinks: false)) {
    final relative = p
        .relative(entity.path, from: data.path)
        .replaceAll('\\', '/');
    if (relative.startsWith('.app-data-import')) continue;
    if (entity is File) {
      image[relative] = sha256.convert(entity.readAsBytesSync()).toString();
    } else if (entity is Directory) {
      image['$relative/'] = 'directory';
    } else {
      fail('Unexpected live filesystem entity: $relative');
    }
  }
  return image;
}

Future<({String id, String phase})> _killAt(
  Directory root,
  String command,
  String phase,
) async {
  final ready = File(p.join(root.path, 'ready.json'));
  if (ready.existsSync()) ready.deleteSync();
  final child = await _startProbe(root, command, phase);
  final errors = child.stderr.transform(utf8.decoder).join();
  final output = child.stdout.transform(utf8.decoder).join();
  var exited = false;
  final exitCode = child.exitCode.then((value) {
    exited = true;
    return value;
  });
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!ready.existsSync() &&
        !exited &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (!ready.existsSync()) {
      if (!exited) child.kill(ProcessSignal.sigkill);
      await exitCode.timeout(const Duration(seconds: 10));
      fail(
        'Probe did not reach $command/$phase: ${await errors}\n${await output}',
      );
    }
    final marker = jsonDecode(ready.readAsStringSync()) as Map<String, dynamic>;
    expect(marker['pid'], child.pid);
    expect(marker['phase'], phase.split(':').first);
    if (phase.contains(':')) expect(marker['resource'], phase.split(':')[1]);
    expect(child.kill(ProcessSignal.sigkill), isTrue);
    expect(await exitCode.timeout(const Duration(seconds: 10)), isNot(0));
    expect(await errors, isEmpty);
    expect(await output, isEmpty);
    return (id: marker['id'] as String, phase: marker['phase'] as String);
  } finally {
    if (!exited) child.kill(ProcessSignal.sigkill);
    await child.exitCode.timeout(const Duration(seconds: 10));
    await child.stdin.close();
    await errors;
    await output;
  }
}

Future<List<Object?>> _runProbe(
  Directory root,
  String command, [
  String argument = '',
]) async {
  final child = await _startProbe(root, command, argument);
  final errors = child.stderr.transform(utf8.decoder).join();
  final output = child.stdout.transform(utf8.decoder).join();
  try {
    final status = await child.exitCode.timeout(const Duration(seconds: 30));
    final errorText = await errors;
    final outputText = await output;
    expect(status, 0, reason: '$command failed: $errorText\n$outputText');
    expect(errorText, isEmpty);
    return jsonDecode(outputText) as List<Object?>;
  } finally {
    child.kill(ProcessSignal.sigkill);
    await child.exitCode.timeout(const Duration(seconds: 10));
    await child.stdin.close();
    await errors;
    await output;
  }
}

Future<Process> _startProbe(Directory root, String command, String argument) =>
    Process.start(_dartExecutable(), [
      '--packages=${p.absolute('.dart_tool/package_config.json')}',
      'test/fixtures/app_data_import_crash_probe.dart',
      root.path,
      command,
      argument,
    ]);

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
