import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/features/history/history_scope.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
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
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/selection_operation.dart';
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
  bool failPop = false;
  final failure = StateError('original transfer popup pop failed');
  @override
  void pop<T extends Object?>([T? result]) {
    if (failPop) throw failure;
    super.pop(result);
  }
}

FavoriteItem _comic(String id) => FavoriteItem.withTime(
  id: id,
  name: id,
  author: 'original author',
  coverPath: '',
  type: ComicType.local,
  tags: ['original tag'],
  time: 'legacy original time',
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
    'Other': [_comic('X')],
    'First': <FavoriteItem>[],
    'Second': <FavoriteItem>[],
  };
  final listeners = <VoidCallback>{};
  final writes =
      <
        ({
          String source,
          List<String> targets,
          List<FavoriteItem> items,
          bool move,
        })
      >[];
  Future<void> Function()? saving;
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
  Future<void> transferFavorites(
    String source,
    Iterable<String> targets,
    List<FavoriteItem> items, {
    required bool move,
  }) async {
    writes.add((
      source: source,
      targets: targets.toList(),
      items: items.map((item) => item.detached()).toList(),
      move: move,
    ));
    await saving?.call();
  }
}

class _Host {
  _Host({this.move = true, this.real = false, this.window = false});
  final bool move;
  final bool real;
  final bool window;
  LocalFavoritesManager? actual;
  int exits = 0;
  final manager = _Manager();
  final originalRegistry = SelectionTaskRegistry();
  late SelectionTaskRegistry registry = originalRegistry;
  final content = ValueNotifier<Widget>(const SizedBox());
  bool allowed = true;
  late WidgetTester tester;
  _NavigatorState get navigator =>
      appNavigation.rootNavigatorKey.currentState! as _NavigatorState;
  dynamic get page => tester.state(find.byType(LocalFavoritesPage));
  SliverGridComics get grid =>
      tester.widget<SliverGridComics>(find.byType(SliverGridComics));

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
    final checkpoint = appdata.captureImportCheckpoint();
    final root = Directory.systemTemp.createTempSync('venera-transfer-owned-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    _favoritesOwner = manager;
    _historyOwner = _History();
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
      _favoritesOwner = previousManager;
      _historyOwner = previousHistory;
      App.dataPath = previousData;
      App.cachePath = previousCache;
      content.dispose();
      final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
      final owned = root.resolveSymbolicLinksSync();
      expect(p.isWithin(temporary, owned), isTrue);
      expect(p.basename(owned), startsWith('venera-transfer-owned-'));
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
    grid.onLongPressed!(grid.comics.first, 0);
    await pumpSidebar(tester);
  }

  VoidCallback menu() => tester
      .widgetList<MenuButton>(find.byType(MenuButton))
      .expand((button) => button.entries)
      .singleWhere(
        (entry) => entry.text == (move ? 'Move to folder' : 'Copy to folder'),
      )
      .onClick;
  Future<void> open() async {
    menu()();
    await pumpSidebar(tester);
    expect(find.byType(PopUpWidgetScaffold), findsOneWidget);
  }

