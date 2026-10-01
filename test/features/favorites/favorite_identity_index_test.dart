import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/favorites/favorite_identity_index.dart';

void main() {
  test('local commits override stale snapshots in either direction', () {
    final index = FavoriteIdentityIndex();
    final generation = index.beginRefresh();
    index.setCount(('added', 1), 1);
    index.setCount(('removed', 1), 0);
    index.setCount(('shared', 1), 1);
    expect(
      index.completeRefresh(generation, {
        ('removed', 1): 1,
        ('shared', 1): 2,
        ('existing', 2): 1,
      }),
      isTrue,
    );
    expect(index.length, 3);
    expect(index.contains('added', 1), isTrue);
    expect(index.contains('removed', 1), isFalse);
    expect(index.contains('shared', 1), isTrue);
    expect(index.contains('existing', 2), isTrue);
  });

  test('new snapshots and clear invalidate older completion and failure', () {
    final index = FavoriteIdentityIndex();
    final older = index.beginRefresh();
    final newer = index.beginRefresh();
    index.setCount(('added', 1), 1);
    index.failRefresh(older);
    expect(index.completeRefresh(older, {('stale', 1): 1}), isFalse);
    expect(index.completeRefresh(newer, {}), isTrue);
    expect(index.contains('added', 1), isTrue);
    final closing = index.beginRefresh();
    index.clear();
    final reopened = index.beginRefresh();
    expect(index.completeRefresh(closing, {('stale', 1): 1}), isFalse);
    expect(index.completeRefresh(reopened, {('fresh', 2): 1}), isTrue);
    expect(index.length, 1);
    expect(index.contains('fresh', 2), isTrue);
  });

  test('failed refresh preserves committed state and supports retry', () {
    final index = FavoriteIdentityIndex();
    index.setCount(('existing', 1), 1);
    final generation = index.beginRefresh();
    index.setCount(('added', 2), 1);
    index.failRefresh(generation);
    expect(index.length, 2);
    expect(index.completeRefresh(generation, {}), isFalse);
    expect(
      index.completeRefresh(index.beginRefresh(), {('added', 2): 1}),
      isTrue,
    );
    expect(index.length, 1);
  });
}
