import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/features/history/history_scope.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/favorites/favorite_metadata_update.dart';
import 'package:venera_next/features/favorites/favorite_models.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/favorites/local_favorites_page.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:window_manager/window_manager.dart';

import '../../components/sidebar_presentation_test.dart'
    show pumpSidebar, settleSidebarWork, sidebarCauses;

class _Navigator extends Navigator {
  const _Navigator({super.key, super.onGenerateRoute});
  @override
  NavigatorState createState() => _NavigatorState();
}

class _NavigatorState extends NavigatorState {
  bool fails = false;
  final failure = StateError('original metadata dialog removal failed');
  final failureStack = StackTrace.fromString('original metadata removal stack');
  final attempts = <Route<dynamic>>[];
  @override
  void removeRoute<T extends Object?>(Route<T> route, [T? result]) {
    attempts.add(route);
    if (fails) Error.throwWithStackTrace(failure, failureStack);
    super.removeRoute(route, result);
  }
}

const _key = 'synthetic-metadata';
FavoriteItem _comic(String id) => FavoriteItem.withTime(
  id: id,
  name: id,
  author: 'old author',
  coverPath: '',
  type: ComicType(_key.hashCode),
  tags: ['old tag'],
  time: '2020-01-02 03:04:05',
);
ComicDetails _details(String id) => ComicDetails.fromJson({
  'title': 'updated $id',
  'cover': '',
  'sourceKey': _key,
  'comicId': id,
  'tags': {
    'author': ['new author'],
    'Artist': ['not a tag'],
    'TIME': ['not a tag'],
    'genre': ['first', 'second'],
  },
});

class _Source extends Fake implements ComicSource {
  @override
  String get key => _key;
  @override
  String get name => 'Synthetic metadata source';
  @override
  int get intKey => _key.hashCode;
  @override
  bool get enableTagsTranslate => false;
  @override
  FavoriteData? get favoriteData => null;
  final requests = <String>[];
  final scopes = <RequestScope?>[];
  Future<Res<ComicDetails>> Function(String)? loading;
  @override
  LoadComicFunc get loadComicInfo => (id) async {
    requests.add(id);
    scopes.add(RequestScope.current);
    return loading == null ? Res(_details(id)) : await loading!(id);
  };
}

class _History extends Fake implements HistoryManager {
  @override
  History? find(String id, ComicType type) => null;
}

class _Manager extends Fake implements LocalFavoritesManager {
  @override
  int connectionGeneration = 1;
  final contents = {
    'Original': [_comic('A'), _comic('B')],
    'Other': [_comic('X')],
  };
  final listeners = <VoidCallback>{};
  final writes = <(String, FavoriteItem)>[];
  @override
  List<String> get folderNames => contents.keys.toList();
  @override
  bool existsFolder(String name) => contents.containsKey(name);
  @override
  int folderComics(String name) => contents[name]?.length ?? 0;
  @override
  List<FavoriteItem> getFolderComics(String name, {int? limit}) =>
      contents[name]?.map((item) => item.detached()).toList() ?? [];
  @override
  (String?, String?) findLinked(String folder) => (null, null);
  @override
  void addListener(VoidCallback listener) => listeners.add(listener);
  @override
  void removeListener(VoidCallback listener) => listeners.remove(listener);
  @override
  Future<void> updateInfo(
    String folder,
    FavoriteItem item, {
    required int generation,
    void Function()? checkActive,
  }) => AppDataOperations.instance.access(() async {
    if (generation != connectionGeneration) throw const SelectionCancelled();
    checkActive?.call();
    writes.add((folder, item.detached()));
    final index = contents[folder]!.indexWhere((old) => old == item);
    if (index >= 0) contents[folder]![index] = item.detached();
    for (final listener in listeners.toList()) {
      listener();
    }
  });
}

