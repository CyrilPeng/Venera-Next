import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/features/favorites/favorite_models.dart';
import 'package:venera_next/features/favorites/favorite_actions.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/favorites/favorites_page.dart';
import 'package:venera_next/features/favorites/local_favorites_page.dart';
import 'package:venera_next/features/follow_updates/follow_updates_page.dart';
import 'package:venera_next/features/follow_updates/follow_updates_runtime.dart';
import 'package:venera_next/features/follow_updates/follow_updates_scope.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/routing/app_navigation.dart';

import '../../components/sidebar_presentation_test.dart'
    show pumpSidebar, settleSidebarWork;

enum _Action { folder, comics, read }

FavoriteItem _comic(String id) => FavoriteItem(
  id: id,
  name: id,
  author: '',
  coverPath: '',
  type: ComicType.local,
  tags: const [],
);

class _History extends Fake implements HistoryManager {
  @override
  History? find(String id, ComicType type) => null;
}

class _Manager extends Fake implements LocalFavoritesManager {
  @override
  int connectionGeneration = 1;
  final contents = {
    'Original': [_comic('A'), _comic('B')],
    'Other': [_comic('X'), _comic('Y')],
  };
  final listeners = <VoidCallback>{};
  final deletions = <String>[];
  final removed = <(String, String, int)>[];
  final exported = <String>[];
  final added = <(String, String, int)>[];
  final marked = <(String, String, int)>[];
  Future<void> Function()? saving;
  @override
  List<String> get folderNames => contents.keys.toList();
  @override
  int folderComics(String name) => contents[name]?.length ?? 0;
  @override
  bool existsFolder(String name) => contents.containsKey(name);
  @override
  (String?, String?) findLinked(String folder) => (null, null);
  @override
  List<FavoriteItem> getFolderComics(String name, {int? limit}) =>
      contents[name]?.map((comic) => comic.detached()).toList() ?? [];
  @override
  List<FavoriteItemWithUpdateInfo> getComicsWithUpdatesInfo(String name) =>
      getFolderComics(name)
          .map(
            (comic) => FavoriteItemWithUpdateInfo(
              comic,
              '2026-10-09',
              true,
              1791504000000,
            ),
          )
          .toList();
  @override
  void addListener(VoidCallback listener) => listeners.add(listener);
  @override
  void removeListener(VoidCallback listener) => listeners.remove(listener);
  @override
  void notifyChanges() {}
  @override
  Future<void> deleteFolder(String name) async {
    deletions.add(name);
    await saving?.call();
    contents.remove(name);
    for (final listener in listeners.toList()) {
      listener();
    }
  }

  @override
  Future<void> batchDeleteComics(
    String folder,
    List<FavoriteItem> comics,
  ) async {
    removed.addAll(comics.map((comic) => (folder, comic.id, comic.type.value)));
    await saving?.call();
    contents[folder]?.removeWhere((comic) => comics.contains(comic));
  }

  @override
  Future<void> deleteComicWithId(
    String folder,
    String id,
    ComicType type,
  ) async {
    removed.add((folder, id, type.value));
    await saving?.call();
    contents[folder]?.removeWhere(
      (comic) => comic.id == id && comic.type == type,
    );
  }

  @override
  String folderToJson(String folder) {
    exported.add(folder);
    return jsonEncode({'folder': folder});
  }

  @override
  Future<int> addComics(String folder, Iterable<FavoriteItem> comics) async {
    final captured = comics.map((comic) => comic.detached()).toList();
    added.addAll(captured.map((comic) => (folder, comic.id, comic.type.value)));
    await saving?.call();
    contents[folder]!.addAll(captured);
    return captured.length;
  }

  @override
  Future<void> markAsRead(
    String id,
    ComicType type, {
    bool notify = true,
  }) async {
    marked.add((
      appdata.settings['followUpdatesFolder'] as String,
      id,
      type.value,
    ));
    await saving?.call();
  }

  @override
  Future<void> markAllAsRead(String folder, List<FavoriteItem> comics) async {
    marked.addAll(comics.map((comic) => (folder, comic.id, comic.type.value)));
    await saving?.call();
  }

  bool get hasWrites =>
      deletions.isNotEmpty || removed.isNotEmpty || marked.isNotEmpty;
}

