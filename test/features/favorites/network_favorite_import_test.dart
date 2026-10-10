import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/favorites/network_favorite_import.dart';
import 'package:venera_next/features/favorites/network_favorite_import_dialog.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/features/favorites/favorite_models.dart';
import 'package:venera_next/features/favorites/favorite_actions.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/selection_operation.dart';

import '../../components/sidebar_presentation_test.dart'
    show pumpSidebar, settleSidebarWork;

Comic comic(String id) => Comic(id, '', id, null, null, '', 'test', null, null);
FavoriteItem item(String id) => FavoriteItem(
  id: id,
  name: id,
  coverPath: '',
  author: '',
  type: const ComicType(2),
  tags: [],
);

class _ImportSource extends Fake implements ComicSource {
  _ImportSource(this.favoriteData);
  @override
  final FavoriteData favoriteData;
  @override
  String get key => 'test';
  @override
  String get name => 'Synthetic favorites';
  @override
  int get intKey => key.hashCode;
}

class _ImportManager extends Fake implements LocalFavoritesManager {
  int commits = 0;
  int publications = 0;
  @override
  int get connectionGeneration => 1;
  @override
  bool existsFolder(String folder) => false;
  @override
  Future<NetworkFavoriteImportCommit> importNetworkFavorites(
    String folder,
    String source,
    String folderId,
    List<FavoriteItem> items, {
    required bool oldToNew,
    void Function()? checkActive,
    int? generation,
  }) async {
    checkActive?.call();
    commits++;
    return NetworkFavoriteImportCommit(folder, items);
  }

