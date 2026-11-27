import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/comic_cover.dart';
import 'package:venera_next/network/request_scope.dart';

import '../support/cover_cache_fixture.dart';

Future<void> _disposeFixture(WidgetTester tester, CoverCacheFixture f) async {
  await tester.pumpWidget(const SizedBox());
  await f.manager.dispose();
  await f.cache.dispose();
  await tester.runAsync(() => f.root.delete(recursive: true));
}

void main() {
  testWidgets(
    'only covers inside the viewport refresh; scrolling cancels old requests',
    (tester) async {
      final entered = <String>[];
      final scopes = <String, RequestScope>{};
      final f = CoverCacheFixture(
        decode: false,
        autoDispose: false,
        metadata: (identity, scope) async {
          entered.add(identity.id);
          scopes[identity.id] = scope;
          await scope.whenCancelled;
          scope.check();
          return null;
        },
      );

      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                height: 200,
                child: ListView.builder(
                  controller: scroll,
                  itemExtent: 100,
                  cacheExtent: 500,
                  itemCount: 10,
                  itemBuilder: (_, index) => ComicCoverImage(
                    manager: f.manager,
                    sourceKey: 'source',
                    id: '$index',
                    url: f.url,
                    image: const AssetImage('unused'),
                    builder: (_) => Text('cover $index'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(entered, ['0', '1']);
        scroll.jumpTo(600);
        await tester.pump();
        expect(scopes['0']!.isCancelled, true);
        expect(scopes['1']!.isCancelled, true);

        expect(entered, ['0', '1', '6', '7']);
      } finally {
        await _disposeFixture(tester, f);
      }
    },
  );

  for (final mode in ['local', 'disabled', 'hidden']) {
    testWidgets('$mode covers do not start network metadata requests', (
      tester,
    ) async {
      final f = CoverCacheFixture(decode: false, autoDispose: false);
      await tester.pumpWidget(
        MaterialApp(
          home: TickerMode(
            enabled: mode != 'hidden',
            child: ComicCoverImage(
              manager: f.manager,
              sourceKey: mode == 'local' ? 'local' : 'source',
              id: 'comic',
              url: f.url,
              enabled: mode != 'disabled',
              image: const AssetImage('unused'),
              builder: (_) => const Text('cover'),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(f.metadataCalls, 0);
      await _disposeFixture(tester, f);
    });
  }
}
