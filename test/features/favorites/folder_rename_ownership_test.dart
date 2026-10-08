import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/favorites/favorite_models.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/favorites/favorites_page.dart';
import 'package:venera_next/features/favorites/folder_rename_dialog.dart';
import 'package:venera_next/features/favorites/local_favorites_page.dart';
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
  final names = ['Original', 'Other'];
  final listeners = <VoidCallback>{};
  final renames = <(String, String)>[];
  Future<void> Function()? saving;
  Future<List<FavoriteItem>>? query;
  int reads = 0;
  @override
  List<String> get folderNames => List.of(names);
  @override
  (String?, String?) findLinked(String folder) => (null, null);
  @override
  int folderComics(String folder) => query == null ? 0 : 600;
  @override
  bool existsFolder(String name) => names.contains(name);
  @override
  List<FavoriteItem> getFolderComics(String folder, {int? limit}) {
    reads++;
    return [];
  }

  @override
  Future<List<FavoriteItem>> getFolderComicsAsync(String folder) {
    reads++;
    return query!;
  }

  @override
  void addListener(VoidCallback listener) => listeners.add(listener);
  @override
  void removeListener(VoidCallback listener) => listeners.remove(listener);
  void notify() {
    for (final listener in listeners.toList()) {
      listener();
    }
  }

  void applyRename(String before, String after) {
    final index = names.indexOf(before);
    if (index < 0) throw StateError('Original folder no longer exists');
    names[index] = after;
    notify();
  }

  @override
  Future<void> rename(String before, String after) async {
    renames.add((before, after));
    try {
      await saving?.call();
    } on PersistenceFailure catch (error) {
      if (error.commitState == PersistenceCommitState.committed) {
        applyRename(before, after);
      }
      rethrow;
    }
    applyRename(before, after);
  }
}

class _Navigator extends Navigator {
  const _Navigator({super.key, super.onGenerateRoute});
  @override
  NavigatorState createState() => _NavigatorState();
}

class _NavigatorState extends NavigatorState {
  bool failPop = false;
  final failure = StateError('original rename dialog pop');
  final stack = StackTrace.fromString('original rename dialog pop stack');
  @override
  void pop<T extends Object?>([T? result]) {
    if (failPop) Error.throwWithStackTrace(failure, stack);
    super.pop(result);
  }
}

class _Host {
  final manager = _Manager();
  final registry = SelectionTaskRegistry();
  final selected = <String?>[];
  final messages = <String>[];
  final content = ValueNotifier<Widget>(const SizedBox());
  bool allowed = true;
  bool window = false;
  int lists = 0;
  int exits = 0;
  late BuildContext context;
  _NavigatorState get navigator =>
      appNavigation.rootNavigatorKey.currentState! as _NavigatorState;

  void refresh() => lists++;
  void select(bool network, String? folder) => selected.add(folder);
  Widget page([String folder = 'Original']) => LocalFavoritesPage(
    folder: folder,
    showFolders: () {},
    onFolderSelected: select,
    updateFolderList: refresh,
  );