FollowUpdatesRuntime _runtime() => FollowUpdatesRuntime(
  folder: () => null,
  isChecking: () => false,
  waitForDownload: () async {},
  createTask: (_) => throw StateError('Unexpected background task'),
  onError: (_, _) {},
  observeChanges: (_) => () {},
);

class _Host {
  _Host(this.action, {this.real = false, this.parent = false});
  final _Action action;
  final bool real;
  final bool parent;
  LocalFavoritesManager? actual;
  final manager = _Manager();
  final originalRegistry = SelectionTaskRegistry();
  late SelectionTaskRegistry registry = originalRegistry;
  final originalRuntime = _runtime();
  late FollowUpdatesRuntime runtime = originalRuntime;
  final content = ValueNotifier<Widget>(const SizedBox());
  final selected = <String?>[];
  bool allowed = true;
  int lists = 0;
  bool dialogDuringPublication = false;
  late WidgetTester tester;
  NavigatorState get navigator => appNavigation.rootNavigatorKey.currentState!;

  Widget page([String folder = 'Original']) => LocalFavoritesPage(
    folder: folder,
    showFolders: () {},
    updateFolderList: () => lists++,
    onFolderSelected: (_, value) {
      dialogDuringPublication = find
          .byType(ContentDialog)
          .evaluate()
          .any((element) => ModalRoute.of(element)?.isCurrent == true);
      selected.add(value);
    },
  );

  Widget app() => MaterialApp(
    navigatorKey: appNavigation.rootNavigatorKey,
    builder: (_, child) => SelectionTasksScope(
      registry: registry,
      child: NavigationAdmission(
        allowsNavigation: () => allowed,
        child: FollowUpdatesScope(runtime: runtime, child: child!),
      ),
    ),
    home: Scaffold(
      body: ValueListenableBuilder<Widget>(
        valueListenable: content,
        builder: (_, value, _) => value,
      ),
    ),
  );

  Future<void> mount(WidgetTester value) async {
    tester = value;
    final previousManager = LocalFavoritesManager.cache;
    final previousHistory = HistoryManager.cache;
    final previousData = App.dataPath;
    final previousCache = App.cachePath;
    final checkpoint = appdata.captureImportCheckpoint();
    final root = Directory.systemTemp.createTempSync(
      'venera-confirm-actions-owned-',
    );
    App.dataPath = root.path;
    App.cachePath = root.path;
    LocalFavoritesManager.cache = manager;
    HistoryManager.cache = _History();
    appdata.settings['language'] = 'en-US';
    appdata.settings['favoritesDisplayMode'] = 'list';
    appdata.settings['followUpdatesFolder'] = real ? null : 'Original';
    appdata.implicitData['local_favorites_read_filter'] = 'All';
    appdata.implicitData['favoriteFolder'] = {
      'name': 'Original',
      'isNetwork': false,
    };
    registerShowMessageHandler((_, _) {});
    content.value = action == _Action.read
        ? const FollowUpdatesPage()
        : parent
        ? const FavoritesPage()
        : page();
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
      for (final owner in {runtime, originalRuntime}) {
        owner.dispose();
      }
      LocalFavoritesManager.cache = previousManager;
      HistoryManager.cache = previousHistory;
      App.dataPath = previousData;
      App.cachePath = previousCache;
      registerShowMessageHandler((_, _) {});
      content.dispose();
      final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
      final owned = root.resolveSymbolicLinksSync();
      expect(p.isWithin(temporary, owned), isTrue);
      expect(p.basename(owned), startsWith('venera-confirm-actions-owned-'));
      root.deleteSync(recursive: true);
    });
    if (real) {
      LocalFavoritesManager.cache = null;
      final database = actual = LocalFavoritesManager();
      await tester.runAsync(() async {
        await database.init();
        for (final folder in ['Original', 'Other']) {
          await database.createFolder(folder);
          await database.prepareTableForFollowUpdates(folder, clearData: false);
          for (final id in ['A', 'B']) {
            await database.addComic(folder, _comic(id), ['A', 'B'].indexOf(id));
          }
        }
        final connection = sqlite3.open(database.databasePath);
        try {
          for (final folder in ['Original', 'Other']) {
            connection.execute(
              'UPDATE "$folder" SET has_new_update = 1, last_update_time = ?, last_check_time = ?;',
              ['2026-10-09', 1791504000000],
            );
          }
        } finally {
          connection.dispose();
        }
        appdata.settings['followUpdatesFolder'] = 'Original';
        database.refreshUpdateIds();
      });
    }
    await tester.pumpWidget(app());
    await pumpSidebar(tester);
    if (action == _Action.comics) {
      final grid = tester.widget<SliverGridComics>(
        find.byType(SliverGridComics),
      );
      grid.onLongPressed!(grid.comics.first, 0);
      await pumpSidebar(tester);
    }
  }

  VoidCallback trigger() {
    if (action == _Action.read) {
      return tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.clear_all))
          .onPressed!;
    }
    return tester
        .widgetList<MenuButton>(find.byType(MenuButton))
        .expand((menu) => menu.entries)
        .singleWhere(
          (entry) =>
              entry.text ==
              (action == _Action.folder ? 'Delete Folder' : 'Delete Comic'),
        )
        .onClick;
  }

  Future<void> open() async {
    trigger()();
    await pumpSidebar(tester);
    expect(find.byType(ContentDialog), findsOneWidget);
  }

  Future<_Manager?> retire(String state) async {
    _Manager? replacement;
    switch (state) {
      case 'folder':
        if (action == _Action.read) {
          appdata.settings['followUpdatesFolder'] = 'Other';
          runtime.notifyChanged();
        } else {
          content.value = page('Other');
        }
      case 'removed':
        content.value = const Text('Replacement content');
      case 'covered':
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Newer page')),
          ),
        );
      case 'frozen':
        allowed = false;
      case 'registry':
        registry = SelectionTaskRegistry();
        await tester.pumpWidget(app());
      case 'runtime':
        runtime = _runtime();
        await tester.pumpWidget(app());
      case 'manager':
        LocalFavoritesManager.cache = replacement = _Manager();
      case 'connection':
        manager.connectionGeneration++;
      case 'path':
        App.dataPath = '${App.dataPath}/replacement';
    }
    await pumpSidebar(tester);
    return replacement;
  }
}

