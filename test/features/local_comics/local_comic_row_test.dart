import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/local_comics/local_comic_row.dart';

void main() {
  test(
    'named row decoding preserves legacy fields independent of column order',
    () {
      final db = sqlite3.openInMemory();
      try {
        db.execute(
          'CREATE TABLE comics (created_at INT, downloadedChapters TEXT, comic_type INT, cover TEXT, chapters TEXT, directory TEXT, tags TEXT, subtitle TEXT, title TEXT, id TEXT);',
        );
        db.execute(
          "INSERT INTO comics VALUES (1234, '[\"a\",\"b\"]', 17, 'cover.jpg', 'null', 'folder', '[\"tag\",\"\"]', 'author', 'title', 'id');",
        );
        final comic = localComicFromRow(
          db.select('SELECT * FROM comics;').single,
        );
        expect(comic.id, 'id');
        expect(comic.title, 'title');
        expect(comic.subtitle, 'author');
        expect(comic.tags, ['tag', '']);
        expect(comic.directory, 'folder');
        expect(comic.cover, 'cover.jpg');
        expect(comic.comicType.value, 17);
        expect(comic.chapters, isNull);
        expect(comic.downloadedChapters, ['a', 'b']);
        expect(comic.createdAt.millisecondsSinceEpoch, 1234);
        db.execute("UPDATE comics SET tags = 'invalid';");
        expect(
          () => localComicFromRow(db.select('SELECT * FROM comics;').single),
          throwsFormatException,
        );
      } finally {
        db.dispose();
      }
    },
  );
}
