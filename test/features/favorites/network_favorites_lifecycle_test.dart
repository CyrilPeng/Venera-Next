import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/favorites/network_favorites_page.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/network/cache.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';

FavoriteData data({
  required Future<Res<Map<String, String>>> Function() load,
  Future<Res<bool>> Function(String)? add,
}) => FavoriteData(
  key: 'test',
  title: 'Remote',
  multiFolder: true,
  loadComic: null,
  loadNext: null,
  loadFolders: ([id]) => load(),
  addFolder: add,
);

void main() {
  tearDown(() => NetworkCacheManager().clear());
  testWidgets(
    'folder loading starts once and late failure after disposal is contained',
    (tester) async {
      var calls = 0;
      final pending = Completer<Res<Map<String, String>>>();
      final source = data(
        load: () {
          calls++;
          return pending.future;
        },
      );
      Widget page() => MaterialApp(
        home: Scaffold(body: NetworkFavoritePage(source, showFolders: () {})),
      );
      await tester.pumpWidget(page());
      await tester.pumpWidget(page());
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox());
      pending.completeError(StateError('late'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('folder failure can retry successfully', (tester) async {
    var calls = 0;
    final source = data(
      load: () {
        if (++calls == 1) throw StateError('offline');
        return Future.value(const Res({'one': 'Recovered'}));
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NetworkFavoritePage(source, showFolders: () {})),
      ),
    );
    await tester.pumpAndSettle();
    tester.widget<NetworkError>(find.byType(NetworkError)).retry!();
    await tester.pumpAndSettle();
    expect(find.text('Recovered'), findsOneWidget);
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder removal sends the selected folder identity', (
    tester,
  ) async {
    final calls = <String>[];
    final source = FavoriteData(
      key: 'test',
      title: 'Remote',
      multiFolder: true,
      loadComic: (page, [folder]) async => const Res(<Comic>[]),
      loadNext: null,
      loadFolders: ([id]) async => const Res({'folder-id': 'Target folder'}),
      addOrDelFavorite: (id, folder, adding, favoriteId) async {
        calls.add(folder);
        expect(id, 'comic-id');
        expect(adding, isFalse);
        return const Res(true);
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NetworkFavoritePage(source, showFolders: () {})),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Target folder'));
    await tester.pumpAndSettle();
    final list = tester.widget<ComicList>(find.byType(ComicList));
    const comic = Comic(
      'Book',
      '',
      'comic-id',
      null,
      null,
      '',
      'test',
      null,
      null,
    );
    list.menuBuilder!(comic).single.onClick();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(calls, ['folder-id']);
    expect(tester.takeException(), isNull);
  });

  for (final success in [true, false]) {
    testWidgets(
      'delete after dialog dismissal success=$success does not pop replacement route',
      (tester) async {
        final pending = Completer<Res<bool>>();
        var calls = 0;
        var committed = 0;
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => confirmNetworkFavoriteDeletion(
                  context,
                  delete: () {
                    calls++;
                    return pending.future;
                  },
                  message: 'Delete?',
                  onCommitted: () => committed++,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Confirm'));
        await tester.tap(find.text('Confirm'));
        expect(calls, 1);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Replacement')),
          ),
        );
        await tester.pumpAndSettle();
        if (success) {
          pending.complete(const Res(true));
        } else {
          pending.completeError(StateError('late'));
        }
        await tester.pumpAndSettle();
        expect(committed, success ? 1 : 0);
        expect(find.text('Replacement'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'create failure resets busy and late success reloads live parent',
    (tester) async {
      var calls = 0;
      var loads = 0;
      final pending = Completer<Res<bool>>();
      final source = data(
        load: () async {
          loads++;
          return Res(loads > 1 ? {'new': 'New Folder'} : {});
        },
        add: (name) {
          expect(name, 'New Folder');
          if (++calls == 1) throw StateError('offline');
          return pending.future;
        },
      );
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(body: NetworkFavoritePage(source, showFolders: () {})),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create a folder'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'New Folder');
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      await tester.tap(find.text('Submit'));
      expect(calls, 2);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      pending.complete(const Res(true));
      await tester.pumpAndSettle();
      expect(find.text('New Folder'), findsOneWidget);
      expect(loads, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