class _Host {
  _Host({this.real = false, this.window = false});
  final bool real;
  final bool window;
  LocalFavoritesManager? actual;
  int exits = 0;
  final manager = _Manager();
  final originalSource = _Source();
  late _Source source = originalSource;
  final originalRegistry = SelectionTaskRegistry();
  late SelectionTaskRegistry registry = originalRegistry;
  final content = ValueNotifier<Widget>(const SizedBox());
  bool allowed = true;
  late WidgetTester tester;
  _NavigatorState get navigator =>
      appNavigation.rootNavigatorKey.currentState! as _NavigatorState;
  Widget local([String folder = 'Original']) => LocalFavoritesPage(
    folder: folder,
    showFolders: () {},
    onFolderSelected: (_, _) {},
    updateFolderList: () {},
  );
  Widget app() => _libraryView(
    MaterialApp(
      builder: (_, _) {
        Widget child = _Navigator(
          key: appNavigation.rootNavigatorKey,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              body: ValueListenableBuilder<Widget>(
                valueListenable: content,
                builder: (_, value, _) => value,
              ),
            ),
          ),
        );
        if (window) child = WindowFrame(child, onExit: () => exits++);
        return SelectionTasksScope(
          registry: registry,
          child: NavigationAdmission(
            allowsNavigation: () => allowed,
            child: child,
          ),
        );
      },
    ),
  );
  Future<void> mount(WidgetTester value) async {
    tester = value;
    final previousManager = _favoritesOwner;
    final previousHistory = _historyOwner;
    final previousData = App.dataPath;
    final previousCache = App.cachePath;
    final previousSources = ComicSource.all();
    final checkpoint = appdata.captureImportCheckpoint();
    final root = Directory.systemTemp.createTempSync('venera-metadata-owned-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    _favoritesOwner = manager;
    _historyOwner = _History();
    configureComicSourceRegistry(
      all: () => [source],
      find: (key) => key == _key ? source : null,
      fromIntKey: (key) => key == _key.hashCode ? source : null,
      isEmpty: () => false,
    );
    appdata.settings['language'] = 'en-US';
    appdata.settings['favoritesDisplayMode'] = 'list';
    appdata.implicitData['local_favorites_read_filter'] = 'All';
    registerShowMessageHandler((_, _) {});
    content.value = local();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await pumpSidebar(tester);
      for (final tasks in {registry, originalRegistry}) {
        await settleSidebarWork(tester, tasks.closeAndWait);
      }
      await tester.runAsync(() async {
        await AppDataOperations.instance.run(() async {});
        await actual?.closeAndWait();
        await appdata.restoreImportCheckpoint(checkpoint, persist: false);
      });
      configureComicSourceRegistry(
        all: () => previousSources,
        find: (key) => previousSources.where((s) => s.key == key).firstOrNull,
        fromIntKey: (key) =>
            previousSources.where((s) => s.intKey == key).firstOrNull,
        isEmpty: () => previousSources.isEmpty,
      );
      _favoritesOwner = previousManager;
      _historyOwner = previousHistory;
      App.dataPath = previousData;
      App.cachePath = previousCache;
      content.dispose();
      final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
      final owned = root.resolveSymbolicLinksSync();
      expect(p.isWithin(temporary, owned), isTrue);
      expect(p.basename(owned), startsWith('venera-metadata-owned-'));
      root.deleteSync(recursive: true);
    });
    if (real) {
      _favoritesOwner = null;
      final database = actual = _favoritesForView();
      appdata.settings['followUpdatesFolder'] = null;
      await tester.runAsync(() async {
        await database.init();
        for (final entry in manager.contents.entries) {
          await database.createFolder(entry.key);
          await database.prepareTableForFollowUpdates(
            entry.key,
            clearData: false,
          );
          for (var i = 0; i < entry.value.length; i++) {
            await database.addComic(entry.key, entry.value[i], i);
          }
        }
        appdata.settings['followUpdatesFolder'] = 'Original';
        database.refreshUpdateIds();
      });
    }
    await tester.pumpWidget(app());
    await pumpSidebar(tester);
  }

  VoidCallback menu() => tester
      .widgetList<MenuButton>(find.byType(MenuButton))
      .expand((button) => button.entries)
      .singleWhere((entry) => entry.text == 'Update Comics Info')
      .onClick;
  Future<void> open() async {
    menu()();
    await pumpSidebar(tester);
  }

  Future<_Manager?> retire(String state) async {
    _Manager? replacement;
    switch (state) {
      case 'folder':
        content.value = local('Other');
      case 'removed':
        content.value = const Text('Replacement content');
      case 'covered':
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Newer route')),
          ),
        );
      case 'frozen':
        allowed = false;
      case 'registry':
        registry = SelectionTaskRegistry();
        await tester.pumpWidget(app());
      case 'manager':
        await _replaceFavorites(tester, replacement = _Manager());
      case 'connection':
        manager.connectionGeneration++;
      case 'path':
        App.dataPath = '${App.dataPath}/replacement';
    }
    await pumpSidebar(tester);
    return replacement;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  App.dataPath = Directory.systemTemp.path;
  App.cachePath = Directory.systemTemp.path;
  setUp(() {
    final muted = Log.isMuted;
    Log.isMuted = true;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (_) async => false,
    );
    addTearDown(() {
      Log.isMuted = muted;
      messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      );
    });
  });

  testWidgets(
    'metadata preserves mapping, identity and original favorite time',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      await host.open();
      expect(host.manager.writes, hasLength(2));
      final (folder, item) = host.manager.writes.first;
      expect(folder, 'Original');
      expect(item.id, 'A');
      expect(item.name, 'updated A');
      expect(item.author, 'new author');
      expect(item.tags, ['genre:first', 'genre:second']);
      expect(item.time, '2020-01-02 03:04:05');
      expect(find.text('Finished'), findsOneWidget);
    },
  );

  for (final state in [
    'folder',
    'removed',
    'covered',
    'frozen',
    'registry',
    'manager',
    'connection',
    'path',
  ]) {
    testWidgets('old metadata menu rejects retired $state', (tester) async {
      final host = _Host();
      await host.mount(tester);
      final retained = host.menu();
      await host.retire(state);
      retained();
      await pumpSidebar(tester);
      expect(host.originalSource.requests, isEmpty);
      expect(find.byType(ContentDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final state in ['folder', 'removed', 'manager', 'connection', 'path']) {
    testWidgets('late metadata response cannot write after $state retires', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      final release = Completer<void>();
      host.source.loading = (id) async {
        await release.future;
        return Res(_details(id));
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await host.open();
      final replacement = await host.retire(state);
      release.complete();
      await pumpSidebar(tester);
      expect(host.manager.writes, isEmpty);
      expect(replacement?.writes ?? [], isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'metadata cancellation reaches the original request and drains it',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      final release = Completer<void>();
      host.source.loading = (id) async {
        await release.future;
        return Res(_details(id));
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await host.open();
      expect(host.source.scopes, isNotEmpty);
      expect(host.source.scopes.every((scope) => scope != null), isTrue);
      await tester.tap(find.widgetWithText(Button, 'Cancel'));
      await tester.pump();
      expect(host.source.scopes.every((scope) => scope!.isCancelled), isTrue);
      var closed = false;
      final closing = host.originalRegistry.closeAndWait().then(
        (_) => closed = true,
      );
      await tester.pump();
      expect(closed, isFalse);
      release.complete();
      await settleSidebarWork(tester, () => closing);
      expect(host.manager.writes, isEmpty);
    },
  );

  testWidgets('original application close joins accepted metadata reads', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    final release = Completer<void>();
    host.source.loading = (id) async {
      await release.future;
      return Res(_details(id));
    };
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    await host.open();
    var closed = false;
    final closing = host.originalRegistry.closeAndWait().then(
      (_) => closed = true,
    );
    await pumpSidebar(tester);
    expect(closed, isFalse);
    release.complete();
    await settleSidebarWork(tester, () => closing);
    expect(host.manager.writes, isEmpty);
    expect(find.byType(ContentDialog), findsNothing);
  });

  testWidgets(
    'metadata retry never switches to a replacement source instance',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      final release = Completer<void>();
      host.source.loading = (_) async {
        await release.future;
        throw StateError('original source failed');
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await host.open();
      host.source = _Source();
      release.complete();
      await pumpSidebar(tester);
      expect(host.source.requests, isEmpty);
      expect(host.manager.writes, isEmpty);
    },
  );

  testWidgets('covered metadata cancel never closes a newer route', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    final release = Completer<void>();
    host.source.loading = (id) async {
      await release.future;
      return Res(_details(id));
    };
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    await host.open();
    final cancel = tester
        .widget<Button>(find.widgetWithText(Button, 'Cancel'))
        .onPressed;
    await host.retire('covered');
    Function.apply(cancel, const []);
    await pumpSidebar(tester);
    expect(find.text('Newer route'), findsOneWidget);
    expect(
      host.source.scopes.any((scope) => scope?.isCancelled == true),
      isFalse,
    );
    release.complete();
    await pumpSidebar(tester);
  });

  testWidgets('empty metadata batch has a finite finished progress value', (
    tester,
  ) async {
    final host = _Host();
    host.manager.contents['Original'] = [];
    await host.mount(tester);
    await host.open();
    expect(tester.takeException(), isNull);
    expect(find.text('Finished'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      1,
    );
    expect(host.source.requests, isEmpty);
  });

  for (final sqlFails in [false, true]) {
    testWidgets(
      'real metadata preserves stored identity across reopening; failure=$sqlFails',
      (tester) async {
        final host = _Host(real: true);
        await host.mount(tester);
        final database = host.actual!;
        const otherType = ComicType(123456789);
        await tester.runAsync(() async {
          await database.addComic(
            'Original',
            _comic('A')..type = otherType,
            12,
          );
          await database.linkFolderToNetwork('Original', _key, 'remote-folder');
          await database.updateOrder(['Other', 'Original']);
        });
        final connection = sqlite3.open(database.databasePath);
        addTearDown(connection.dispose);
        connection.execute(
          'UPDATE "Original" SET has_new_update = 1, last_update_time = ?, last_check_time = ?, translated_tags = ?;',
          ['legacy: update', 12345, 'old translated tags'],
        );
        List<Map<String, Object?>> rows(String table) => connection
            .select('SELECT rowid, * FROM "$table" ORDER BY rowid;')
            .map((row) => Map<String, Object?>.from(row))
            .toList();
        final original = rows('Original');
        final other = rows('Other');
        final links = rows('folder_sync');
        final order = rows('folder_order');
        if (sqlFails) {
          connection.execute(
            'CREATE TRIGGER reject_metadata BEFORE UPDATE OF name ON "Original" WHEN old.id = \'A\' BEGIN SELECT RAISE(ABORT, \'metadata rejected\'); END;',
          );
        }
        await host.open();
        expect(host.source.requests, unorderedEquals(['A', 'B']));
        expect(find.text('Finished'), findsOneWidget);
        if (sqlFails) expect(find.text('Error: 1'), findsOneWidget);
        final expected = original.map((row) {
          if (row['type'] == otherType.value ||
              (sqlFails && row['id'] == 'A')) {
            return row;
          }
          return {
            ...row,
            'name': 'updated ${row['id']}',
            'author': 'new author',
            'cover_path': '',
            'tags': 'genre:first,genre:second',
          };
        }).toList();
        expect(rows('Original'), expected);
        expect(rows('Other'), other);
        expect(rows('folder_sync'), links);
        expect(rows('folder_order'), order);
        await tester.tap(find.widgetWithText(Button, 'OK'));
        await pumpSidebar(tester);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await database.closeAndWait();
          await database.init();
        });
        expect(rows('Original'), expected);
        expect(rows('Other'), other);
        expect(rows('folder_sync'), links);
        expect(rows('folder_order'), order);
        expect(
          database
              .getFolderComics('Original')
              .where((item) => item.type == otherType)
              .single
              .name,
          'A',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'real metadata committed notification failure does not repeat source or save',
    (tester) async {
      final host = _Host(real: true);
      await host.mount(tester);
      final database = host.actual!;
      final observer = StateError('metadata committed observer failure');
      var notifications = 0;
      void notify() {
        notifications++;
        throw observer;
      }

      database.addListener(notify);
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        if (identical(details.exception, observer)) throw observer;
        previous?.call(details);
      };
      try {
        await host.open();
      } finally {
        database.removeListener(notify);
        FlutterError.onError = previous;
      }
      expect(host.source.requests, unorderedEquals(['A', 'B']));
      expect(notifications, 2);
      expect(find.text('Error: 2'), findsOneWidget);
      expect(database.getFolderComics('Original').map((item) => item.name), [
        'updated A',
        'updated B',
      ]);
      await tester.tap(find.widgetWithText(Button, 'OK'));
      await pumpSidebar(tester);
      expect(host.source.requests, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'metadata removal failure and late source failures both survive cleanup retry',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      final release = Completer<void>();
      final lateFailure = StateError('late original metadata source failure');
      final navigator = host.navigator;
      host.source.loading = (_) async {
        await release.future;
        throw lateFailure;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        navigator.fails = false;
      });
      await host.open();
      final original = ModalRoute.of(
        tester.element(find.byType(ContentDialog)),
      )!;
      host.navigator.fails = true;
      Object? failure;
      var closed = false;
      final closing = host.originalRegistry.closeAndWait().then<void>(
        (_) => closed = true,
        onError: (Object error) {
          failure = error;
          closed = true;
        },
      );
      await pumpSidebar(tester);
      expect(closed, isFalse);
      expect(host.navigator.attempts, [original]);
      release.complete();
      await settleSidebarWork(tester, () => closing);
      await pumpSidebar(tester);
      expect(failure, isA<SelectionCleanupFailure>());
      final causes = sidebarCauses(failure!).toList();
      expect(causes, contains(same(host.navigator.failure)));
      expect(
        causes.whereType<FavoriteMetadataBatchFailure>().any(
          (batch) =>
              batch.failures.length == 2 &&
              batch.failures.every(
                (item) => identical(item.cause, lateFailure),
              ),
        ),
        isTrue,
      );
      expect(host.source.requests, hasLength(2));
      expect(find.byType(ContentDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      navigator.fails = false;
      await settleSidebarWork(tester, host.originalRegistry.closeAndWait);
      await pumpSidebar(tester);
      expect(host.navigator.attempts, [original, original]);
      expect(find.byType(ContentDialog), findsNothing);
      expect(host.source.requests, hasLength(2));
    },
  );

  for (final fail in [false, true]) {
    testWidgets(
      'original window drains metadata source completion; failure=$fail',
      (tester) async {
        final host = _Host(window: true);
        await host.mount(tester);
        final release = Completer<void>();
        final lateFailure = StateError('window metadata source failure');
        host.source.loading = (id) async {
          await release.future;
          if (fail) throw lateFailure;
          return Res(_details(id));
        };
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        await host.open();
        final window = tester.state(find.byType(WindowFrame)) as WindowListener;
        window.onWindowClose();
        await pumpSidebar(tester);
        expect(host.exits, 0);
        expect(host.source.scopes.every((scope) => scope!.isCancelled), isTrue);
        release.complete();
        await pumpSidebar(tester);
        if (fail) {
          expect(host.exits, 0);
          final failure = tester.takeException();
          expect(failure, isNotNull);
          expect(
            sidebarCauses(failure!).whereType<FavoriteMetadataBatchFailure>(),
            isNotEmpty,
          );
          window.onWindowClose();
          await pumpSidebar(tester);
        }
        expect(host.exits, 1);
        expect(host.manager.writes, isEmpty);
        expect(host.source.requests, hasLength(2));
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Widget? _libraryChild;
LocalFavoritesManager? _favoritesOwner;
LocalFavoritesManager _favoritesForView() =>
    _favoritesOwner ??= LocalFavoritesManager.independent();
HistoryManager? _historyOwner;
HistoryManager _historyForView() => _historyOwner ??= HistoryManager.create();
Widget _libraryView(Widget child) {
  _libraryChild = child;
  return FavoritesScope(
    manager: _favoritesForView(),
    child: HistoryScope(manager: _historyForView(), child: child),
  );
}

Future<void> _replaceFavorites(
  WidgetTester tester,
  LocalFavoritesManager manager,
) async {
  _favoritesOwner = manager;
  await tester.pumpWidget(_libraryView(_libraryChild!));
}
