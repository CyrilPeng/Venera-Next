import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/page_order_migration.dart';

void main() {
  late List<int> restored;
  var chapter = 2;
  var cancelled = false;
  setUp(() {
    restored = [];
    chapter = 2;
    cancelled = false;
  });
  ReaderPageOrderMigration create(
    Future<MigratedReaderPosition?> Function() migrate, {
    int? initialPage = 4,
  }) => ReaderPageOrderMigration(
    migrate: migrate,
    initialChapter: 2,
    initialPage: initialPage,
    currentChapter: () => chapter,
    displayPage: (page) => (page + 1) ~/ 2,
    restorePage: restored.add,
  );
  const mapping = MigratedReaderPosition(
    chapter: 2,
    previousPage: 4,
    imagePage: 8,
  );

  test('cancelled wait retains original mapping for a later view', () async {
    var calls = 0;
    final gate = Completer<MigratedReaderPosition?>();
    final migration = create(() {
      calls++;
      return gate.future;
    });
    final old = migration.prepare(isCancelled: () => cancelled);
    cancelled = true;
    gate.complete(mapping);
    await old;
    expect(restored, isEmpty);
    cancelled = false;
    await migration.prepare(isCancelled: () => cancelled);
    await migration.prepare(isCancelled: () => cancelled);
    expect(calls, 1);
    expect(restored, [4]);
  });

  test('overlapping views share migration and restore only once', () async {
    var calls = 0;
    final gate = Completer<MigratedReaderPosition?>();
    final migration = create(() {
      calls++;
      return gate.future;
    });
    final first = migration.prepare(isCancelled: () => false);
    final second = migration.prepare(isCancelled: () => false);
    gate.complete(mapping);
    await Future.wait([first, second]);
    expect(calls, 1);
    expect(restored, [4]);
  });

  for (final synchronous in [false, true]) {
    test('migration failures permit retry; synchronous=$synchronous', () async {
      var calls = 0;
      final error = StateError('migration failed');
      final migration = create(() {
        if (++calls == 1) {
          if (synchronous) throw error;
          return Future.error(error);
        }
        return Future.value(mapping);
      });
      await expectLater(
        migration.prepare(isCancelled: () => false),
        throwsA(same(error)),
      );
      await migration.prepare(isCancelled: () => false);
      expect(calls, 2);
      expect(restored, [4]);
    });
  }

  for (final reason in [
    'chapter changed',
    'different initial page',
    'missing history',
  ]) {
    test('does not restore when $reason', () async {
      final gate = Completer<MigratedReaderPosition?>();
      final migration = create(
        () => gate.future,
        initialPage: reason == 'different initial page' ? 7 : 4,
      );
      final pending = migration.prepare(isCancelled: () => false);
      if (reason == 'chapter changed') chapter = 3;
      gate.complete(reason == 'missing history' ? null : mapping);
      await pending;
      chapter = 2;
      await migration.prepare(isCancelled: () => false);
      expect(restored, isEmpty);
    });
  }

  test('pre-cancelled view never starts migration', () async {
    var calls = 0;
    final migration = create(() async {
      calls++;
      return mapping;
    });
    await migration.prepare(isCancelled: () => true);
    expect(calls, 0);
    await migration.prepare(isCancelled: () => false);
    expect(calls, 1);
    expect(restored, [4]);
  });
}
