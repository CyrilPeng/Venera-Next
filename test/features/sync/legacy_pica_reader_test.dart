import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/sync/legacy_pica_reader.dart';

void main() {
  late Database db;
  late LegacyPicaReader reader;
  setUp(() {
    db = sqlite3.openInMemory();
    reader = LegacyPicaReader(db);
  });
  tearDown(() => db.dispose());

  test(
    'favorites retain legacy type numbering, quoted folders and tag positions',
    () {
      db.execute('CREATE TABLE folder_order (name TEXT);');
      db.execute(
        'CREATE TABLE folder_sync (folder_name TEXT, key TEXT, sync_data TEXT);',
      );
      db.execute(
        'CREATE TABLE "收藏 ""A""" (target TEXT, name TEXT, cover_path TEXT, author TEXT, type INT, tags TEXT);',
      );
      for (final type in [0, 1, 2, 3, 4, 5, 6, 99]) {
        db.execute('INSERT INTO "收藏 ""A""" VALUES (?, ?, ?, ?, ?, ?);', [
          '$type',
          'title',
          'cover',
          'author',
          type,
          ',a,,b',
        ]);
      }
      expect(reader.favoriteFolders(), ['收藏 "A"']);
      final items = reader.favorites('收藏 "A"').toList();
      expect(items.map((item) => item.type.value), [
        'picacg'.hashCode,
        'ehentai'.hashCode,
        'jm'.hashCode,
        'hitomi'.hashCode,
        'wnacg'.hashCode,
        5,
        'nhentai'.hashCode,
        99,
      ]);
      expect(items.first.tags, ['', 'a', '', 'b']);
      expect(items.first.coverPath, 'cover');
    },
  );

  test('network links normalize the renamed source and defer JSON decoding', () {
    db.execute(
      'CREATE TABLE folder_sync (folder_name TEXT, key TEXT, sync_data TEXT);',
    );
    db.execute('INSERT INTO folder_sync VALUES (?, ?, ?);', [
      'valid',
      'HtManga',
      '{"folderId":"remote"}',
    ]);
    db.execute('INSERT INTO folder_sync VALUES (?, ?, ?);', [
      'existing',
      'picacg',
      null,
    ]);
    final links = reader.folderLinks().toList();
    expect(links.first.sourceKey, 'wnacg');
    expect(links.first.networkFolder, 'remote');
    expect(links.last.folder, 'existing');
    expect(() => links.last.networkFolder, throwsA(isA<TypeError>()));
  });

  test('history maps its distinct type numbering and string read chapters', () {
    db.execute(
      'CREATE TABLE history (target TEXT, type INT, max_page INT, ep INT, page INT, time INT, title TEXT, subtitle TEXT, cover TEXT);',
    );
    for (final type in [0, 1, 2, 3, 4, 5, 6, 99]) {
      db.execute(
        "INSERT INTO history VALUES (?, ?, 20, 2, 7, 1234, 'title', 'author', 'cover');",
        ['$type', type],
      );
    }
    final items = reader.history().toList();
    expect(items.map((item) => item.type.value), [
      'picacg'.hashCode,
      'ehentai'.hashCode,
      'jm'.hashCode,
      'hitomi'.hashCode,
      'wnacg'.hashCode,
      'nhentai'.hashCode,
      6,
      99,
    ]);
    expect(items.first.readEpisode, {'2'});
    expect(items.first.time.millisecondsSinceEpoch, 1234);
    expect(items.first.page, 7);
    expect(items.first.maxPage, 20);
    expect(items.first.readDurationMs, 0);
  });

  test('image identities keep hyphens and normalize only zero chapters', () {
    db.execute(
      'CREATE TABLE image_favorites (id TEXT, page INT, ep INT, title TEXT);',
    );
    db.execute(
      "INSERT INTO image_favorites VALUES ('HtManga-book-part-2', 3, 0, 'title');",
    );
    db.execute(
      "INSERT INTO image_favorites VALUES ('picacg-book', 4, 5, 'title');",
    );
    db.execute(
      "INSERT INTO image_favorites VALUES ('unavailable', 1, 0, 'ignored');",
    );
    final items = reader
        .images(sourceAvailable: (key) => key != 'unavailable')
        .toList();
    expect(items.first.id, 'book-part-2');
    expect(items.first.sourceKey, 'wnacg');
    expect(items.first.ep, 1);
    expect(items.first.page, 3);
    expect(items.last.ep, 5);
    db.execute(
      "INSERT INTO image_favorites VALUES ('picacg', 1, 1, 'invalid');",
    );
    expect(
      () => reader.images(sourceAvailable: (key) => key == 'picacg').toList(),
      throwsFormatException,
    );
  });
}
