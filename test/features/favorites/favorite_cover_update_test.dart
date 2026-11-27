import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/comic_type.dart';

import 'support/favorites_manager_fixture.dart';

void main() {
  test(
    'cover publication updates all captured references while preserving every other column',
    () async {
      await withFavoritesManager((manager) async {
        await manager.createFolder('A');
        await manager.createFolder('B');
        await manager.addComic('A', managerFavorite('comic'));
        await manager.addComic('B', managerFavorite('comic'));
        await manager.prepareTableForFollowUpdates('B');
        final db = sqlite3.open(manager.databasePath);
        try {
          final before = {
            for (final name in ['A', 'B'])
              name: Map<String, Object?>.from(
                db.select('SELECT * FROM "$name";').single,
              ),
          };
          final publish = manager.captureCoverUpdate('comic', ComicType.local);
          await publish('https://fixture.invalid/new.png', () {});
          for (final name in ['A', 'B']) {
            final row = Map<String, Object?>.from(
              db.select('SELECT * FROM "$name";').single,
            );
            final expected = {
              ...before[name]!,
              'cover_path': 'https://fixture.invalid/new.png',
            };
            expect(row, expected);
          }
        } finally {
          db.dispose();
        }
      });
    },
  );

  test(
    'a renamed folder remains the same target; a recreated folder cannot adopt the old write',
    () async {
      await withFavoritesManager((manager) async {
        await manager.createFolder('A');
        await manager.addComic('A', managerFavorite('comic'));
        final publish = manager.captureCoverUpdate('comic', ComicType.local);
        await manager.rename('A', 'Renamed');
        await manager.createFolder('A');
        await manager.addComic('A', managerFavorite('comic'));
        await publish('https://fixture.invalid/new.png', () {});
        expect(
          manager.getFolderComics('Renamed').single.cover,
          'https://fixture.invalid/new.png',
        );
        expect(manager.getFolderComics('A').single.cover, 'cover-comic.jpg');
      });
    },
  );

  test(
    'a deleted reference is not recreated by a late cover publication',
    () async {
      await withFavoritesManager((manager) async {
        await manager.createFolder('A');
        await manager.addComic('A', managerFavorite('comic'));
        final publish = manager.captureCoverUpdate('comic', ComicType.local);
        await manager.deleteComicWithId('A', 'comic', ComicType.local);
        await publish('https://fixture.invalid/new.png', () {});
        expect(manager.getFolderComics('A'), isEmpty);
      });
    },
  );

  test('a reopened database rejects the previous cover publisher', () async {
    await withFavoritesManager((manager) async {
      await manager.createFolder('A');
      await manager.addComic('A', managerFavorite('comic'));
      final publish = manager.captureCoverUpdate('comic', ComicType.local);
      await manager.closeAndWait();
      await manager.init();
      await expectLater(
        publish('https://fixture.invalid/new.png', () {}),
        throwsStateError,
      );
      expect(manager.getFolderComics('A').single.cover, 'cover-comic.jpg');
    });
  });
}
