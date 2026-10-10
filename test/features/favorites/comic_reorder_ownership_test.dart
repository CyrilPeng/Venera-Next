import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/features/history/history_scope.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/button.dart';
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

class _OtherPopGuard extends PopEntry<Object?> {
  @override
  final ValueNotifier<bool> canPopNotifier = ValueNotifier(false);
}

class _Manager extends Fake implements LocalFavoritesManager {
  @override
  int connectionGeneration = 1;
  final contents = {
    'Original': [_comic('A'), _comic('B'), _comic('C')],
    'Other': [_comic('X'), _comic('Y')],
  };
  final listeners = <VoidCallback>{};
  final writes = <(String, List<String>)>[];
  Future<void> Function()? saving;
  Future<void>? _tail;
  Future<void> get settled => _tail ?? Future.value();
  @override
  List<String> get folderNames => contents.keys.toList();
  @override
  (String?, String?) findLinked(String name) => (null, null);
  @override
  int folderComics(String name) => contents[name]!.length;
  @override
  bool existsFolder(String name) => contents.containsKey(name);
  @override
  List<FavoriteItem> getFolderComics(String name, {int? limit}) =>
      contents[name]!.map((item) => item.detached()).toList();
  @override
  void addListener(VoidCallback listener) => listeners.add(listener);
  @override
  void removeListener(VoidCallback listener) => listeners.remove(listener);
  @override
  Future<void> reorder(List<FavoriteItem> items, String folder) {
    final snapshot = items.map((item) => item.detached()).toList();
    Future<void> write() async {
      writes.add((folder, snapshot.map((item) => item.id).toList()));
      await saving?.call();
      contents[folder] = snapshot;
      for (final listener in listeners.toList()) {
        listener();
      }
    }

    final previous = _tail;
    final result = previous == null
        ? Future<void>.sync(write)
        : previous.then((_) => write());
    _tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }
}

class _Host {
  final manager = _Manager();
  final registry = SelectionTaskRegistry();
  final registries = <SelectionTaskRegistry>[];
  final content = ValueNotifier<Widget>(const SizedBox());
  final messages = <String>[];
  bool allowed = true;
  bool window = false;
  bool multipleWindows = false;
  bool useSecondWindow = false;
  bool nested = false;
  final firstWindow = GlobalKey();
  final secondWindow = GlobalKey();
  final innerNavigator = GlobalKey<NavigatorState>();
  int exits = 0;
  int secondExits = 0;
  Object? expectedCloseFailure;
  NavigatorState get navigator => nested
      ? innerNavigator.currentState!
      : appNavigation.rootNavigatorKey.currentState!;

  Widget page([String folder = 'Original']) => LocalFavoritesPage(
    folder: folder,
    showFolders: () {},
    onFolderSelected: (_, _) {},
    updateFolderList: () {},
  );

  Widget app({SelectionTaskRegistry? tasks}) => _libraryView(
    MaterialApp(
      navigatorKey: appNavigation.rootNavigatorKey,
      builder: (_, child) => SelectionTasksScope(
        registry: tasks ?? registry,
        child: NavigationAdmission(
          allowsNavigation: () => allowed,
          child: multipleWindows
              ? Row(
                  children: [
                    Expanded(
                      child: WindowFrame(
                        useSecondWindow ? const SizedBox() : child!,
                        key: firstWindow,
                        onExit: () => exits++,
                      ),
                    ),
                    Expanded(
                      child: WindowFrame(
                        useSecondWindow ? child! : const SizedBox(),
                        key: secondWindow,
                        onExit: () => secondExits++,
                      ),
                    ),
                  ],
                )
              : window
              ? WindowFrame(child!, onExit: () => exits++)
              : child!,
        ),
      ),
      home: Scaffold(
        body: nested
            ? Navigator(
                key: innerNavigator,
                onGenerateRoute: (_) =>
                    MaterialPageRoute<void>(builder: (_) => _content()),
              )
            : _content(),
      ),
    ),
  );

  Widget _content() => ValueListenableBuilder<Widget>(
    valueListenable: content,
    builder: (_, value, _) => value,
  );