Future<void> _confirm(WidgetTester tester) {
  final press = tester
      .widget<Button>(find.widgetWithText(Button, 'Confirm'))
      .onPressed;
  return Future<void>.sync(() => Function.apply(press, const []));
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

  testWidgets('R1 bulk dialog freezes comics and waits for accepted saves', (
    tester,
  ) async {
    final host = _Host(_Action.folder);
    await host.mount(tester);
    appdata.settings['quickFavorite'] = 'Original';
    final items = [_comic('new')];
    final pending = Completer<void>();
    host.manager.saving = () => pending.future;
    final showing = addFavorite(
      tester.element(find.byType(LocalFavoritesPage)),
      items,
    );
    items.first.id = 'changed';
    items.clear();
    await pumpSidebar(tester);
    final saving = _confirm(tester);
    await pumpSidebar(tester);
    expect(host.manager.added, [('Original', 'new', 0)]);
    await host.retire('removed');
    var closed = false;
    final closing = host.originalRegistry.closeAndWait().then(
      (_) => closed = true,
    );
    await pumpSidebar(tester);
    final closedEarly = closed;
    pending.complete();
    await settleSidebarWork(tester, () async {
      await saving;
      await showing;
      await closing;
    });
    expect(closedEarly, isFalse);
    expect(host.manager.contents['Original']!.last.id, 'new');
    expect(tester.takeException(), isNull);
  });

  testWidgets('R1 bulk dialog cannot save into a replacement database', (
    tester,
  ) async {
    final host = _Host(_Action.folder);
    await host.mount(tester);
    appdata.settings['quickFavorite'] = 'Original';
    final showing = addFavorite(
      tester.element(find.byType(LocalFavoritesPage)),
      [_comic('new')],
    );
    await pumpSidebar(tester);
    final replacement = await host.retire('manager');
    await _confirm(tester);
    await pumpSidebar(tester);
    expect(host.manager.added, isEmpty);
    expect(replacement!.added, isEmpty);
    await tester.tap(find.text('Cancel'));
    await pumpSidebar(tester);
    await showing;
    expect(tester.takeException(), isNull);
  });

  for (final action in ['Delete', 'Export']) {
    for (final retired in ['folder', 'manager', 'path', 'removed']) {
      testWidgets('R1 retained $action rejects $retired replacement', (
        tester,
      ) async {
        final host = _Host(_Action.folder);
        await host.mount(tester);
        final grid = tester.widget<SliverGridComics>(
          find.byType(SliverGridComics),
        );
        final trigger = action == 'Delete'
            ? grid.menuBuilder!(grid.comics.first)
                  .singleWhere((entry) => entry.text == action)
                  .onClick
            : tester
                  .widgetList<MenuButton>(find.byType(MenuButton))
                  .expand((menu) => menu.entries)
                  .singleWhere((entry) => entry.text == action)
                  .onClick;
        final replacement = await host.retire(retired);
        trigger();
        await pumpSidebar(tester);
        expect(host.manager.removed, isEmpty);
        expect(host.manager.exported, isEmpty);
        if (replacement != null) {
          expect(replacement.removed, isEmpty);
          expect(replacement.exported, isEmpty);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('R1 accepted quick deletion drains with its original host', (
    tester,
  ) async {
    final host = _Host(_Action.folder);
    await host.mount(tester);
    final pending = Completer<void>();
    host.manager.saving = () => pending.future;
    final grid = tester.widget<SliverGridComics>(find.byType(SliverGridComics));
    grid.menuBuilder!(grid.comics.first)
        .singleWhere((entry) => entry.text == 'Delete')
        .onClick();
    await pumpSidebar(tester);
    expect(host.manager.removed, [('Original', 'A', 0)]);
    await host.retire('removed');
    var ended = false;
    final closing = host.originalRegistry.closeAndWait().then(
      (_) => ended = true,
    );
    await pumpSidebar(tester);
    final completedBeforeSave = ended;
    pending.complete();
    await settleSidebarWork(tester, () async => await closing);
    expect(completedBeforeSave, isFalse);
    expect(host.manager.contents['Original']!.map((comic) => comic.id), ['B']);
    expect(tester.takeException(), isNull);
  });

  for (final action in _Action.values) {
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
      testWidgets('old action cannot present confirmation: $action $state', (
        tester,
      ) async {
        final host = _Host(action);
        await host.mount(tester);
        final trigger = host.trigger();
        final replacement = await host.retire(state);
        trigger();
        await pumpSidebar(tester);
        expect(find.byType(ContentDialog), findsNothing);
        expect(host.manager.hasWrites, isFalse);
        expect(replacement?.hasWrites, isNot(true));
        expect(tester.takeException(), isNull);
      });
    }

    for (final state in ['folder', 'manager', 'connection', 'path']) {
      testWidgets(
        'confirmation cannot mutate replacement target: $action $state',
        (tester) async {
          final host = _Host(action);
          await host.mount(tester);
          await host.open();
          final replacement = await host.retire(state);
          await settleSidebarWork(tester, () => _confirm(tester));
          await pumpSidebar(tester);
          expect(host.manager.hasWrites, isFalse);
          expect(replacement?.hasWrites, isNot(true));
          expect(host.selected, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final state in ['manager', 'connection', 'path']) {
      testWidgets(
        'queued accepted action rechecks original database: $action $state',
        (tester) async {
          final host = _Host(action);
          await host.mount(tester);
          await host.open();
          final gate = Completer<void>();
          final blocking = AppDataOperations.instance.run(() => gate.future);
          final confirming = _confirm(tester);
          await pumpSidebar(tester);
          try {
            expect(host.manager.hasWrites, isFalse);
            final replacement = await host.retire(state);
            gate.complete();
            await settleSidebarWork(tester, () => confirming);
            expect(host.manager.hasWrites, isFalse);
            expect(replacement?.hasWrites, isNot(true));
            expect(host.selected, isEmpty);
          } finally {
            if (!gate.isCompleted) gate.complete();
            await settleSidebarWork(
              tester,
              () => Future.wait([blocking, confirming]),
            );
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'folder deletion publishes selection after confirmation is gone',
    (tester) async {
      final host = _Host(_Action.folder);
      await host.mount(tester);
      await host.open();
      await settleSidebarWork(tester, () => _confirm(tester));
      await pumpSidebar(tester);
      expect(host.manager.deletions, ['Original']);
      expect(host.selected, [null]);
      expect(host.lists, 1);
      expect(host.dialogDuringPublication, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('accepted comic deletion preserves a newer selection', (
    tester,
  ) async {
    final host = _Host(_Action.comics);
    await host.mount(tester);
    final originalGrid = tester.widget<SliverGridComics>(
      find.byType(SliverGridComics),
    );
    await host.open();
    final pending = Completer<void>();
    host.manager.saving = () => pending.future;
    final confirming = _confirm(tester);
    await pumpSidebar(tester);
    originalGrid.onTap!(originalGrid.comics.first, 0);
    originalGrid.onLongPressed!(originalGrid.comics.last, 0);
    await pumpSidebar(tester);
    pending.complete();
    await settleSidebarWork(tester, () => confirming);
    await pumpSidebar(tester);
    final grid = tester.widget<SliverGridComics>(find.byType(SliverGridComics));
    expect(grid.selections!.keys.map((comic) => comic.id), ['B']);
    expect(host.manager.removed, [('Original', 'A', ComicType.local.value)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('old comic menu cannot substitute a newer selection', (
    tester,
  ) async {
    final host = _Host(_Action.comics);
    await host.mount(tester);
    final trigger = host.trigger();
    final grid = tester.widget<SliverGridComics>(find.byType(SliverGridComics));
    grid.onTap!(grid.comics.first, 0);
    grid.onLongPressed!(grid.comics.last, 0);
    await pumpSidebar(tester);
    trigger();
    await pumpSidebar(tester);
    expect(find.byType(ContentDialog), findsNothing);
    expect(host.manager.hasWrites, isFalse);
  });

  for (final action in [_Action.comics, _Action.read]) {
    testWidgets('confirmation retains immutable item identities: $action', (
      tester,
    ) async {
      final host = _Host(action);
      await host.mount(tester);
      final grid = tester
          .widgetList<SliverGridComics>(find.byType(SliverGridComics))
          .first;
      final original = grid.comics.first as FavoriteItem;
      await host.open();
      original.id = 'Replacement identity';
      await settleSidebarWork(tester, () => _confirm(tester));
      await pumpSidebar(tester);
      final writes = action == _Action.comics
          ? host.manager.removed
          : host.manager.marked;
      expect(writes.map((entry) => entry.$2), contains('A'));
      expect(
        writes.map((entry) => entry.$2),
        isNot(contains('Replacement identity')),
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final state in PersistenceCommitState.values) {
    testWidgets(
      'folder delete publishes only a known committed result: $state',
      (tester) async {
        final host = _Host(_Action.folder);
        host.manager.saving = () async => throw PersistenceFailure(
          commitState: state,
          cause: StateError('delete result'),
          stackTrace: StackTrace.current,
        );
        await host.mount(tester);
        await host.open();
        await settleSidebarWork(tester, () => _confirm(tester));
        await pumpSidebar(tester);
        final label = state == PersistenceCommitState.notCommitted
            ? 'Confirm'
            : 'OK';
        final press = tester
            .widget<Button>(find.widgetWithText(Button, label))
            .onPressed;
        if (state == PersistenceCommitState.notCommitted) {
          host.manager.saving = null;
        }
        await settleSidebarWork(
          tester,
          () => Future<void>.sync(() => Function.apply(press, const [])),
        );
        await pumpSidebar(tester);
        expect(
          host.manager.deletions,
          hasLength(state == PersistenceCommitState.notCommitted ? 2 : 1),
        );
        expect(
          host.selected,
          state == PersistenceCommitState.unknown ? isEmpty : [null],
        );
        expect(host.dialogDuringPublication, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'real mark-all-read rolls back the entire original snapshot on failure',
    (tester) async {
      final host = _Host(_Action.read, real: true);
      await host.mount(tester);
      final database = host.actual!;
      final connection = sqlite3.open(database.databasePath);
      addTearDown(connection.dispose);
      final original = connection
          .select('SELECT * FROM "Original" ORDER BY id;')
          .map((row) => Map<String, Object?>.from(row))
          .toList();
      final other = connection
          .select('SELECT * FROM "Other" ORDER BY id;')
          .map((row) => Map<String, Object?>.from(row))
          .toList();
      connection.execute('''
      CREATE TRIGGER reject_read BEFORE UPDATE OF has_new_update ON "Original"
      WHEN OLD.id = 'B' BEGIN SELECT RAISE(ABORT, 'original read rollback'); END;
    ''');
      await host.open();
      await settleSidebarWork(tester, () => _confirm(tester));
      await pumpSidebar(tester);
      expect(find.textContaining('original read rollback'), findsOneWidget);
      expect(
        connection
            .select('SELECT * FROM "Original" ORDER BY id;')
            .map((row) => Map<String, Object?>.from(row)),
        original,
      );
      expect(database.hasNewUpdate('A', ComicType.local), isTrue);
      expect(database.hasNewUpdate('B', ComicType.local), isTrue);
      connection.execute('DROP TRIGGER reject_read;');
      await settleSidebarWork(tester, () => _confirm(tester));
      await pumpSidebar(tester);
      expect(database.countUpdates('Original'), 0);
      expect(
        connection
            .select('SELECT * FROM "Other" ORDER BY id;')
            .map((row) => Map<String, Object?>.from(row)),
        other,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real comic deletion cannot replay after a post-commit observer failure',
    (tester) async {
      final host = _Host(_Action.comics, real: true);
      await host.mount(tester);
      final database = host.actual!;
      final failure = StateError('original delete observer');
      registerFollowUpdatesChangeListener(() => throw failure);
      addTearDown(() => registerFollowUpdatesChangeListener(null));
      await host.open();
      await settleSidebarWork(tester, () => _confirm(tester));
      await pumpSidebar(tester);
      expect(database.comicExists('Original', 'A', ComicType.local), isFalse);
      expect(find.textContaining('original delete observer'), findsOneWidget);
      registerFollowUpdatesChangeListener(null);
      await tester.runAsync(() => database.addComic('Original', _comic('A')));
      final press = tester
          .widget<Button>(
            find.descendant(
              of: find.byType(ContentDialog),
              matching: find.byType(Button),
            ),
          )
          .onPressed;
      await settleSidebarWork(
        tester,
        () => Future<void>.sync(() => Function.apply(press, const [])),
      );
      await pumpSidebar(tester);
      expect(database.comicExists('Original', 'A', ComicType.local), isTrue);
      expect(database.comicExists('Other', 'A', ComicType.local), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final action in _Action.values) {
    testWidgets(
      'accepted mutation outlives its original caller and stays with its registry: $action',
      (tester) async {
        final host = _Host(action);
        await host.mount(tester);
        final pending = Completer<void>();
        host.manager.saving = () => pending.future;
        await host.open();
        final confirming = _confirm(tester);
        await pumpSidebar(tester);
        await host.retire('removed');
        await host.retire('registry');
        var originalClosed = false;
        final closing = host.originalRegistry.closeAndWait().then<void>(
          (_) => originalClosed = true,
        );
        await settleSidebarWork(tester, host.registry.closeAndWait);
        try {
          expect(originalClosed, isFalse);
          expect(host.manager.hasWrites, isTrue);
        } finally {
          pending.complete();
          await settleSidebarWork(
            tester,
            () => Future.wait([confirming, closing]),
          );
        }
        expect(host.selected, isEmpty);
        expect(host.runtime.changes.value, 0);
        expect(find.text('Replacement content'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final opened in [false, true]) {
    testWidgets(
      'mark-all-read rejects a replaced follow runtime: opened=$opened',
      (tester) async {
        final host = _Host(_Action.read);
        await host.mount(tester);
        final trigger = host.trigger();
        if (opened) await host.open();
        await host.retire('runtime');
        if (opened) {
          await settleSidebarWork(tester, () => _confirm(tester));
        } else {
          trigger();
          await pumpSidebar(tester);
          expect(find.byType(ContentDialog), findsNothing);
        }
        expect(host.manager.hasWrites, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final observerFails in [false, true]) {
    testWidgets(
      'actual FavoritesPage accepts committed folder deletion after dialog closes: failure=$observerFails',
      (tester) async {
        final host = _Host(_Action.folder, real: true, parent: true);
        await host.mount(tester);
        final database = host.actual!;
        final originalPage = tester.state(find.byType(LocalFavoritesPage));
        final parent =
            tester.state(find.byType(FavoritesPage)) as SettingsSaveState;
        final failure = StateError('original folder deletion observer');
        if (observerFails) {
          registerFollowUpdatesChangeListener(() => throw failure);
        }
        addTearDown(() => registerFollowUpdatesChangeListener(null));
        appdata.settings['quickFavorite'] = 'Original';
        appdata.settings['readLaterFolder'] = 'Other';
        await tester.runAsync(() async {
          await database.linkFolderToNetwork(
            'Original',
            'synthetic-source',
            'remote',
          );
          await database.updateOrder(['Original', 'Other']);
        });
        await host.open();
        await settleSidebarWork(tester, () => _confirm(tester));
        await pumpSidebar(tester);
        if (observerFails) {
          expect(
            find.textContaining('original folder deletion observer'),
            findsOneWidget,
          );
          final acknowledge = tester
              .widget<Button>(find.widgetWithText(Button, 'OK'))
              .onPressed;
          await settleSidebarWork(
            tester,
            () =>
                Future<void>.sync(() => Function.apply(acknowledge, const [])),
          );
          await pumpSidebar(tester);
        }
        await settleSidebarWork(tester, parent.waitForSettingsSave);
        await pumpSidebar(tester);
        expect(originalPage.mounted, isFalse);
        expect(find.text('Unselected'), findsOneWidget);
        expect(appdata.implicitData['favoriteFolder'], {
          'name': null,
          'isNetwork': false,
        });
        expect(appdata.settings['quickFavorite'], isNull);
        expect(appdata.settings['followUpdatesFolder'], isNull);
        expect(appdata.settings['readLaterFolder'], 'Other');
        final persisted =
            jsonDecode(
                  File('${App.dataPath}/implicitData.json').readAsStringSync(),
                )
                as Map;
        expect(persisted['favoriteFolder'], {'name': null, 'isNetwork': false});
        registerFollowUpdatesChangeListener(null);
        await tester.runAsync(() async {
          await database.closeAndWait();
          await database.init();
        });
        expect(database.existsFolder('Original'), isFalse);
        expect(database.count('Other'), 2);
        expect(database.findLinked('Original'), (null, null));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'real mark-all-read preserves later records and composite identities across reopening',
    (tester) async {
      final host = _Host(_Action.read, real: true);
      await host.mount(tester);
      final database = host.actual!;
      await host.open();
      final later = _comic('A')..type = const ComicType(730019);
      final newComic = _comic('C');
      await tester.runAsync(() async {
        await database.addComic('Original', later, 2);
        await database.addComic('Original', newComic, 3);
      });
      final connection = sqlite3.open(database.databasePath);
      connection.execute(
        'UPDATE "Original" SET has_new_update = 1, last_update_time = ?, last_check_time = ?;',
        ['2026-10-09', 1791504000000],
      );
      final before = connection
          .select('SELECT rowid, * FROM "Original" ORDER BY rowid;')
          .map((row) => Map<String, Object?>.from(row))
          .toList();
      connection.dispose();
      var notifications = 0;
      void changed() => notifications++;
      database.addListener(changed);
      addTearDown(() => database.removeListener(changed));
      await settleSidebarWork(tester, () => _confirm(tester));
      await pumpSidebar(tester);
      expect(notifications, 1);
      expect(host.runtime.changes.value, 1);
      final expected = before.map((row) {
        final result = Map<String, Object?>.from(row);
        if (result['type'] == ComicType.local.value &&
            ['A', 'B'].contains(result['id'])) {
          result['has_new_update'] = 0;
        }
        return result;
      }).toList();
      await tester.runAsync(() async {
        await database.closeAndWait();
        await database.init();
      });
      final reopened = sqlite3.open(database.databasePath);
      try {
        expect(
          reopened
              .select('SELECT rowid, * FROM "Original" ORDER BY rowid;')
              .map((row) => Map<String, Object?>.from(row)),
          expected,
        );
        expect(database.hasNewUpdate('A', later.type), isTrue);
        expect(database.hasNewUpdate('A', ComicType.local), isFalse);
        expect(database.countUpdates('Other'), 2);
      } finally {
        reopened.dispose();
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'queued mark-all-read keeps its folder when follow settings change',
    (tester) async {
      final host = _Host(_Action.read, real: true);
      await host.mount(tester);
      await host.open();
      final gate = Completer<void>();
      final blocking = AppDataOperations.instance.run(() => gate.future);
      final confirming = _confirm(tester);
      await pumpSidebar(tester);
      await host.retire('folder');
      try {
        gate.complete();
        await settleSidebarWork(
          tester,
          () => Future.wait([blocking, confirming]),
        );
        expect(host.actual!.countUpdates('Original'), 0);
        expect(host.actual!.countUpdates('Other'), 2);
        expect(host.actual!.hasNewUpdate('A', ComicType.local), isTrue);
        expect(appdata.settings['followUpdatesFolder'], 'Other');
        expect(host.runtime.changes.value, 1);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await settleSidebarWork(
          tester,
          () => Future.wait([blocking, confirming]),
        );
      }
      expect(tester.takeException(), isNull);
    },
  );
}