  Future<void> choose([String name = 'First']) async {
    tester
        .widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, name))
        .onChanged!(true);
    await tester.pump();
  }

  Future<void> press([VoidCallback? retained]) => Future<void>.sync(
    () => Function.apply(
      retained ??
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed!,
      const [],
    ),
  );
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
      case 'selection':
        page.selectAll();
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

  for (final move in [true, false]) {
    testWidgets('transfer preserves source and selected targets; move=$move', (
      tester,
    ) async {
      final host = _Host(move: move);
      await host.mount(tester);
      await host.open();
      await host.choose();
      await host.choose('Second');
      await host.press();
      await pumpSidebar(tester);
      expect(host.manager.writes, hasLength(1));
      final write = host.manager.writes.single;
      expect(write.source, 'Original');
      expect(write.targets, ['First', 'Second']);
      expect(write.items.map((item) => item.id), ['A']);
      expect(write.move, move);
      expect(find.byType(PopUpWidgetScaffold), findsNothing);
      expect(host.page.multiSelectMode, isFalse);
    });
  }

  for (final state in [
    'folder',
    'removed',
    'covered',
    'frozen',
    'registry',
    'manager',
    'connection',
    'path',
    'selection',
  ]) {
    testWidgets('retained transfer menu rejects retired $state', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      final retained = host.menu();
      await host.retire(state);
      retained();
      await pumpSidebar(tester);
      expect(find.byType(PopUpWidgetScaffold), findsNothing);
      expect(host.manager.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
    testWidgets('retained transfer save rejects retired $state', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      await host.open();
      await host.choose();
      final retained = tester
          .widget<FilledButton>(find.byType(FilledButton))
          .onPressed!;
      final replacement = await host.retire(state);
      await host.press(retained);
      await pumpSidebar(tester);
      expect(host.manager.writes, isEmpty);
      expect(replacement?.writes ?? [], isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final state in ['manager', 'connection', 'path']) {
    testWidgets('queued transfer rechecks original $state at admission', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      await host.open();
      await host.choose();
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final saving = host.press();
      await tester.pump();
      final replacement = await host.retire(state);
      release.complete();
      await settleSidebarWork(tester, () => Future.wait([exclusive, saving]));
      expect(host.manager.writes, isEmpty);
      expect(replacement?.writes ?? [], isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('accepted transfer is joined by the original application close', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    await host.open();
    await host.choose();
    final release = Completer<void>();
    host.manager.saving = () => release.future;
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final saving = host.press();
    await tester.pump();
    expect(host.manager.writes, hasLength(1));
    var closed = false;
    final closing = host.originalRegistry.closeAndWait().then(
      (_) => closed = true,
    );
    await pumpSidebar(tester);
    expect(closed, isFalse);
    release.complete();
    await settleSidebarWork(tester, () => Future.wait([saving, closing]));
    expect(closed, isTrue);
    expect(find.byType(PopUpWidgetScaffold), findsNothing);
  });

  testWidgets('accepted transfer does not clear a newer page selection', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    await host.open();
    await host.choose();
    final release = Completer<void>();
    host.manager.saving = () => release.future;
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final saving = host.press();
    await tester.pump();
    host.page.selectAll();
    await tester.pump();
    release.complete();
    await settleSidebarWork(tester, () => saving);
    expect(host.page.multiSelectMode, isTrue);
    expect((host.page.selectedComics as Map).length, 2);
  });

  testWidgets('transfer snapshots item identities before popup interaction', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    final original = host.grid.comics.first as FavoriteItem;
    await host.open();
    original.id = 'mutated after menu';
    original.tags.add('late tag');
    await host.choose();
    await host.press();
    await pumpSidebar(tester);
    final saved = host.manager.writes.single.items.single;
    expect(saved.id, 'A');
    expect(saved.tags, ['original tag']);
    expect(saved.time, 'legacy original time');
  });

  for (final state in PersistenceCommitState.values) {
    testWidgets('transfer retry respects persistence commitment $state', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      await host.open();
      await host.choose();
      final cause = StateError('original transfer failure');
      host.manager.saving = () async => throw PersistenceFailure(
        commitState: state,
        cause: cause,
        stackTrace: StackTrace.current,
      );
      await host.press();
      await pumpSidebar(tester);
      expect(host.manager.writes, hasLength(1));
      host.manager.saving = null;
      await host.press();
      await pumpSidebar(tester);
      expect(
        host.manager.writes.length,
        state == PersistenceCommitState.notCommitted ? 2 : 1,
      );
      expect(find.byType(PopUpWidgetScaffold), findsNothing);
    });
  }

  testWidgets('visible popup can dismiss after initiating page removal', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    await host.open();
    await host.retire('removed');
    await tester.tap(find.widgetWithIcon(IconButton, Icons.arrow_back_sharp));
    await pumpSidebar(tester);
    expect(find.byType(PopUpWidgetScaffold), findsNothing);
    expect(host.manager.writes, isEmpty);
  });

  testWidgets(
    'real committed move is not replayed after a notification failure',
    (tester) async {
      final host = _Host(real: true);
      await host.mount(tester);
      final database = host.actual!;
      final failure = StateError('original transfer observer failure');
      registerFollowUpdatesChangeListener(() => throw failure);
      addTearDown(() => registerFollowUpdatesChangeListener(null));
      await host.open();
      await host.choose();
      await host.choose('Second');
      await settleSidebarWork(tester, host.press);
      await pumpSidebar(tester);
      expect(database.comicExists('Original', 'A', ComicType.local), isFalse);
      expect(database.comicExists('First', 'A', ComicType.local), isTrue);
      expect(database.comicExists('Second', 'A', ComicType.local), isTrue);
      expect(
        find.textContaining('original transfer observer failure'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'OK'), findsOneWidget);
      registerFollowUpdatesChangeListener(null);
      await tester.runAsync(() => database.addComic('Original', _comic('A')));
      await settleSidebarWork(tester, host.press);
      await pumpSidebar(tester);
      expect(find.byType(PopUpWidgetScaffold), findsNothing);
      expect(database.comicExists('Original', 'A', ComicType.local), isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await database.closeAndWait();
        await database.init();
      });
      expect(database.comicExists('Original', 'A', ComicType.local), isTrue);
      expect(database.comicExists('First', 'A', ComicType.local), isTrue);
      expect(database.comicExists('Second', 'A', ComicType.local), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('successful transfer with failed pop only retries closing', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    await host.open();
    await host.choose();
    host.navigator.failPop = true;
    await host.press();
    await pumpSidebar(tester);
    expect(host.manager.writes, hasLength(1));
    expect(find.widgetWithText(FilledButton, 'OK'), findsOneWidget);
    expect(host.page.multiSelectMode, isTrue);
    host.navigator.failPop = false;
    await host.press();
    await pumpSidebar(tester);
    expect(host.manager.writes, hasLength(1));
    expect(host.page.multiSelectMode, isFalse);
    expect(find.byType(PopUpWidgetScaffold), findsNothing);
  });

  for (final fail in [false, true]) {
    testWidgets('original window drains accepted transfer; failure=$fail', (
      tester,
    ) async {
      final host = _Host(window: true);
      await host.mount(tester);
      await host.open();
      await host.choose();
      final release = Completer<void>();
      host.manager.saving = () => release.future;
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final saving = host.press();
      await tester.pump();
      final window = tester.state(find.byType(WindowFrame)) as WindowListener;
      window.onWindowClose();
      await pumpSidebar(tester);
      expect(host.exits, 0);
      final failure = StateError('late original transfer failure');
      if (fail) {
        release.completeError(failure);
      } else {
        release.complete();
      }
      await settleSidebarWork(tester, () => saving);
      await pumpSidebar(tester);
      if (fail) {
        expect(host.exits, 0);
        final error = tester.takeException();
        expect(error, isNotNull);
        expect(sidebarCauses(error!), contains(same(failure)));
        window.onWindowClose();
        await pumpSidebar(tester);
      }
      expect(host.exits, 1);
      expect(host.manager.writes, hasLength(1));
      expect(tester.takeException(), isNull);
    });
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
