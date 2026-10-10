import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/favorites/favorites_scope.dart';

void main() {
  testWidgets('view replacement invalidates only its original store binding', (
    tester,
  ) async {
    final defaultStore = LocalFavoritesManager.cache;
    final first = LocalFavoritesManager.independent();
    final second = LocalFavoritesManager.independent();
    final replacement = LocalFavoritesManager.independent();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    addTearDown(replacement.dispose);
    late FavoriteStoreBinding original, other;
    var capture = true;
    final left = Builder(
      builder: (context) {
        if (capture) original = FavoritesScope.capture(context);
        return const SizedBox();
      },
    );
    final right = Builder(
      builder: (context) {
        if (capture) other = FavoritesScope.capture(context);
        return const SizedBox();
      },
    );
    Widget view(LocalFavoritesManager manager) => Row(
      textDirection: TextDirection.ltr,
      children: [
        FavoritesScope(manager: manager, child: left),
        FavoritesScope(manager: second, child: right),
      ],
    );
    await tester.pumpWidget(view(first));
    expect(original.manager, same(first));
    expect(other.manager, same(second));
    capture = false;
    await tester.pumpWidget(view(replacement));
    expect(original.isCurrent, isFalse);
    expect(other.isCurrent, isTrue);
    expect(LocalFavoritesManager.cache, same(defaultStore));
    await tester.pumpWidget(const SizedBox());
    // Removing a view does not dispose its borrowed store. Already admitted
    // work can drain; its own connection generation still guards database use.
    expect(other.manager, same(second));
    expect(other.isCurrent, isTrue);
  });
}
