import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/favorites/folder_order_dialog.dart';
import 'package:venera_next/features/favorites/favorite_models.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
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

class _Manager extends Fake implements LocalFavoritesManager {
  @override
  int connectionGeneration = 1;
  List<String> order = ['A', 'B', 'C'];
  final writes = <List<String>>[];
  Future<void> Function(List<String>)? save;
  @override
  List<String> get folderNames => List.of(order);
  @override
  Future<void> updateOrder(List<String> values) async {
    final snapshot = List<String>.of(values);
    writes.add(snapshot);
    await save?.call(snapshot);
    order = snapshot;
  }
}

class _Navigator extends Navigator {
  const _Navigator({super.key, super.onGenerateRoute});
  @override
  NavigatorState createState() => _NavigatorState();
}

class _NavigatorState extends NavigatorState {
  bool fails = false;
  final failure = StateError('original order popup removal');
  final stack = StackTrace.fromString('original order popup stack');
  final attempts = <Route<dynamic>>[];
  @override
  void removeRoute<T extends Object?>(Route<T> route, [T? result]) {
    attempts.add(route);
    if (fails) Error.throwWithStackTrace(failure, stack);
    super.removeRoute(route, result);
  }
}

class _Host {
  final registry = SelectionTaskRegistry();
  final manager = _Manager();
  final messages = <String>[];
  late BuildContext context;
  bool allowed = true;
  bool window = false;
  Widget? content;
  int exits = 0;
  _NavigatorState get navigator =>
      appNavigation.rootNavigatorKey.currentState! as _NavigatorState;

  Widget app({SelectionTaskRegistry? tasks}) => _libraryView(
    MaterialApp(
      builder: (_, _) {
        Widget child = _Navigator(
          key: appNavigation.rootNavigatorKey,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (value) {
              context = value;
              return Scaffold(body: content ?? const Text('Original owner'));
            },
          ),
        );
        if (window) child = WindowFrame(child, onExit: () => exits++);
        return SelectionTasksScope(
          registry: tasks ?? registry,
          child: NavigationAdmission(
            allowsNavigation: () => allowed,
            child: child,
          ),
        );
      },
    ),
  );

  Future<void> mount(
    WidgetTester tester, {
    LocalFavoritesManager? database,
  }) async {
    final original = _favoritesOwner;
    final language = appdata.settings['language'];
    _favoritesOwner = database ?? manager;
    appdata.settings['language'] = 'en-US';
    registerShowMessageHandler((_, message) => messages.add(message));
    addTearDown(() async {
      final navigation = appNavigation.rootNavigatorKey.currentState;
      if (navigation is _NavigatorState) navigation.fails = false;
      await tester.pumpWidget(const SizedBox());
      await pumpSidebar(tester);
      await settleSidebarWork(tester, registry.closeAndWait);
      _favoritesOwner = original;
      appdata.settings['language'] = language;
      registerShowMessageHandler((_, _) {});
    });
    await tester.pumpWidget(app());
  }

  Future<void> open() => sortFolders(context);

  Route<dynamic> route(WidgetTester tester) => tester
      .widget<PopupIndicatorWidget>(find.byType(PopupIndicatorWidget))
      .route!;

  Route<void> cover() {
    final route = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('Newer page')),
    );
    navigator.push(route);
    return route;
  }

  void closeWindow(WidgetTester tester) =>
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
}

ReorderCallback _reorder(WidgetTester tester) => tester
    .widget<ReorderableListView>(find.byType(ReorderableListView))
    .onReorder;

VoidCallback _help(WidgetTester tester) => tester
    .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.help_outline))
    .onPressed!;

VoidCallback _back(WidgetTester tester) => tester
    .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.arrow_back_sharp))
    .onPressed!;