  @override
  Future<void> publishNetworkFavoriteImport(
    NetworkFavoriteImportCommit result,
  ) async {
    publications++;
  }
}

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
  App.dataPath = Directory.systemTemp.path;
  for (final replacement in ['source', 'database']) {
    testWidgets('R1 import entry rejects a replaced $replacement', (
      tester,
    ) async {
      final originalSources = List.of(ComicSource.all());
      final originalManager = _favoritesOwner;
      final manager = _ImportManager();
      final registry = SelectionTaskRegistry();
      final pending = Completer<Res<List<Comic>>>();
      var reads = 0;
      final data = FavoriteData(
        key: 'test',
        title: 'Synthetic favorites',
        multiFolder: false,
        loadNext: null,
        loadComic: (_, [folder]) {
          reads++;
          return pending.future;
        },
      );
      var source = _ImportSource(data);
      configureComicSourceRegistry(
        all: () => [source],
        find: (key) => key == 'test' ? source : null,
        fromIntKey: (key) => key == 'test'.hashCode ? source : null,
        isEmpty: () => false,
      );
      _favoritesOwner = manager;
      addTearDown(() async {
        if (!pending.isCompleted) pending.complete(const Res([]));
        await tester.pumpWidget(const SizedBox());
        await settleSidebarWork(tester, registry.closeAndWait);
        _favoritesOwner = originalManager;
        configureComicSourceRegistry(
          all: () => originalSources,
          find: (key) => originalSources.where((s) => s.key == key).firstOrNull,
          fromIntKey: (key) =>
              originalSources.where((s) => s.intKey == key).firstOrNull,
          isEmpty: () => originalSources.isEmpty,
        );
      });
      late BuildContext context;
      await tester.pumpWidget(
        _libraryView(
          MaterialApp(
            builder: (_, child) =>
                SelectionTasksScope(registry: registry, child: child!),
            home: Builder(
              builder: (value) {
                context = value;
                return const Scaffold();
              },
            ),
          ),
        ),
      );
      var ended = false;
      final work = importNetworkFolder(
        context,
        'test',
        5,
        null,
        null,
      ).then((_) => ended = true);
      await pumpSidebar(tester);
      expect(reads, 1);
      if (replacement == 'source') {
        source = _ImportSource(data);
      } else {
        await _replaceFavorites(tester, _ImportManager());
      }
      pending.complete(Res([comic('one')], subData: 5));
      await pumpSidebar(tester);
      expect(reads, 1);
      expect(manager.commits, 0);
      expect(manager.publications, 0);
      expect(find.text('Cancelled'), findsOneWidget);
      expect(ended, isFalse);
      await tester.tap(find.text('OK'));
      await settleSidebarWork(tester, () async => await work);
      expect(ended, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('R1 removed import waits for the real read before host closes', (
    tester,
  ) async {
    final registry = SelectionTaskRegistry();
    final pending = Completer<List<FavoriteItem>>();
    var commits = 0;
    await tester.pumpWidget(
      _libraryView(
        MaterialApp(
          builder: (_, child) =>
              SelectionTasksScope(registry: registry, child: child!),
          home: NetworkFavoriteImportDialog(
            collect: (_, _) => pending.future,
            commit: (_, _) {
              commits++;
              return NetworkFavoriteImportCommit('Target', []);
            },
            publish: (_) {},
          ),
        ),
      ),
    );
    await pumpSidebar(tester);
    await tester.pumpWidget(const SizedBox());
    var ended = false;
    final closing = registry.closeAndWait().then((_) => ended = true);
    await pumpSidebar(tester);
    final endedEarly = ended;
    pending.complete([item('one')]);
    await settleSidebarWork(tester, () async => await closing);
    expect(endedEarly, isFalse);
    expect(commits, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'R1 import keeps its original callbacks across widget replacement',
    (tester) async {
      final pending = Completer<List<FavoriteItem>>();
      var oldCommits = 0;
      var newCommits = 0;
      final registry = SelectionTaskRegistry();
      Widget app(NetworkFavoriteImportDialog child) => _libraryView(
        MaterialApp(
          builder: (_, page) =>
              SelectionTasksScope(registry: registry, child: page!),
          home: child,
        ),
      );
      await tester.pumpWidget(
        app(
          NetworkFavoriteImportDialog(
            collect: (_, _) => pending.future,
            commit: (_, _) {
              oldCommits++;
              return NetworkFavoriteImportCommit('Old', []);
            },
            publish: (_) {},
          ),
        ),
      );
      await pumpSidebar(tester);
      await tester.pumpWidget(
        app(
          NetworkFavoriteImportDialog(
            collect: (_, _) async => [],
            commit: (_, _) {
              newCommits++;
              return NetworkFavoriteImportCommit('New', []);
            },
            publish: (_) {},
          ),
        ),
      );
      pending.complete([item('one')]);
      await pumpSidebar(tester);
      expect(oldCommits, 0);
      expect(newCommits, 0);
      await tester.pumpWidget(const SizedBox());
      await settleSidebarWork(tester, registry.closeAndWait);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'committed import publishes after its dialog is forcibly unmounted',
    (tester) async {
      final pending = Completer<NetworkFavoriteImportCommit>();
      var publications = 0;
      await tester.pumpWidget(
        _libraryView(
          MaterialApp(
            home: NetworkFavoriteImportDialog(
              collect: (_, progress) async => [item('one')],
              commit: (_, scope) => pending.future,
              publish: (_) async {
                publications++;
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      pending.complete(NetworkFavoriteImportCommit('Target', [item('one')]));
      await tester.pump();
      expect(publications, 1);
      expect(tester.takeException(), isNull);
    },
  );
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
    'R1 cancellation during prefetch drains the real request and keeps late error',
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
      var ended = false;
      Object? error;
      final result = collect(data, scope).then<void>(
        (_) => ended = true,
        onError: (Object failure) {
          error = failure;
          ended = true;
        },
      );
      scope.cancel();
      await Future<void>.delayed(Duration.zero);
      final endedEarly = ended;
      final late = StateError('late');
      pending.completeError(late);
      await result;
      expect(endedEarly, isFalse);
      expect(error, same(late));
      expect(calls, 1);
      scope.dispose();
    },
  );
  for (final kind in [FailureKind.cancelled, FailureKind.unsupported]) {
    test(
      'R1 structured $kind favorite reads retain details without retries',
      () async {
        var calls = 0;
        final failure = OperationFailure(message: 'source result', kind: kind);
        final data = FavoriteData(
          key: 'test',
          title: '',
          multiFolder: true,
          loadNext: null,
          loadComic: (_, [folder]) async {
            calls++;
            return Res.failure(failure);
          },
        );
        final scope = RequestScope();
        addTearDown(scope.dispose);
        await expectLater(collect(data, scope), throwsA(same(failure)));
        expect(calls, 1);
      },
    );
  }
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
        _libraryView(
          MaterialApp(
            home: NetworkFavoriteImportDialog(
              collect: (_, progress) async {
                collections++;
                return [item('one')];
              },
              commit: (items, scope) {
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
      _libraryView(
        MaterialApp(
          home: NetworkFavoriteImportDialog(
            collect: (_, progress) async => [item('one')],
            commit: (_, scope) => throw StateError('SQL failed'),
            publish: (_) {
              publications++;
            },
          ),
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
        _libraryView(
          MaterialApp(navigatorKey: navigator, home: const Scaffold()),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => NetworkFavoriteImportDialog(
            publish: (_) {},
            collect: (_, progress) => pending.future,
            commit: (_, scope) {
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
        _libraryView(
          MaterialApp(
            home: NetworkFavoriteImportDialog(
              publish: (_) {},
              collect: (value, progress) {
                scope = value;
                return pending.future;
              },
              commit: (_, scope) {
                commits++;
                return NetworkFavoriteImportCommit('Target', [item('one')]);
              },
            ),
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
      _libraryView(
        MaterialApp(
          home: NetworkFavoriteImportDialog(
            publish: (_) {},
            collect: (_, progress) async => throw StateError('offline'),
            commit: (_, scope) {
              commits++;
              return NetworkFavoriteImportCommit('Target', [item('one')]);
            },
          ),
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

Widget? _libraryChild;
LocalFavoritesManager? _favoritesOwner;
LocalFavoritesManager _favoritesForView() =>
    _favoritesOwner ??= LocalFavoritesManager.independent();
Widget _libraryView(Widget child) {
  _libraryChild = child;
  return FavoritesScope(manager: _favoritesForView(), child: child);
}

Future<void> _replaceFavorites(
  WidgetTester tester,
  LocalFavoritesManager manager,
) async {
  _favoritesOwner = manager;
  await tester.pumpWidget(_libraryView(_libraryChild!));
}
