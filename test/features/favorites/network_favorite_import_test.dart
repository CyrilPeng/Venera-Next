import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/favorites/network_favorite_import.dart';
import 'package:venera_next/features/favorites/network_favorite_import_dialog.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/features/favorites/favorite_models.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/request_scope.dart';

Comic comic(String id) => Comic(id, '', id, null, null, '', 'test', null, null);
FavoriteItem item(String id) => FavoriteItem(
  id: id,
  name: id,
  coverPath: '',
  author: '',
  type: const ComicType(2),
  tags: [],
);
Future<List<FavoriteItem>> collect(
  FavoriteData data,
  RequestScope scope, {
  int limit = 10,
}) => collectNetworkFavorites(
  data: data,
  sourceKey: 'test',
  folderId: 'remote',
  pageLimit: limit,
  scope: scope,
  exists: (_) => false,
  onProgress: (_) {},
);
void main() {
  test(
    'oldest-first initial page is clamped and duplicates collapse',
    () async {
      final pages = <int>[];
      final data = FavoriteData(
        key: 'test',
        title: '',
        multiFolder: true,
        isOldToNewSort: true,
        loadNext: null,
        loadComic: (page, [folder]) async {
          pages.add(page);
          return Res([comic('same')], subData: 2);
        },
      );
      final scope = RequestScope();
      addTearDown(scope.dispose);
      expect((await collect(data, scope)).map((e) => e.id), ['same']);
      expect(pages, [1, 1, 2]);
    },
  );
  test(
    'failed prefetch retries three times without publishing items',
    () async {
      var calls = 0;
      final data = FavoriteData(
        key: 'test',
        title: '',
        multiFolder: true,
        isOldToNewSort: true,
        loadNext: null,
        loadComic: (_, [folder]) async {
          calls++;
          return const Res.error('offline');
        },
      );
      final scope = RequestScope();
      addTearDown(scope.dispose);
      await expectLater(collect(data, scope), throwsStateError);
      expect(calls, 3);
    },
  );
  test(
    'cancellation during prefetch terminates waiting without further requests',
    () async {
      final pending = Completer<Res<List<Comic>>>();
      var calls = 0;
      final data = FavoriteData(
        key: 'test',
        title: '',
        multiFolder: true,
        isOldToNewSort: true,
        loadNext: null,
        loadComic: (_, [folder]) {
          calls++;
          return pending.future;
        },
      );
      final scope = RequestScope();
      final result = collect(data, scope);
      final assertion = expectLater(result, throwsA(isA<RequestCancelled>()));
      scope.cancel();
      await assertion;
      pending.completeError(StateError('late'));
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      scope.dispose();
    },
  );
  test(
    'repeated cursor is rejected instead of collecting indefinitely',
    () async {
      final data = FavoriteData(
        key: 'test',
        title: '',
        multiFolder: true,
        loadComic: null,
        loadNext: (cursor, [folder]) async =>
            Res([comic('one')], subData: 'same'),
      );
      final scope = RequestScope();
      addTearDown(scope.dispose);
      await expectLater(collect(data, scope), throwsFormatException);
    },
  );
  test(
    'network commit rolls back batch and preserves linked folder on SQL failure',
    () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      final repo = FavoritesRepository(db)..initializeMetadata();
      repo.createFolder('Target');
      repo.linkFolderToNetwork('Target', 'test', 'remote');
      db.execute(
        "CREATE TRIGGER fail_insert BEFORE INSERT ON Target WHEN new.id = 'bad' BEGIN SELECT RAISE(ABORT, 'injected'); END;",
      );
      List<FavoriteItem> commit() => commitNetworkFavorites(
        repo,
        folder: 'Target',
        source: 'test',
        folderId: 'remote',
        items: [item('good'), item('bad')],
        append: true,
        oldToNew: false,
        translateTags: (_) => '',
      );
      expect(commit, throwsA(isA<SqliteException>()));
      expect(repo.getFolderComics('Target'), isEmpty);
      db.execute('DROP TRIGGER fail_insert');
      expect(commit(), hasLength(2));
      expect(commit(), isEmpty);
    },
  );
  test(
    'commit checks network ownership and creates no orphan folder on failure',
    () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      final repo = FavoritesRepository(db)..initializeMetadata();
      expect(
        () => commitNetworkFavorites(
          repo,
          folder: '',
          source: 'test',
          folderId: 'remote',
          items: [],
          append: true,
          oldToNew: false,
          translateTags: (_) => '',
        ),
        throwsArgumentError,
      );
      repo.createFolder('Other');
      expect(
        () => commitNetworkFavorites(
          repo,
          folder: 'Other',
          source: 'test',
          folderId: 'remote',
          items: [],
          append: true,
          oldToNew: false,
          translateTags: (_) => '',
        ),
        throwsStateError,
      );
      // A reserved metadata table must not be adopted as a favorite folder.
      expect(
        () => commitNetworkFavorites(
          repo,
          folder: 'folder_sync',
          source: 'test',
          folderId: 'remote',
          items: [item('one')],
          append: true,
          oldToNew: false,
          translateTags: (_) => '',
        ),
        throwsA(isA<SqliteException>()),
      );
      expect(repo.findLinked('folder_sync'), (null, null));
    },
  );
  test('new folder and link roll back if metadata insertion fails', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    final repo = FavoritesRepository(db)..initializeMetadata();
    db.execute(
      "CREATE TRIGGER fail_link BEFORE INSERT ON folder_sync BEGIN SELECT RAISE(ABORT, 'injected'); END;",
    );
    expect(
      () => commitNetworkFavorites(
        repo,
        folder: 'New',
        source: 'test',
        folderId: 'remote',
        items: [item('one')],
        append: true,
        oldToNew: false,
        translateTags: (_) => '',
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(repo.folderNames(), isEmpty);
    expect(repo.findLinked('New'), (null, null));
  });
  testWidgets(
    'publication failure retains SQL count and refresh never reimports',
    (tester) async {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      final repo = FavoritesRepository(db)..initializeMetadata();
      var collections = 0;
      var commits = 0;
      var publications = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: NetworkFavoriteImportDialog(
            collect: (_, progress) async {
              collections++;
              return [item('one')];
            },
            commit: (items) {
              commits++;
              return NetworkFavoriteImportCommit(
                'Target',
                commitNetworkFavorites(
                  repo,
                  folder: 'Target',
                  source: 'test',
                  folderId: 'remote',
                  items: items,
                  append: true,
                  oldToNew: false,
                  translateTags: (_) => '',
                ),
              );
            },
            publish: (result) {
              publications++;
              expect(result.count, 1);
              expect(repo.getFolderComics('Target'), hasLength(1));
              if (publications < 3) throw StateError('refresh unavailable');
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Finished'), findsOneWidget);
      expect(find.textContaining('Imported 1 comics'), findsOneWidget);
      expect(find.text('Error'), findsNothing);
      expect(find.textContaining('refresh unavailable'), findsOneWidget);
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.textContaining('refresh unavailable'), findsOneWidget);
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.textContaining('refresh unavailable'), findsNothing);
      expect(find.text('Refresh'), findsNothing);
      expect(collections, 1);
      expect(commits, 1);
      expect(publications, 3);
      expect(repo.getFolderComics('Target'), hasLength(1));
    },
  );

  testWidgets('commit failure never publishes or offers refresh', (
    tester,
  ) async {
    var publications = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: NetworkFavoriteImportDialog(
          collect: (_, progress) async => [item('one')],
          commit: (_) => throw StateError('SQL failed'),
          publish: (_) {
            publications++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Error'), findsOneWidget);
    expect(find.textContaining('Imported 0 comics'), findsOneWidget);
    expect(find.text('Refresh'), findsNothing);
    expect(publications, 0);
  });

  test('commit result snapshots identities independently of mutable items', () {
    final value = item('original');
    final result = NetworkFavoriteImportCommit('Target', [value]);
    value.id = 'changed';
    expect(result.identities, [('original', 2)]);
    expect(() => result.identities.clear(), throwsUnsupportedError);
  });

  testWidgets(
    'route pop cancels before its exit animation disposes the widget',
    (tester) async {
      final pending = Completer<List<FavoriteItem>>();
      final navigator = GlobalKey<NavigatorState>();
      var commits = 0;
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const Scaffold()),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => NetworkFavoriteImportDialog(
            publish: (_) {},
            collect: (_, progress) => pending.future,
            commit: (_) {
              commits++;
              return NetworkFavoriteImportCommit('Target', [item('one')]);
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      navigator.currentState!.pop();
      pending.complete([item('one')]);
      await tester.pump();
      expect(commits, 0);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dismissal before collection completes prevents commit and late navigation',
    (tester) async {
      final pending = Completer<List<FavoriteItem>>();
      var commits = 0;
      late RequestScope scope;
      await tester.pumpWidget(
        MaterialApp(
          home: NetworkFavoriteImportDialog(
            publish: (_) {},
            collect: (value, progress) {
              scope = value;
              return pending.future;
            },
            commit: (_) {
              commits++;
              return NetworkFavoriteImportCommit('Target', [item('one')]);
            },
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox());
      pending.complete([item('one')]);
      await tester.pump();
      expect(scope.isCancelled, isTrue);
      expect(commits, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('collection failure never calls commit and remains visible', (
    tester,
  ) async {
    var commits = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: NetworkFavoriteImportDialog(
          publish: (_) {},
          collect: (_, progress) async => throw StateError('offline'),
          commit: (_) {
            commits++;
            return NetworkFavoriteImportCommit('Target', [item('one')]);
          },
        ),
      ),
    );
    await tester.pump();
    expect(commits, 0);
    expect(find.textContaining('offline'), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