List<String> _labels(WidgetTester tester) => tester
    .widgetList<ListTile>(find.byType(ListTile))
    .map((tile) => (tile.title! as Text).data!)
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

  for (final built in [false, true]) {
    testWidgets(
      'folder sort ends when its Navigator is disposed: built=$built',
      (tester) async {
        final host = _Host();
        await host.mount(tester);
        var ended = false;
        host.open().then<void>((_) => ended = true).ignore();
        if (built) {
          await pumpSidebar(tester);
        } else {
          await tester.idle();
        }
        await tester.pumpWidget(const SizedBox());
        await pumpSidebar(tester);
        expect(ended, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final reason in ['closed', 'frozen', 'covered']) {
    testWidgets('original caller rejects new sort after $reason', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      if (reason == 'closed') {
        await settleSidebarWork(tester, host.registry.closeAndWait);
      } else if (reason == 'frozen') {
        host.allowed = false;
      } else {
        host.cover();
        await pumpSidebar(tester);
      }
      host.open().ignore();
      await pumpSidebar(tester);
      expect(find.byType(ReorderableListView), findsNothing);
      expect(host.manager.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final reason in ['covered', 'frozen', 'removed']) {
    testWidgets('retired reorder callback cannot change the draft: $reason', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      final result = host.open();
      await pumpSidebar(tester);
      final retained = _reorder(tester);
      if (reason == 'covered') {
        host.cover();
      } else if (reason == 'frozen') {
        host.allowed = false;
      } else {
        host.navigator.pop();
      }
      await pumpSidebar(tester);
      retained(0, 3);
      await pumpSidebar(tester);
      if (reason == 'covered') {
        host.navigator.pop();
        await pumpSidebar(tester);
      }
      if (reason != 'removed') {
        expect(_labels(tester), ['A', 'B', 'C']);
        host.navigator.pop();
      }
      await settleSidebarWork(tester, () => result);
      expect(host.manager.order, ['A', 'B', 'C']);
      expect(tester.takeException(), isNull);
    });
  }

  for (final action in ['help', 'back']) {
    testWidgets('covered sort $action does not affect the newer route', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      host.open().ignore();
      await pumpSidebar(tester);
      final retained = action == 'help' ? _help(tester) : _back(tester);
      final newer = host.cover();
      await pumpSidebar(tester);
      retained();
      await pumpSidebar(tester);
      expect(newer.isCurrent, isTrue);
      expect(find.text('Long press and drag to reorder.'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('ordinary dismissal saves the final folder order once', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    final result = host.open();
    await pumpSidebar(tester);
    _reorder(tester)(0, 3);
    await tester.pump();
    expect(host.manager.writes, isEmpty);
    _back(tester)();
    await settleSidebarWork(tester, () => result);
    expect(host.manager.writes, [
      ['B', 'C', 'A'],
    ]);
    expect(host.manager.order, ['B', 'C', 'A']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'application closes its sort popup and joins the accepted order',
    (tester) async {
      final host = _Host();
      final pending = Completer<void>();
      host.manager.save = (_) => pending.future;
      await host.mount(tester);
      addTearDown(() {
        if (!pending.isCompleted) pending.complete();
      });
      var ended = false;
      final result = host.open().then<void>((_) => ended = true);
      await pumpSidebar(tester);
      _reorder(tester)(0, 3);
      var closed = false;
      final closing = host.registry.closeAndWait().then<void>(
        (_) => closed = true,
      );
      try {
        await pumpSidebar(tester);
        expect(closed, isFalse);
        expect(ended, isFalse);
        expect(host.manager.writes, [
          ['B', 'C', 'A'],
        ]);
      } finally {
        pending.complete();
        if (find.byType(ReorderableListView).evaluate().isNotEmpty) {
          host.navigator.pop();
        }
        await settleSidebarWork(tester, () => Future.wait([result, closing]));
      }
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('window waits for order persistence after popup dismissal', (
    tester,
  ) async {
    final host = _Host()..window = true;
    final pending = Completer<void>();
    host.manager.save = (_) => pending.future;
    await host.mount(tester);
    addTearDown(() {
      if (!pending.isCompleted) pending.complete();
    });
    final result = host.open();
    await pumpSidebar(tester);
    _reorder(tester)(0, 3);
    host.navigator.pop();
    await pumpSidebar(tester);
    expect(host.manager.writes, [
      ['B', 'C', 'A'],
    ]);
    host.closeWindow(tester);
    try {
      await pumpSidebar(tester);
      expect(host.exits, 0);
    } finally {
      pending.complete();
      await settleSidebarWork(tester, () => result);
      await pumpSidebar(tester);
    }
    expect(host.exits, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed sort removal ends its waiter and remains retryable', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    Object? presentationError;
    final result = host.open().catchError((Object error) {
      presentationError = error;
    });
    await pumpSidebar(tester);
    final original = host.route(tester);
    _reorder(tester)(0, 3);
    host.navigator.fails = true;
    Object? failure;
    await settleSidebarWork(
      tester,
      () => host.registry.closeAndWait().catchError((Object error) {
        failure = error;
      }),
    );
    expect(failure, isA<SelectionCleanupFailure>());
    expect(sidebarCauses(failure!), contains(same(host.navigator.failure)));
    await settleSidebarWork(tester, () => result);
    expect(
      sidebarCauses(presentationError!),
      contains(same(host.navigator.failure)),
    );
    expect(host.navigator.attempts, [original]);
    host.navigator.fails = false;
    await settleSidebarWork(tester, host.registry.closeAndWait);
    expect(host.navigator.attempts, [original, original]);
    expect(host.manager.writes, [
      ['B', 'C', 'A'],
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacement manager cannot receive an old folder order', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    final result = host.open();
    await pumpSidebar(tester);
    _reorder(tester)(0, 3);
    final replacement = _Manager();
    await _replaceFavorites(tester, replacement);
    host.navigator.pop();
    await settleSidebarWork(tester, () => result);
    expect(host.manager.writes, isEmpty);
    expect(replacement.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final state in PersistenceCommitState.values) {
    testWidgets(
      'sort Future preserves persistence failure and commitment: $state',
      (tester) async {
        final host = _Host();
        final failure = PersistenceFailure(
          commitState: state,
          cause: StateError('original folder order save'),
          stackTrace: StackTrace.current,
        );
        host.manager.save = (_) async => throw failure;
        await host.mount(tester);
        Object? reported;
        final result = host.open().catchError((Object error) {
          reported = error;
        });
        await pumpSidebar(tester);
        _reorder(tester)(0, 3);
        host.navigator.pop();
        await settleSidebarWork(tester, () => result);
        expect(reported, same(failure));
        expect(host.manager.writes, [
          ['B', 'C', 'A'],
        ]);
        await settleSidebarWork(tester, host.registry.closeAndWait);
        expect(host.manager.writes.length, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('original application joins save after registry replacement', (
    tester,
  ) async {
    final host = _Host();
    final pending = Completer<void>();
    host.manager.save = (_) => pending.future;
    await host.mount(tester);
    addTearDown(() {
      if (!pending.isCompleted) pending.complete();
    });
    final result = host.open();
    await pumpSidebar(tester);
    host.navigator.pop();
    await pumpSidebar(tester);
    final replacement = SelectionTaskRegistry();
    await tester.pumpWidget(host.app(tasks: replacement));
    var closed = false;
    final closing = host.registry.closeAndWait().then<void>(
      (_) => closed = true,
    );
    await settleSidebarWork(tester, replacement.closeAndWait);
    try {
      expect(closed, isFalse);
    } finally {
      pending.complete();
      await settleSidebarWork(tester, () => Future.wait([result, closing]));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('application closes both the original order popup and its help', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    host.open().ignore();
    await pumpSidebar(tester);
    final original = host.route(tester);
    _help(tester)();
    await pumpSidebar(tester);
    final help = ModalRoute.of(
      tester.element(find.text('Long press and drag to reorder.')),
    )!;
    final newer = host.cover();
    await pumpSidebar(tester);
    await settleSidebarWork(tester, host.registry.closeAndWait);
    expect(original.isActive, isFalse);
    expect(help.isActive, isFalse);
    expect(newer.isCurrent, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final window in [false, true]) {
    for (final removalFails in [false, true]) {
      testWidgets(
        'closing joins the original save failure: window=$window removal=$removalFails',
        (tester) async {
          final host = _Host()..window = window;
          final pending = Completer<void>();
          final stack = StackTrace.fromString(
            'original order persistence stack',
          );
          final failure = PersistenceFailure(
            commitState: PersistenceCommitState.unknown,
            cause: StateError('original order save failed'),
            stackTrace: stack,
          );
          host.manager.save = (_) async {
            await pending.future;
            Error.throwWithStackTrace(failure, stack);
          };
          await host.mount(tester);
          addTearDown(() {
            if (!pending.isCompleted) pending.complete();
          });
          Object? reported;
          StackTrace? reportedStack;
          final result = host.open().catchError((
            Object error,
            StackTrace trace,
          ) {
            reported = error;
            reportedStack = trace;
          });
          await pumpSidebar(tester);
          final original = host.route(tester);
          _reorder(tester)(0, 3);
          host.navigator.fails = removalFails;
          Object? closeFailure;
          Future<void>? closing;
          if (window) {
            host.closeWindow(tester);
          } else {
            closing = host.registry.closeAndWait().catchError((Object error) {
              closeFailure = error;
            });
          }
          await pumpSidebar(tester);
          expect(host.exits, 0);
          expect(reported, isNull);
          expect(closeFailure, isNull);
          expect(host.manager.writes, [
            ['B', 'C', 'A'],
          ]);
          pending.complete();
          await settleSidebarWork(tester, () => result);
          if (closing != null) await settleSidebarWork(tester, () => closing!);
          await pumpSidebar(tester);
          if (window) closeFailure = tester.takeException();
          expect(closeFailure, isNotNull);
          expect(sidebarCauses(closeFailure!), contains(same(failure)));
          expect(sidebarCauses(reported!), contains(same(failure)));
          if (removalFails) {
            expect(
              sidebarCauses(closeFailure!),
              contains(same(host.navigator.failure)),
            );
            expect(
              (reported as SelectionCleanupFailure).operationStack,
              same(stack),
            );
          } else {
            expect(reported, same(failure));
            expect(reportedStack, same(stack));
          }
          expect(host.exits, 0);
          expect(host.navigator.attempts, [original]);
          host.navigator.fails = false;
          if (window) {
            host.closeWindow(tester);
            await pumpSidebar(tester);
            expect(host.exits, 1);
          } else {
            await settleSidebarWork(tester, host.registry.closeAndWait);
          }
          expect(host.manager.writes.length, 1);
          expect(host.navigator.attempts, [
            original,
            if (removalFails) original,
          ]);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final change in ['connection', 'path', 'manager']) {
    testWidgets(
      'queued old folder order is retired after $change replacement',
      (tester) async {
        final host = _Host();
        await host.mount(tester);
        final result = host.open();
        await pumpSidebar(tester);
        _reorder(tester)(0, 3);
        final previousPath = App.dataPath;
        final replacement = _Manager();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
          App.dataPath = previousPath;
        });
        final replacing = AppDataOperations.instance.run(() async {
          await release.future;
          if (change == 'connection') {
            host.manager.connectionGeneration++;
          } else if (change == 'path') {
            App.dataPath = p.join(previousPath, 'synthetic-order-replacement');
          } else {
            await _replaceFavorites(tester, replacement);
          }
        });
        host.navigator.pop();
        await pumpSidebar(tester);
        expect(host.manager.writes, isEmpty);
        release.complete();
        await settleSidebarWork(tester, () => Future.wait([replacing, result]));
        expect(host.manager.writes, isEmpty);
        expect(replacement.writes, isEmpty);
        expect(host.messages, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('retired database disables editing but still permits dismissal', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    final result = host.open();
    await pumpSidebar(tester);
    final reorder = _reorder(tester);
    final help = _help(tester);
    await _replaceFavorites(tester, _Manager());
    reorder(0, 3);
    help();
    await pumpSidebar(tester);
    expect(_labels(tester), ['A', 'B', 'C']);
    expect(find.text('Long press and drag to reorder.'), findsNothing);
    _back(tester)();
    await settleSidebarWork(tester, () => result);
    expect(host.manager.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removed caller still permits closing its visible sort popup', (
    tester,
  ) async {
    final host = _Host();
    final visible = ValueNotifier(true);
    late BuildContext caller;
    host.content = ValueListenableBuilder<bool>(
      valueListenable: visible,
      builder: (_, show, _) => show
          ? Builder(
              builder: (context) {
                caller = context;
                return const Text('Original trigger');
              },
            )
          : const Text('Removed trigger'),
    );
    await host.mount(tester);
    addTearDown(visible.dispose);
    final result = sortFolders(caller);
    await pumpSidebar(tester);
    _reorder(tester)(0, 3);
    visible.value = false;
    await pumpSidebar(tester);
    expect(caller.mounted, isFalse);
    _reorder(tester)(0, 3);
    expect(_labels(tester), ['B', 'C', 'A']);
    final original = host.route(tester);
    _back(tester)();
    await pumpSidebar(tester);
    expect(original.isActive, isFalse);
    await settleSidebarWork(tester, () => result);
    expect(host.manager.writes, [
      ['B', 'C', 'A'],
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('frozen sort rejects back, help and barrier until it resumes', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    final result = host.open();
    await pumpSidebar(tester);
    final original = host.route(tester);
    host.allowed = false;
    _back(tester)();
    _help(tester)();
    await host.navigator.maybePop();
    await tester.tapAt(const Offset(5, 5));
    await pumpSidebar(tester);
    expect(original.isCurrent, isTrue);
    expect(host.manager.writes, isEmpty);
    expect(find.text('Long press and drag to reorder.'), findsNothing);
    host.allowed = true;
    await host.navigator.maybePop();
    await settleSidebarWork(tester, () => result);
    expect(host.manager.writes, [
      ['A', 'B', 'C'],
    ]);
    expect(tester.takeException(), isNull);
  });

  for (final covered in [false, true]) {
    testWidgets(
      'nested popup caller respects its outer route: covered=$covered',
      (tester) async {
        final host = _Host();
        await host.mount(tester);
        late BuildContext caller;
        final parent = PopUpWidget<void>(
          Builder(
            builder: (context) {
              caller = context;
              return const Material(child: Text('Nested caller'));
            },
          ),
        );
        host.navigator.push(parent);
        await pumpSidebar(tester);
        if (covered) host.cover();
        await pumpSidebar(tester);
        final result = sortFolders(caller);
        await pumpSidebar(tester);
        if (covered) {
          expect(find.byType(ReorderableListView), findsNothing);
          expect(host.manager.writes, isEmpty);
        } else {
          _reorder(tester)(0, 3);
          _back(tester)();
        }
        await settleSidebarWork(tester, () => result);
        if (!covered) {
          await pumpSidebar(tester);
          expect(parent.isCurrent, isTrue);
          expect(host.manager.order, ['B', 'C', 'A']);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'real SQLite sort preserves rows, links and reopened folder order',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'venera-folder-order-owned-',
      );
      final previousData = App.dataPath;
      final previousCache = App.cachePath;
      final previousManager = _favoritesOwner;
      final previousSettings = Map<String, dynamic>.from(
        appdata.toJson()['settings'] as Map,
      );
      App.dataPath = root.path;
      App.cachePath = root.path;
      _favoritesOwner = null;
      final database = _favoritesForView();
      addTearDown(() async {
        await tester.runAsync(() async {
          await AppDataOperations.instance.run(() async {});
          await database.closeAndWait();
        });
        _favoritesOwner = previousManager;
        previousSettings.forEach((key, value) => appdata.settings[key] = value);
        App.dataPath = previousData;
        App.cachePath = previousCache;
        final temporaryRoot = Directory.systemTemp.resolveSymbolicLinksSync();
        final owned = root.resolveSymbolicLinksSync();
        expect(p.isWithin(temporaryRoot, owned), isTrue);
        expect(p.basename(owned), startsWith('venera-folder-order-owned-'));
        root.deleteSync(recursive: true);
      });
      await tester.runAsync(() async {
        await database.init();
        for (final name in ['A', 'B', '引号 " C']) {
          await database.createFolder(name);
        }
        await database.linkFolderToNetwork(
          'B',
          'synthetic-source',
          'source-folder',
        );
        await database.addComic(
          'A',
          FavoriteItem(
            id: 'synthetic-id',
            name: 'Stored comic',
            coverPath: 'synthetic-cover',
            author: 'Synthetic author',
            type: ComicType.local,
            tags: ['one', 'two'],
          ),
        );
      });
      final host = _Host();
      await host.mount(tester, database: database);
      final original = List<String>.of(database.folderNames);
      final expected = [...original.skip(1), original.first];
      final beforeComic = database.getFolderComics('A').single;
      var notifications = 0;
      void changed() => notifications++;
      database.addListener(changed);
      addTearDown(() => database.removeListener(changed));
      final result = host.open();
      await pumpSidebar(tester);
      _reorder(tester)(0, original.length);
      await tester.pump();
      expect(database.folderNames, original);
      expect(notifications, 0);
      _back(tester)();
      await settleSidebarWork(tester, () => result);
      expect(database.folderNames, expected);
      expect(notifications, 1);
      expect(database.findLinked('B'), ('synthetic-source', 'source-folder'));
      expect(
        database.getFolderComics('A').single.toJson(),
        beforeComic.toJson(),
      );
      final raw = sqlite3.open(database.databasePath);
      try {
        expect(
          raw
              .select('PRAGMA table_info(folder_order)')
              .map((row) => row['name']),
          ['folder_name', 'order_value'],
        );
        expect(
          raw
              .select(
                'SELECT folder_name FROM folder_order ORDER BY order_value',
              )
              .map((row) => row['folder_name']),
          expected,
        );
      } finally {
        raw.dispose();
      }
      await tester.runAsync(() async {
        await database.closeAndWait();
        await database.init();
      });
      expect(database.folderNames, expected);
      expect(
        database.getFolderComics('A').single.toJson(),
        beforeComic.toJson(),
      );
      expect(database.findLinked('B'), ('synthetic-source', 'source-folder'));
      expect(tester.takeException(), isNull);
    },
  );
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
