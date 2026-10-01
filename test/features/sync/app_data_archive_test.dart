import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/sync/app_data_archive.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('app-data-archive-'));
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'archive service round trips explicit paths without app globals',
    () async {
      final source = Directory('${root.path}/source')..createSync();
      final cache = Directory('${root.path}/cache')..createSync();
      final output = '${root.path}/backup.venera';
      for (final name in ['history.db', 'local_favorite.db', 'cookie.db']) {
        final db = sqlite3.open('${source.path}/$name');
        try {
          db.execute('CREATE TABLE content (value TEXT);');
          db.execute('INSERT INTO content VALUES (?);', [name]);
        } finally {
          db.dispose();
        }
      }
      Directory('${source.path}/comic_source').createSync();
      File(
        '${source.path}/comic_source/source.js',
      ).writeAsStringSync('// source');
      await AppDataArchive.create(
        dataPath: source.path,
        cachePath: cache.path,
        destinationPath: output,
        settingsJson: '{"settings":{"language":"en-US"}}',
      );
      expect(cache.listSync(), isEmpty);
      final extracted = '${root.path}/extracted';
      await AppDataArchive.extract(output, extracted);
      expect(jsonDecode(File('$extracted/appdata.json').readAsStringSync()), {
        'settings': {'language': 'en-US'},
      });
      expect(
        File('$extracted/comic_source/source.js').readAsStringSync(),
        '// source',
      );
      final db = sqlite3.open('$extracted/history.db');
      try {
        expect(
          db.select('SELECT value FROM content;').single['value'],
          'history.db',
        );
      } finally {
        db.dispose();
      }
    },
  );

  test('creation does not overwrite an existing archive', () async {
    final target = File('${root.path}/existing.venera')
      ..writeAsStringSync('keep');
    await expectLater(
      AppDataArchive.create(
        dataPath: root.path,
        cachePath: root.path,
        destinationPath: target.path,
        settingsJson: '{}',
      ),
      throwsStateError,
    );
    expect(target.readAsStringSync(), 'keep');
    expect(root.listSync(), hasLength(1));
  });

  test('all paths are validated before extraction writes any file', () async {
    final input = File('${root.path}/invalid.picadata');
    final archive = Archive()
      ..addFile(ArchiveFile.string('appdata.json', '{}'))
      ..addFile(ArchiveFile.string('../escape', 'invalid'));
    input.writeAsBytesSync(ZipEncoder().encode(archive));
    await expectLater(
      AppDataArchive.extract(input.path, '${root.path}/extracted'),
      throwsFormatException,
    );
    expect(File('${root.path}/extracted/appdata.json').existsSync(), isFalse);
    expect(File('${root.path}/escape').existsSync(), isFalse);
    input.renameSync('${input.path}.released');
  });
}