  Future<void> mount(WidgetTester tester) async {
    final previousManager = _favoritesOwner;
    final previousHistory = _historyOwner;
    final previousSettings = Map<String, dynamic>.from(
      appdata.toJson()['settings'] as Map,
    );
    final previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
    _favoritesOwner = manager;
    _historyOwner = _History();
    appdata.settings['language'] = 'en-US';
    appdata.settings['favoritesDisplayMode'] = 'list';
    appdata.implicitData['local_favorites_read_filter'] = 'All';
    registerShowMessageHandler((_, message) => messages.add(message));
    content.value = page();
    registries.add(registry);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await pumpSidebar(tester);
      await settleSidebarWork(tester, () => manager.settled);
      for (final tasks in registries) {
        await settleSidebarWork(tester, () async {
          try {
            await tasks.closeAndWait();
          } catch (error) {
            if (expectedCloseFailure == null ||
                !sidebarCauses(error).contains(expectedCloseFailure)) {
              rethrow;
            }
          }
        });
      }
      _favoritesOwner = previousManager;
      _historyOwner = previousHistory;
      previousSettings.forEach((key, value) => appdata.settings[key] = value);
      appdata.implicitData = previousImplicit;
      registerShowMessageHandler((_, _) {});
      content.dispose();
    });
    await tester.pumpWidget(app());
    await pumpSidebar(tester);
  }

  Route<void> cover() {
    final route = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('Newer page')),
    );
    navigator.push(route);
    return route;
  }

  Future<SelectionTaskRegistry> replaceRegistry(WidgetTester tester) async {
    final next = SelectionTaskRegistry();
    registries.add(next);
    await tester.pumpWidget(app(tasks: next));
    return next;
  }

  void closeWindow(WidgetTester tester) =>
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
}

VoidCallback _menu(WidgetTester tester) => tester
    .widgetList<MenuButton>(find.byType(MenuButton))
    .expand((menu) => menu.entries)
    .singleWhere((entry) => entry.text == 'Reorder')
    .onClick;

Future<void> _open(WidgetTester tester) async {
  _menu(tester)();
  await pumpSidebar(tester);
  expect(find.byType(ReorderableBuilder<FavoriteItem>), findsOneWidget);
}

VoidCallback _reverse(WidgetTester tester) => tester
    .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.swap_vert))
    .onPressed!;

VoidCallback _back(WidgetTester tester) => tester
    .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.arrow_back))
    .onPressed!;

VoidCallback _retry(WidgetTester tester) =>
    tester.widget<TextButton>(_retryButton).onPressed!;

Finder get _retryButton => find.descendant(
  of: find.byType(Appbar),
  matching: find.widgetWithText(TextButton, 'Retry'),
);

VoidCallback _drag(WidgetTester tester) {
  final action = tester
      .widget<ReorderableBuilder<FavoriteItem>>(
        find.byType(ReorderableBuilder<FavoriteItem>),
      )
      .onReorder!;
  return () => action((items) => items.reversed.toList());
}

List<String> _order(WidgetTester tester) => tester
    .widget<ReorderableBuilder<FavoriteItem>>(
      find.byType(ReorderableBuilder<FavoriteItem>, skipOffstage: false),
    )
    .children!
    .map((child) => ((child as Padding).child! as ComicTile).comic.id)
    .toList();

