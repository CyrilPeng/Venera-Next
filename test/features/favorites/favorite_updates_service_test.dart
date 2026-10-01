import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorite_updates_service.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';

void main() {
  test(
    'failed refresh preserves the previous folder snapshot and clear drops it',
    () {
      final db = sqlite3.openInMemory();
      final repository = FavoritesRepository(db)..initializeMetadata();
      Object? selected = 'first';
      final service = FavoriteUpdatesService(
        repository: () => repository,
        folder: () => selected,
      );
      try {
        repository.createFolder('first');
        repository.prepareForFollowUpdates('first', clearData: false);
        db.execute(
          "INSERT INTO first (id, type, has_new_update) VALUES ('same', 1, 1), ('same', 2, 0);",
        );
        service.refresh();
        expect(service.contains('same', 1), isTrue);
        expect(service.contains('same', 2), isFalse);
        repository.createFolder('broken');
        selected = 'broken';
        expect(service.refresh, throwsA(isA<SqliteException>()));
        expect(service.contains('same', 1), isFalse);
        selected = 'first';
        expect(service.contains('same', 1), isTrue);
        service.clear();
        expect(service.contains('same', 1), isFalse);
        service.refresh();
        expect(service.contains('same', 1), isTrue);
        selected = 123;
        service.refresh();
        selected = 'first';
        expect(service.contains('same', 1), isFalse);
      } finally {
        db.dispose();
      }
    },
  );
}