  Widget app({SelectionTaskRegistry? tasks}) => MaterialApp(
    builder: (_, _) {
      Widget body = _Navigator(
        key: appNavigation.rootNavigatorKey,
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (value) {
            context = value;
            return Scaffold(
              body: ValueListenableBuilder<Widget>(
                valueListenable: content,
                builder: (_, value, _) => value,
              ),
            );
          },
        ),
      );
      if (window) body = WindowFrame(body, onExit: () => exits++);
      return SelectionTasksScope(
        registry: tasks ?? registry,
        child: NavigationAdmission(
          allowsNavigation: () => allowed,
          child: body,
        ),
      );
    },
  );

  Future<void> mount(
    WidgetTester tester, {
    LocalFavoritesManager? database,
    Widget? initialContent,
  }) async {
    final previousManager = LocalFavoritesManager.cache;
    final previousSettings = Map<String, dynamic>.from(
      appdata.toJson()['settings'] as Map,
    );
    final previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
    LocalFavoritesManager.cache = database ?? manager;
    appdata.settings['language'] = 'en-US';
    appdata.implicitData['local_favorites_read_filter'] = 'All';
    registerShowMessageHandler((_, value) => messages.add(value));
    content.value = initialContent ?? page();
    addTearDown(() async {
      final state = appNavigation.rootNavigatorKey.currentState;
      if (state is _NavigatorState) state.failPop = false;
      await tester.pumpWidget(const SizedBox());
      await pumpSidebar(tester);
      await settleSidebarWork(tester, registry.closeAndWait);
      LocalFavoritesManager.cache = previousManager;
      previousSettings.forEach((key, value) => appdata.settings[key] = value);
      appdata.implicitData = previousImplicit;
      content.dispose();
      registerShowMessageHandler((_, _) {});
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

  void closeWindow(WidgetTester tester) =>
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
}

Future<(Directory, LocalFavoritesManager)> _database(
  WidgetTester tester,
) async {
  final root = Directory.systemTemp.createTempSync(
    'venera-folder-rename-owned-',
  );
  final previousData = App.dataPath;
  final previousCache = App.cachePath;
  final previousManager = LocalFavoritesManager.cache;
  final checkpoint = appdata.captureImportCheckpoint();
  App.dataPath = root.path;
  App.cachePath = root.path;
  LocalFavoritesManager.cache = null;
  final database = LocalFavoritesManager();
  addTearDown(() async {
    registerFollowUpdatesChangeListener(null);
    await tester.runAsync(() async {
      await AppDataOperations.instance.run(() async {});
      await database.closeAndWait();
      await appdata.restoreImportCheckpoint(checkpoint, persist: false);
    });
    LocalFavoritesManager.cache = previousManager;
    App.dataPath = previousData;
    App.cachePath = previousCache;
    final temporaryRoot = Directory.systemTemp.resolveSymbolicLinksSync();
    final owned = root.resolveSymbolicLinksSync();
    expect(p.isWithin(temporaryRoot, owned), isTrue);
    expect(p.basename(owned), startsWith('venera-folder-rename-owned-'));
    root.deleteSync(recursive: true);
  });
  await tester.runAsync(() async {
    await database.init();
    await database.createFolder('Original');
    await database.createFolder('Other');
  });
  return (root, database);
}

VoidCallback _rename(WidgetTester tester) => tester
    .widgetList<MenuButton>(find.byType(MenuButton))
    .expand((menu) => menu.entries)
    .singleWhere((entry) => entry.text == 'Rename')
    .onClick;

Future<void> _press(WidgetTester tester, [String label = 'Confirm']) {
  final callback = tester
      .widget<Button>(find.widgetWithText(Button, label))
      .onPressed;
  return Future<void>.sync(() => Function.apply(callback, const []));
}

Future<void> _open(WidgetTester tester) async {
  _rename(tester)();
  await pumpSidebar(tester);
  await tester.enterText(find.byType(TextField), 'Renamed');
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

  for (final reason in [
    'removed',
    'covered',
    'retargeted',
    'closed',
    'frozen',
  ]) {
    testWidgets('old Rename menu cannot present after $reason', (tester) async {
      final host = _Host();
      await host.mount(tester);
      final retained = _rename(tester);
      if (reason == 'removed') {
        host.content.value = const Text('Removed');
      } else if (reason == 'retargeted') {
        host.content.value = host.page('Other');
      } else if (reason == 'covered') {
        host.cover();
      } else if (reason == 'closed') {
        await settleSidebarWork(tester, host.registry.closeAndWait);
      } else {
        host.allowed = false;
      }
      await pumpSidebar(tester);
      retained();
      await pumpSidebar(tester);
      expect(find.byType(TextField), findsNothing);
      expect(host.manager.renames, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final replacement in ['empty', 'new']) {
    testWidgets(
      'local page detaches its own listener after cache $replacement',
      (tester) async {
        final host = _Host();
        await host.mount(tester);
        expect(host.manager.listeners, hasLength(1));
        final next = replacement == 'empty' ? null : _Manager();
        LocalFavoritesManager.cache = next;
        host.content.value = const Text('Removed');
        await pumpSidebar(tester);
        expect(LocalFavoritesManager.cache, same(next));
        expect(host.manager.listeners, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('local page releases its scroll controller on disposal', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    final controller = tester
        .widget<SmoothCustomScrollView>(find.byType(SmoothCustomScrollView))
        .controller!;
    host.content.value = const Text('Removed');
    await pumpSidebar(tester);
    expect(() => controller.addListener(() {}), throwsFlutterError);
    expect(tester.takeException(), isNull);
  });

  for (final replacement in ['manager', 'connection', 'path']) {
    testWidgets('queued Rename cannot enter a replacement $replacement', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      await _open(tester);
      final previousPath = App.dataPath;
      final next = _Manager();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        App.dataPath = previousPath;
      });
      final replacing = AppDataOperations.instance.run(() async {
        await release.future;
        if (replacement == 'manager') {
          LocalFavoritesManager.cache = next;
        } else if (replacement == 'connection') {
          host.manager.connectionGeneration++;
        } else {
          App.dataPath = '$previousPath/synthetic-rename-replacement';
        }
      });
      final confirming = _press(tester);
      await pumpSidebar(tester);
      expect(host.manager.renames, isEmpty);
      release.complete();
      await settleSidebarWork(
        tester,
        () => Future.wait([replacing, confirming]),
      );
      expect(host.manager.renames, isEmpty);
      expect(next.renames, isEmpty);
      expect(host.selected, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'normal Rename updates the original list and selected folder once',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      await _open(tester);
      await settleSidebarWork(tester, () => _press(tester));
      await pumpSidebar(tester);
      expect(host.manager.renames, [('Original', 'Renamed')]);
      expect(host.manager.names, ['Renamed', 'Other']);
      expect(host.lists, 1);
      expect(host.selected, ['Renamed']);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final reason in ['removed', 'retargeted', 'covered', 'registry']) {
    testWidgets('accepted Rename does not publish into $reason owner', (
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
      final confirming = _press(tester);
      await pumpSidebar(tester);
      if (reason == 'removed') {
        host.content.value = const Text('Removed');
      } else if (reason == 'retargeted') {
        host.content.value = host.page('Other');
      } else if (reason == 'covered') {
        host.cover();
      } else {
        await tester.pumpWidget(host.app(tasks: SelectionTaskRegistry()));
      }
      await pumpSidebar(tester);
      pending.complete();
      await settleSidebarWork(tester, () => confirming);
      await pumpSidebar(tester);
      expect(host.manager.renames, [('Original', 'Renamed')]);
      expect(host.selected, isEmpty);
      expect(host.lists, 0);
      expect(tester.takeException(), isNull);
    });
  }

  for (final state in PersistenceCommitState.values) {
    testWidgets('Rename acknowledgement preserves $state without replay', (
      tester,
    ) async {
      final host = _Host();
      final failure = PersistenceFailure(
        commitState: state,
        cause: StateError('original rename failure'),
        stackTrace: StackTrace.fromString('original rename stack'),
      );
      host.manager.saving = () async => throw failure;
      await host.mount(tester);
      await _open(tester);
      await settleSidebarWork(tester, () => _press(tester));
      await pumpSidebar(tester);
      expect(find.text(failure.toString()), findsOneWidget);
      expect(host.selected, isEmpty);
      expect(host.lists, 0);
      if (state == PersistenceCommitState.notCommitted) {
        host.manager.saving = null;
        await settleSidebarWork(tester, () => _press(tester));
        expect(host.manager.renames, hasLength(2));
      } else {
        await settleSidebarWork(tester, () => _press(tester, 'OK'));
        expect(host.manager.renames, hasLength(1));
      }
      await pumpSidebar(tester);
      expect(
        host.selected,
        state == PersistenceCommitState.unknown ? isEmpty : ['Renamed'],
      );
      expect(host.lists, state == PersistenceCommitState.unknown ? 0 : 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Rename stays committed after its successful confirmation cannot pop',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      await _open(tester);
      host.navigator.failPop = true;
      await settleSidebarWork(tester, () => _press(tester));
      await pumpSidebar(tester);
      expect(host.manager.renames, [('Original', 'Renamed')]);
      expect(find.text(host.navigator.failure.toString()), findsOneWidget);
      expect(find.widgetWithText(Button, 'OK'), findsOneWidget);
      host.navigator.failPop = false;
      await settleSidebarWork(tester, () => _press(tester, 'OK'));
      await pumpSidebar(tester);
      expect(host.manager.renames, hasLength(1));
      expect(host.selected, ['Renamed']);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final window in [false, true]) {
    testWidgets(
      'original closing host reports its accepted Rename failure: window=$window',
      (tester) async {
        final host = _Host()..window = window;
        final pending = Completer<void>();
        final stack = StackTrace.fromString('pending rename failure stack');
        final failure = PersistenceFailure(
          commitState: PersistenceCommitState.unknown,
          cause: StateError('pending rename failure'),
          stackTrace: stack,
        );
        host.manager.saving = () async {
          await pending.future;
          Error.throwWithStackTrace(failure, stack);
        };
        await host.mount(tester);
        addTearDown(() {
          if (!pending.isCompleted) pending.complete();
        });
        await _open(tester);
        final confirming = _press(tester);
        await pumpSidebar(tester);
        Object? closingError;
        Future<void>? closing;
        var closed = false;
        if (window) {
          host.closeWindow(tester);
        } else {
          closing = host.registry.closeAndWait().then<void>(
            (_) => closed = true,
            onError: (Object error) => closingError = error,
          );
        }
        await pumpSidebar(tester);
        expect(host.exits, 0);
        expect(closed, isFalse);
        pending.complete();
        await settleSidebarWork(tester, () => confirming);
        if (closing != null) await settleSidebarWork(tester, () => closing!);
        await pumpSidebar(tester);
        if (window) closingError = tester.takeException();
        expect(closingError, isNotNull);
        expect(sidebarCauses(closingError!), contains(same(failure)));
        expect(host.exits, 0);
        expect(host.selected, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'replacement manager cannot receive reads from the original listener',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      final next = _Manager();
      LocalFavoritesManager.cache = next;
      host.manager.notify();
      await pumpSidebar(tester);
      expect(next.reads, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final replacement in ['manager', 'connection', 'path', 'registry']) {
    for (final fails in [false, true]) {
      testWidgets(
        'late local query cannot update a $replacement replacement: fails=$fails',
        (tester) async {
          final host = _Host();
          final pending = Completer<List<FavoriteItem>>();
          host.manager.query = pending.future;
          await host.mount(tester);
          final previousPath = App.dataPath;
          addTearDown(() {
            if (!pending.isCompleted) pending.complete([]);
            App.dataPath = previousPath;
          });
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          if (replacement == 'manager') {
            LocalFavoritesManager.cache = _Manager();
          } else if (replacement == 'connection') {
            host.manager.connectionGeneration++;
          } else if (replacement == 'path') {
            App.dataPath = '$previousPath/synthetic-late-query';
          } else {
            await tester.pumpWidget(host.app(tasks: SelectionTaskRegistry()));
          }
          if (fails) {
            pending.completeError(StateError('retired query failure'));
          } else {
            pending.complete([]);
          }
          await pumpSidebar(tester);
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'current local query completes after an older folder result is retired',
    (tester) async {
      final host = _Host();
      final oldQuery = Completer<List<FavoriteItem>>();
      final newQuery = Completer<List<FavoriteItem>>();
      host.manager.query = oldQuery.future;
      await host.mount(tester);
      addTearDown(() {
        if (!oldQuery.isCompleted) oldQuery.complete([]);
        if (!newQuery.isCompleted) newQuery.complete([]);
      });
      host.manager.query = newQuery.future;
      host.content.value = host.page('Other');
      await pumpSidebar(tester);
      oldQuery.complete([]);
      await pumpSidebar(tester);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      newQuery.complete([]);
      await pumpSidebar(tester);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(host.manager.reads, 2);
      expect(tester.takeException(), isNull);
    },
  );

  for (final reason in ['removed', 'retargeted']) {
    testWidgets('Rename rejects confirmation after its page is $reason', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      await _open(tester);
      host.content.value = reason == 'removed'
          ? const Text('Removed')
          : host.page('Other');
      await pumpSidebar(tester);
      await settleSidebarWork(tester, () => _press(tester));
      expect(host.manager.renames, isEmpty);
      expect(host.selected, isEmpty);
      await tester.tap(find.widgetWithIcon(IconButton, Icons.close));
      await pumpSidebar(tester);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final committedFailure in [false, true]) {
    testWidgets(
      'dismissed Rename joins its pending commit: failure=$committedFailure',
      (tester) async {
        final host = _Host();
        final pending = Completer<void>();
        host.manager.saving = () async {
          await pending.future;
          if (committedFailure) {
            throw PersistenceFailure(
              commitState: PersistenceCommitState.committed,
              cause: StateError('post-commit observer'),
              stackTrace: StackTrace.current,
            );
          }
        };
        await host.mount(tester);
        addTearDown(() {
          if (!pending.isCompleted) pending.complete();
        });
        await _open(tester);
        final confirming = _press(tester);
        await pumpSidebar(tester);
        await tester.tap(find.widgetWithIcon(IconButton, Icons.close));
        await pumpSidebar(tester);
        expect(find.byType(TextField), findsNothing);
        expect(host.selected, isEmpty);
        pending.complete();
        await settleSidebarWork(tester, () => confirming);
        await pumpSidebar(tester);
        expect(host.manager.renames, [('Original', 'Renamed')]);
        expect(host.selected, ['Renamed']);
        expect(host.lists, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final window in [false, true]) {
    testWidgets(
      'closing owner joins queued Rename without discarding it: $window',
      (tester) async {
        final host = _Host()..window = window;
        await host.mount(tester);
        await _open(tester);
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final exclusive = AppDataOperations.instance.run(() => release.future);
        final confirming = _press(tester);
        await pumpSidebar(tester);
        expect(host.manager.renames, isEmpty);
        var closed = false;
        Future<void>? closing;
        if (window) {
          host.closeWindow(tester);
        } else {
          closing = host.registry.closeAndWait().then<void>(
            (_) => closed = true,
          );
        }
        await pumpSidebar(tester);
        expect(closed, isFalse);
        expect(host.exits, 0);
        release.complete();
        await settleSidebarWork(
          tester,
          () => Future.wait([exclusive, confirming]),
        );
        if (closing != null) await settleSidebarWork(tester, () => closing!);
        await pumpSidebar(tester);
        expect(host.manager.renames, [('Original', 'Renamed')]);
        expect(host.selected, isEmpty);
        expect(host.exits, window ? 1 : 0);
        expect(closed, !window);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Rename publication failure preserves its committed outcome and stack',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      final failure = StateError('original page publication');
      final stack = StackTrace.fromString('original publication stack');
      Object? reported;
      StackTrace? reportedStack;
      var publications = 0;
      final shown =
          renameFavoriteFolder(
            host.context,
            manager: host.manager,
            folder: 'Original',
            isCurrent: () => true,
            onRenamed: (_) {
              publications++;
              Error.throwWithStackTrace(failure, stack);
            },
          ).catchError((Object error, StackTrace errorStack) {
            reported = error;
            reportedStack = errorStack;
          });
      await pumpSidebar(tester);
      await tester.enterText(find.byType(TextField), 'Renamed');
      await settleSidebarWork(tester, () => _press(tester));
      await settleSidebarWork(tester, () => shown);
      await pumpSidebar(tester);
      expect(reported, isA<PersistenceFailure>());
      final details = reported! as PersistenceFailure;
      expect(details.commitState, PersistenceCommitState.committed);
      expect(details.cause, same(failure));
      expect(details.stackTrace, same(stack));
      expect(reportedStack, same(stack));
      await settleSidebarWork(tester, host.registry.closeAndWait);
      expect(publications, 1);
      expect(host.manager.renames, [('Original', 'Renamed')]);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final failingObserver in [false, true]) {
    testWidgets(
      'real SQLite Rename preserves data and links: observer=$failingObserver',
      (tester) async {
        final (root, database) = await _database(tester);
        const original = '原 " Folder';
        const renamed = '收藏 Renamed';
        await tester.runAsync(() async {
          await database.createFolder(original);
          await database.prepareTableForFollowUpdates(original);
          await database.linkFolderToNetwork(
            original,
            'synthetic-source',
            'remote',
          );
          await database.addComic(
            original,
            FavoriteItem(
              id: 'synthetic-id',
              name: 'Stored comic',
              author: 'Synthetic author',
              coverPath: 'synthetic-cover',
              type: ComicType.local,
              tags: ['one', 'two'],
            ),
          );
          await database.updateOrder(database.folderNames.reversed.toList());
        });
        appdata.settings['quickFavorite'] = original;
        appdata.settings['followUpdatesFolder'] = original;
        appdata.settings['readLaterFolder'] = ' $original ';
        final host = _Host();
        await host.mount(
          tester,
          database: database,
          initialContent: const Text('Original caller'),
        );
        final originalOrder = database.folderNames;
        final originalComic = database
            .getFolderComics(original)
            .single
            .toJson();
        final expectedOrder = originalOrder
            .map((name) => name == original ? renamed : name)
            .toList();
        var notifications = 0;
        var observerCalls = 0;
        void changed() => notifications++;
        database.addListener(changed);
        addTearDown(() => database.removeListener(changed));
        final failure = StateError('synthetic follow observer');
        if (failingObserver) {
          registerFollowUpdatesChangeListener(() {
            observerCalls++;
            throw failure;
          });
          addTearDown(() => registerFollowUpdatesChangeListener(null));
        }
        final shown = renameFavoriteFolder(
          host.context,
          manager: database,
          folder: original,
          isCurrent: () => true,
          onRenamed: host.selected.add,
        );
        await pumpSidebar(tester);
        await tester.enterText(find.byType(TextField), renamed);
        await settleSidebarWork(tester, () => _press(tester));
        await pumpSidebar(tester);
        if (failingObserver) {
          expect(find.text('Persistence committed: $failure'), findsOneWidget);
          expect(host.selected, isEmpty);
          await settleSidebarWork(tester, () => _press(tester, 'OK'));
        }
        await settleSidebarWork(tester, () => shown);
        await pumpSidebar(tester);
        expect(host.selected, [renamed]);
        expect(database.folderNames, expectedOrder);
        expect(
          database.getFolderComics(renamed).single.toJson(),
          originalComic,
        );
        expect(database.findLinked(renamed), ('synthetic-source', 'remote'));
        expect(database.findLinked(original), (null, null));
        expect(notifications, 1);
        expect(observerCalls, failingObserver ? 1 : 0);
        final settings = jsonDecode(
          File(p.join(root.path, 'appdata.json')).readAsStringSync(),
        )['settings'];
        expect(settings['quickFavorite'], renamed);
        expect(settings['followUpdatesFolder'], renamed);
        expect(settings['readLaterFolder'], ' $original ');
        final raw = sqlite3.open(database.databasePath);
        try {
          expect(
            raw
                .select(
                  'SELECT folder_name FROM folder_order ORDER BY order_value',
                )
                .map((row) => row['folder_name']),
            expectedOrder,
          );
          expect(
            raw
                .select(
                  'SELECT folder_name, source_key, source_folder FROM folder_sync',
                )
                .single,
            {
              'folder_name': renamed,
              'source_key': 'synthetic-source',
              'source_folder': 'remote',
            },
          );
        } finally {
          raw.dispose();
        }
        registerFollowUpdatesChangeListener(null);
        await tester.runAsync(() async {
          await database.closeAndWait();
          await database.init();
        });
        expect(database.folderNames, expectedOrder);
        expect(
          database.getFolderComics(renamed).single.toJson(),
          originalComic,
        );
        expect(database.findLinked(renamed), ('synthetic-source', 'remote'));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'actual FavoritesPage changes its key after Rename: observer=$failingObserver',
      (tester) async {
        final (root, database) = await _database(tester);
        appdata.implicitData['favoriteFolder'] = {
          'name': 'Original',
          'isNetwork': false,
        };
        await tester.runAsync(
          () => database.prepareTableForFollowUpdates('Original'),
        );
        appdata.settings['followUpdatesFolder'] = 'Original';
        final host = _Host();
        await host.mount(
          tester,
          database: database,
          initialContent: const FavoritesPage(),
        );
        final original = tester.element(
          find.byKey(const PageStorageKey('local_Original')),
        );
        final failure = StateError('synthetic selected folder observer');
        if (failingObserver) {
          registerFollowUpdatesChangeListener(() => throw failure);
          addTearDown(() => registerFollowUpdatesChangeListener(null));
        }
        await _open(tester);
        await settleSidebarWork(tester, () => _press(tester));
        await pumpSidebar(tester);
        if (failingObserver) {
          expect(original.mounted, isTrue);
          expect(find.text('Persistence committed: $failure'), findsOneWidget);
          await settleSidebarWork(tester, () => _press(tester, 'OK'));
          await pumpSidebar(tester);
        }
        final owner = tester.state<SettingsSaveState>(
          find.byType(FavoritesPage),
        );
        await settleSidebarWork(tester, owner.waitForSettingsSave);
        await pumpSidebar(tester);
        expect(original.mounted, isFalse);
        expect(
          find.byKey(const PageStorageKey('local_Renamed')),
          findsOneWidget,
        );
        expect(find.byType(TextField), findsNothing);
        final saved = jsonDecode(
          File(p.join(root.path, 'implicitData.json')).readAsStringSync(),
        );
        expect(saved['favoriteFolder'], {
          'name': 'Renamed',
          'isNetwork': false,
        });
        expect(database.existsFolder('Original'), isFalse);
        expect(database.existsFolder('Renamed'), isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