List<String> _parentOrder(WidgetTester tester) => tester
    .widget<SliverGridComics>(
      find.byType(SliverGridComics, skipOffstage: false),
    )
    .comics
    .map((comic) => comic.id)
    .toList();

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

  for (final reason in [
    'removed',
    'covered',
    'retargeted',
    'closed',
    'frozen',
    'registry',
    'manager',
    'connection',
    'path',
    'folder',
  ]) {
    testWidgets('old Reorder menu cannot present after $reason', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      final retained = _menu(tester);
      final path = App.dataPath;
      addTearDown(() => App.dataPath = path);
      if (reason == 'removed') {
        host.content.value = const Text('Removed');
      } else if (reason == 'retargeted') {
        host.content.value = host.page('Other');
      } else if (reason == 'covered') {
        host.cover();
      } else if (reason == 'closed') {
        await settleSidebarWork(tester, host.registry.closeAndWait);
      } else if (reason == 'frozen') {
        host.allowed = false;
      } else if (reason == 'registry') {
        await host.replaceRegistry(tester);
      } else if (reason == 'manager') {
        await _replaceFavorites(tester, _Manager());
      } else if (reason == 'connection') {
        host.manager.connectionGeneration++;
      } else if (reason == 'folder') {
        host.manager.contents.remove('Original');
      } else {
        App.dataPath = '$path/synthetic-order-replacement';
      }
      await pumpSidebar(tester);
      retained();
      await pumpSidebar(tester);
      expect(find.byType(ReorderableBuilder<FavoriteItem>), findsNothing);
      expect(host.manager.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final drag in [false, true]) {
    testWidgets(
      'current comic ${drag ? 'drag' : 'reverse'} persists and returns its order',
      (tester) async {
        final host = _Host();
        await host.mount(tester);
        await _open(tester);
        (drag ? _drag(tester) : _reverse(tester))();
        await settleSidebarWork(tester, () => host.manager.settled);
        await pumpSidebar(tester);
        expect(_order(tester), ['C', 'B', 'A']);
        expect(host.manager.writes, hasLength(1));
        expect(host.manager.writes.single.$1, 'Original');
        expect(host.manager.writes.single.$2, ['C', 'B', 'A']);
        host.navigator.pop();
        await pumpSidebar(tester);
        expect(_parentOrder(tester), ['C', 'B', 'A']);
        expect(tester.takeException(), isNull);
      },
    );

    for (final reason in [
      'removed',
      'covered',
      'frozen',
      'closed',
      'registry',
      'manager',
      'connection',
      'path',
      'parent',
      'retargeted',
      'folder',
    ]) {
      testWidgets(
        'retained comic ${drag ? 'drag' : 'reverse'} is inert after $reason',
        (tester) async {
          final host = _Host();
          await host.mount(tester);
          await _open(tester);
          final retained = drag ? _drag(tester) : _reverse(tester);
          final path = App.dataPath;
          addTearDown(() => App.dataPath = path);
          if (reason == 'removed') {
            host.navigator.pop();
          } else if (reason == 'covered') {
            host.cover();
          } else if (reason == 'frozen') {
            host.allowed = false;
          } else if (reason == 'closed') {
            await settleSidebarWork(tester, host.registry.closeAndWait);
          } else if (reason == 'registry') {
            await host.replaceRegistry(tester);
          } else if (reason == 'manager') {
            await _replaceFavorites(tester, _Manager());
          } else if (reason == 'connection') {
            host.manager.connectionGeneration++;
          } else if (reason == 'parent') {
            host.content.value = const Text('Removed parent');
          } else if (reason == 'retargeted') {
            host.content.value = host.page('Other');
          } else if (reason == 'folder') {
            host.manager.contents.remove('Original');
          } else {
            App.dataPath = '$path/synthetic-order-replacement';
          }
          await pumpSidebar(tester);
          expect(retained, returnsNormally);
          await pumpSidebar(tester);
          expect(host.manager.writes, isEmpty);
          if (reason != 'removed') expect(_order(tester), ['A', 'B', 'C']);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final replacement in ['manager', 'connection', 'path']) {
    testWidgets('queued comic order cannot enter a replacement $replacement', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      await _open(tester);
      final release = Completer<void>();
      final path = App.dataPath;
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        App.dataPath = path;
      });
      final next = _Manager();
      final replacing = AppDataOperations.instance.run(() async {
        await release.future;
        if (replacement == 'manager') {
          await _replaceFavorites(tester, next);
        } else if (replacement == 'connection') {
          host.manager.connectionGeneration++;
        } else {
          App.dataPath = '$path/synthetic-order-replacement';
        }
      });
      _reverse(tester)();
      await pumpSidebar(tester);
      expect(host.manager.writes, isEmpty);
      release.complete();
      await settleSidebarWork(tester, () => replacing);
      await pumpSidebar(tester);
      expect(host.manager.writes, isEmpty);
      expect(next.writes, isEmpty);
      _back(tester)();
      await pumpSidebar(tester);
      expect(find.byType(ReorderableBuilder<FavoriteItem>), findsNothing);
      await settleSidebarWork(tester, host.registry.closeAndWait);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('accepted order never replaces a retargeted parent folder', (
    tester,
  ) async {
    final host = _Host();
    final pending = Completer<void>();
    host.manager.saving = () => pending.future;
    await host.mount(tester);
    addTearDown(() {
      if (!pending.isCompleted) pending.complete();
    });
    await _open(tester);
    _reverse(tester)();
    await pumpSidebar(tester);
    host.content.value = host.page('Other');
    await pumpSidebar(tester);
    expect(_parentOrder(tester), ['X', 'Y']);
    pending.complete();
    await settleSidebarWork(tester, () => host.manager.settled);
    await pumpSidebar(tester);
    host.navigator.pop();
    await pumpSidebar(tester);
    expect(_parentOrder(tester), ['X', 'Y']);
    expect(tester.takeException(), isNull);
  });

  for (final window in [false, true]) {
    for (final fails in [false, true]) {
      testWidgets(
        'original closing host joins comic order: window=$window fails=$fails',
        (tester) async {
          final host = _Host()..window = window;
          final pending = Completer<void>();
          final failure = StateError('original order write');
          final stack = StackTrace.fromString('original order stack');
          if (fails) host.expectedCloseFailure = failure;
          host.manager.saving = () async {
            await pending.future;
            if (fails) Error.throwWithStackTrace(failure, stack);
          };
          await host.mount(tester);
          addTearDown(() {
            if (!pending.isCompleted) pending.complete();
          });
          await _open(tester);
          _reverse(tester)();
          await pumpSidebar(tester);
          Object? closeFailure;
          var closed = false;
          Future<void>? closing;
          if (window) {
            host.closeWindow(tester);
          } else {
            closing = host.registry.closeAndWait().then<void>(
              (_) => closed = true,
              onError: (Object error) => closeFailure = error,
            );
          }
          await pumpSidebar(tester);
          expect(closed, isFalse);
          expect(host.exits, 0);
          pending.complete();
          await settleSidebarWork(tester, () => host.manager.settled);
          if (closing != null) await settleSidebarWork(tester, () => closing!);
          await pumpSidebar(tester);
          if (window) closeFailure = tester.takeException();
          if (fails) {
            expect(closeFailure, isNotNull);
            expect(sidebarCauses(closeFailure!), contains(same(failure)));
          } else {
            expect(closeFailure, isNull);
            expect(window ? host.exits == 1 : closed, isTrue);
          }
          expect(tester.takeException(), isNull);
          if (window && fails) {
            // The old page reports the same failed write again on disposal.
            // Dispose inside the test body so Flutter can collect that report;
            // the shutdown assertions above still require the original failure.
            await tester.pumpWidget(const SizedBox());
            await pumpSidebar(tester);
            final reported = tester.takeException();
            if (reported != null) expect(reported, same(failure));
          }
        },
      );
    }
  }

  testWidgets('replacement application cannot take the old order wait', (
    tester,
  ) async {
    final host = _Host();
    final pending = Completer<void>();
    host.manager.saving = () => pending.future;
    await host.mount(tester);
    addTearDown(() {
      if (!pending.isCompleted) pending.complete();
    });
    await _open(tester);
    _reverse(tester)();
    await pumpSidebar(tester);
    final next = await host.replaceRegistry(tester);
    var closed = false;
    final closing = host.registry.closeAndWait().then<void>(
      (_) => closed = true,
    );
    await settleSidebarWork(tester, next.closeAndWait);
    await pumpSidebar(tester);
    expect(closed, isFalse);
    pending.complete();
    await settleSidebarWork(tester, () => closing);
    expect(closed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('comic reorder uses and leaves the nearest Navigator', (
    tester,
  ) async {
    final host = _Host()..nested = true;
    await host.mount(tester);
    await _open(tester);
    expect(host.navigator.canPop(), isTrue);
    expect(appNavigation.rootNavigatorKey.currentState!.canPop(), isFalse);
    _reverse(tester)();
    await settleSidebarWork(tester, () => host.manager.settled);
    _back(tester)();
    await pumpSidebar(tester);
    expect(host.navigator.canPop(), isFalse);
    expect(_parentOrder(tester), ['C', 'B', 'A']);
    expect(tester.takeException(), isNull);
  });

  for (final systemBack in [false, true]) {
    testWidgets('leaving comic order waits and pops once: system=$systemBack', (
      tester,
    ) async {
      final host = _Host();
      final pending = Completer<void>();
      host.manager.saving = () => pending.future;
      await host.mount(tester);
      addTearDown(() {
        if (!pending.isCompleted) pending.complete();
      });
      await _open(tester);
      final reverse = _reverse(tester);
      final back = _back(tester);
      reverse();
      await pumpSidebar(tester);
      if (systemBack) {
        await host.navigator.maybePop();
      } else {
        back();
      }
      await pumpSidebar(tester);
      back();
      reverse();
      expect(find.byType(ReorderableBuilder<FavoriteItem>), findsOneWidget);
      expect(host.manager.writes, hasLength(1));
      pending.complete();
      await settleSidebarWork(tester, () => host.manager.settled);
      await pumpSidebar(tester);
      expect(find.byType(ReorderableBuilder<FavoriteItem>), findsNothing);
      expect(_parentOrder(tester), ['C', 'B', 'A']);
      expect(host.navigator.canPop(), isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  for (final reason in ['parent', 'retargeted', 'database']) {
    testWidgets('current comic editor can leave its retired $reason', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      await _open(tester);
      if (reason == 'parent') {
        host.content.value = const Text('Removed parent');
      } else if (reason == 'retargeted') {
        host.content.value = host.page('Other');
      } else {
        await _replaceFavorites(tester, _Manager());
      }
      await pumpSidebar(tester);
      _back(tester)();
      await pumpSidebar(tester);
      expect(find.byType(ReorderableBuilder<FavoriteItem>), findsNothing);
      expect(host.manager.writes, isEmpty);
      expect(host.navigator.canPop(), isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  for (final detached in [false, true]) {
    testWidgets(
      'original application waits for accepted order after detach=$detached',
      (tester) async {
        final host = _Host();
        final pending = Completer<void>();
        host.manager.saving = () => pending.future;
        await host.mount(tester);
        addTearDown(() {
          if (!pending.isCompleted) pending.complete();
        });
        await _open(tester);
        final back = _back(tester);
        _reverse(tester)();
        await pumpSidebar(tester);
        if (detached) {
          await tester.pumpWidget(const SizedBox());
        } else {
          host.cover();
        }
        await pumpSidebar(tester);
        back();
        var closed = false;
        final closing = host.registry.closeAndWait().then<void>(
          (_) => closed = true,
        );
        await pumpSidebar(tester);
        expect(closed, isFalse);
        if (!detached) expect(find.text('Newer page'), findsOneWidget);
        pending.complete();
        await settleSidebarWork(tester, () => closing);
        expect(closed, isTrue);
        expect(host.manager.contents['Original']!.map((item) => item.id), [
          'C',
          'B',
          'A',
        ]);
        if (!detached) expect(find.text('Newer page'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('a later complete order repairs a failed earlier assignment', (
    tester,
  ) async {
    final host = _Host();
    final pending = Completer<void>();
    var calls = 0;
    host.manager.saving = () async {
      if (++calls == 1) {
        await pending.future;
        throw StateError('first order');
      }
    };
    await host.mount(tester);
    addTearDown(() {
      if (!pending.isCompleted) pending.complete();
    });
    await _open(tester);
    _reverse(tester)();
    _reverse(tester)();
    await pumpSidebar(tester);
    expect(host.manager.writes, hasLength(1));
    expect(_order(tester), ['A', 'B', 'C']);
    pending.complete();
    await settleSidebarWork(tester, () => host.manager.settled);
    await pumpSidebar(tester);
    expect(host.manager.writes.map((write) => write.$2), [
      ['C', 'B', 'A'],
      ['A', 'B', 'C'],
    ]);
    expect(_retryButton, findsNothing);
    _back(tester)();
    await pumpSidebar(tester);
    expect(_parentOrder(tester), ['A', 'B', 'C']);
    await settleSidebarWork(tester, host.registry.closeAndWait);
    expect(tester.takeException(), isNull);
  });

  for (final state in PersistenceCommitState.values) {
    testWidgets(
      'explicit comic order retry is idempotent after ${state.name}',
      (tester) async {
        final host = _Host()..window = true;
        final cause = StateError('order ${state.name}');
        final stack = StackTrace.fromString('order persistence stack');
        final failure = PersistenceFailure(
          commitState: state,
          cause: cause,
          stackTrace: stack,
        );
        var calls = 0;
        host.manager.saving = () async {
          if (++calls == 1) Error.throwWithStackTrace(failure, stack);
        };
        await host.mount(tester);
        await _open(tester);
        _reverse(tester)();
        await settleSidebarWork(tester, () => host.manager.settled);
        await pumpSidebar(tester);
        expect(host.manager.writes, hasLength(1));
        expect(_retryButton, findsOneWidget);
        final retry = _retry(tester);
        host.closeWindow(tester);
        await pumpSidebar(tester);
        expect(tester.takeException(), same(failure));
        expect(host.exits, 0);
        expect(host.manager.writes, hasLength(1));
        retry();
        await settleSidebarWork(tester, () => host.manager.settled);
        await pumpSidebar(tester);
        expect(host.manager.writes.map((write) => write.$2), [
          ['C', 'B', 'A'],
          ['C', 'B', 'A'],
        ]);
        expect(_retryButton, findsNothing);
        host.closeWindow(tester);
        await pumpSidebar(tester);
        expect(host.exits, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final reason in [
    'removed',
    'covered',
    'frozen',
    'registry',
    'manager',
    'connection',
    'path',
    'parent',
    'retargeted',
  ]) {
    testWidgets(
      'failed comic order cannot retry through an obsolete $reason control',
      (tester) async {
        final host = _Host();
        final failure = StateError('failed original order');
        host.expectedCloseFailure = failure;
        host.manager.saving = () async => throw failure;
        await host.mount(tester);
        await _open(tester);
        _reverse(tester)();
        await settleSidebarWork(tester, () => host.manager.settled);
        await pumpSidebar(tester);
        final retry = _retry(tester);
        final path = App.dataPath;
        addTearDown(() => App.dataPath = path);
        if (reason == 'removed') {
          host.navigator.pop();
        } else if (reason == 'covered') {
          host.cover();
        } else if (reason == 'frozen') {
          host.allowed = false;
        } else if (reason == 'registry') {
          await host.replaceRegistry(tester);
        } else if (reason == 'manager') {
          await _replaceFavorites(tester, _Manager());
        } else if (reason == 'connection') {
          host.manager.connectionGeneration++;
        } else if (reason == 'path') {
          App.dataPath = '$path/synthetic-order-replacement';
        } else if (reason == 'parent') {
          host.content.value = const Text('Removed parent');
        } else {
          host.content.value = host.page('Other');
        }
        await pumpSidebar(tester);
        retry();
        await pumpSidebar(tester);
        expect(host.manager.writes, hasLength(1));
        Object? reported;
        await settleSidebarWork(tester, () async {
          try {
            await host.registry.closeAndWait();
          } catch (error) {
            reported = error;
          }
        });
        expect(reported, isNotNull);
        expect(sidebarCauses(reported!), contains(same(failure)));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'covered order failure remains retryable when its route returns',
    (tester) async {
      final host = _Host();
      final pending = Completer<void>();
      var calls = 0;
      host.manager.saving = () async {
        if (++calls == 1) {
          await pending.future;
          throw StateError('covered original order');
        }
      };
      await host.mount(tester);
      addTearDown(() {
        if (!pending.isCompleted) pending.complete();
      });
      await _open(tester);
      final back = _back(tester);
      _reverse(tester)();
      host.cover();
      await pumpSidebar(tester);
      pending.complete();
      await settleSidebarWork(tester, () => host.manager.settled);
      await pumpSidebar(tester);
      expect(host.messages, isEmpty);
      back();
      await pumpSidebar(tester);
      expect(find.text('Newer page'), findsOneWidget);
      host.navigator.pop();
      await pumpSidebar(tester);
      _retry(tester)();
      await settleSidebarWork(tester, () => host.manager.settled);
      await pumpSidebar(tester);
      expect(host.manager.writes, hasLength(2));
      back();
      await pumpSidebar(tester);
      expect(_parentOrder(tester), ['C', 'B', 'A']);
      await settleSidebarWork(tester, host.registry.closeAndWait);
      expect(tester.takeException(), isNull);
    },
  );

  for (final fails in [false, true]) {
    testWidgets(
      'accepted comic order stays with its original window: fails=$fails',
      (tester) async {
        final host = _Host()..multipleWindows = true;
        final pending = Completer<void>();
        final failure = StateError('original window order');
        if (fails) host.expectedCloseFailure = failure;
        host.manager.saving = () async {
          await pending.future;
          if (fails) throw failure;
        };
        await host.mount(tester);
        addTearDown(() {
          if (!pending.isCompleted) pending.complete();
        });
        await _open(tester);
        final reverse = _reverse(tester);
        reverse();
        await pumpSidebar(tester);
        host.useSecondWindow = true;
        await tester.pumpWidget(host.app());
        await pumpSidebar(tester);
        reverse();
        expect(host.manager.writes, hasLength(1));
        (host.secondWindow.currentState! as WindowListener).onWindowClose();
        (host.firstWindow.currentState! as WindowListener).onWindowClose();
        await pumpSidebar(tester);
        expect(host.secondExits, 1);
        expect(host.exits, 0);
        pending.complete();
        await settleSidebarWork(tester, () => host.manager.settled);
        await pumpSidebar(tester);
        expect(host.exits, fails ? 0 : 1);
        expect(tester.takeException(), fails ? same(failure) : isNull);
      },
    );
  }

  for (final reason in ['parent', 'retargeted', 'database']) {
    testWidgets('failed retired comic editor can leave: $reason', (
      tester,
    ) async {
      final host = _Host();
      final failure = StateError('failed retired order');
      final stack = StackTrace.fromString('retired order stack');
      host.expectedCloseFailure = failure;
      host.manager.saving = () async =>
          Error.throwWithStackTrace(failure, stack);
      await host.mount(tester);
      await _open(tester);
      _reverse(tester)();
      await settleSidebarWork(tester, () => host.manager.settled);
      await pumpSidebar(tester);
      if (reason == 'parent') {
        host.content.value = const Text('Removed parent');
      } else if (reason == 'retargeted') {
        host.content.value = host.page('Other');
      } else {
        await _replaceFavorites(tester, _Manager());
      }
      await pumpSidebar(tester);
      _back(tester)();
      await pumpSidebar(tester);
      expect(find.byType(ReorderableBuilder<FavoriteItem>), findsNothing);
      expect(host.manager.writes, hasLength(1));
      Object? reported;
      await settleSidebarWork(tester, () async {
        try {
          await host.registry.closeAndWait();
        } catch (error) {
          reported = error;
        }
      });
      final detail =
          (reported! as SelectionCleanupFailure).failures.single
              as ({Object error, StackTrace stack});
      expect(detail.error, same(failure));
      expect(detail.stack, same(stack));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'retired failed comic editor still respects another route owner',
    (tester) async {
      final host = _Host();
      final failure = StateError('failed guarded order');
      host.expectedCloseFailure = failure;
      host.manager.saving = () async => throw failure;
      await host.mount(tester);
      await _open(tester);
      _reverse(tester)();
      await settleSidebarWork(tester, () => host.manager.settled);
      await pumpSidebar(tester);
      final route = ModalRoute.of(
        tester.element(find.byType(ReorderableBuilder<FavoriteItem>)),
      )!;
      final guard = _OtherPopGuard();
      route.registerPopEntry(guard);
      addTearDown(() {
        route.unregisterPopEntry(guard);
        guard.canPopNotifier.dispose();
      });
      host.content.value = const Text('Removed parent');
      await pumpSidebar(tester);
      _back(tester)();
      await pumpSidebar(tester);
      expect(find.byType(ReorderableBuilder<FavoriteItem>), findsOneWidget);
      guard.canPopNotifier.value = true;
      _back(tester)();
      await pumpSidebar(tester);
      expect(find.byType(ReorderableBuilder<FavoriteItem>), findsNothing);
      expect(host.manager.writes, hasLength(1));
      Object? reported;
      await settleSidebarWork(tester, () async {
        try {
          await host.registry.closeAndWait();
        } catch (error) {
          reported = error;
        }
      });
      expect(sidebarCauses(reported!), contains(same(failure)));
      expect(tester.takeException(), isNull);
    },
  );
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
