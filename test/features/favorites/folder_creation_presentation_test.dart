import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_details/favorite.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/favorites/create_favorite_folder_dialog.dart';
import 'package:venera_next/features/favorites/favorite_actions.dart';
import 'package:venera_next/features/favorites/favorite_transfer_dialog.dart';
import 'package:venera_next/features/favorites/favorite_models.dart';
import 'package:venera_next/features/favorites/favorite_folder_browser.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/favorites/favorites_page.dart';
import 'package:venera_next/features/favorites/local_favorites_page.dart';
import 'package:venera_next/features/favorites/side_bar.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:window_manager/window_manager.dart';

import '../../support/sidebar_test_support.dart'
    show pumpSidebar, settleSidebarWork, sidebarCauses;

class _Source extends Fake implements ComicSource {
  _Source({this.network});
  final FavoriteData? network;
  @override
  final key = 'favorite-creation-test-source';
  @override
  FavoriteData? get favoriteData => network;
  @override
  bool get isLogged => network != null;
}

void _registerSource(_Source source) {
  configureComicSourceRegistry(
    all: () => [source],
    find: (key) => key == source.key ? source : null,
    fromIntKey: (key) => key == source.key.hashCode ? source : null,
    isEmpty: () => false,
  );
  addTearDown(
    () => configureComicSourceRegistry(
      all: () => [],
      find: (_) => null,
      fromIntKey: (_) => null,
      isEmpty: () => true,
    ),
  );
}

ComicFavoritePanel _detailPanel(
  _Source source, {
  void Function(bool?, bool?)? onFavorite,
}) => ComicFavoritePanel(
  cid: 'qa-comic',
  type: ComicType(source.key.hashCode),
  isFavorite: false,
  onFavorite: onFavorite ?? (_, _) {},
  favoriteItem: FavoriteItem(
    id: 'qa-comic',
    name: 'Synthetic comic',
    coverPath: '',
    author: '',
    type: ComicType(source.key.hashCode),
    tags: [],
  ),
);

class _Navigator extends Navigator {
  const _Navigator({super.key, super.onGenerateRoute});
  @override
  NavigatorState createState() => _NavigatorState();
}

class _NavigatorState extends NavigatorState {
  bool fails = false;
  final failure = StateError('original create dialog removal failed');
  final failureStack = StackTrace.fromString('original create dialog stack');
  final attempts = <Route<dynamic>>[];
  @override
  void removeRoute<T extends Object?>(Route<T> route, [T? result]) {
    attempts.add(route);
    if (fails) Error.throwWithStackTrace(failure, failureStack);
    super.removeRoute(route, result);
  }
}

class _FolderCreationHost {
  final registry = SelectionTaskRegistry();
  final manager = LocalFavoritesManager();
  late Directory root;
  late BuildContext context;
  bool allowed = true;
  bool window = false;
  int exits = 0;
  Widget? content;
  double textScale = 1;
  final repaint = GlobalKey();
  _NavigatorState get navigator =>
      appNavigation.rootNavigatorKey.currentState! as _NavigatorState;

  Widget tree() => MaterialApp(
    builder: (context, _) {
      Widget child = _Navigator(
        key: appNavigation.rootNavigatorKey,
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (value) {
            this.context = value;
            return Scaffold(body: content ?? const Text('Original home'));
          },
        ),
      );
      if (window) child = WindowFrame(child, onExit: () => exits++);
      return MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: RepaintBoundary(
          key: repaint,
          child: SelectionTasksScope(
            registry: registry,
            child: NavigationAdmission(
              allowsNavigation: () => allowed,
              child: child,
            ),
          ),
        ),
      );
    },
  );

  Future<void> mount(
    WidgetTester tester, {
    List<String> folders = const [],
  }) async {
    root = Directory.systemTemp.createTempSync('venera-favorite-create-');
    final previousData = App.dataPath;
    final previousCache = App.cachePath;
    final previousSettings = Map<String, dynamic>.from(
      appdata.toJson()['settings'] as Map,
    );
    final previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
    App.dataPath = root.path;
    App.cachePath = root.path;
    appdata.settings['language'] = 'en-US';
    addTearDown(() async {
      final navigation = appNavigation.rootNavigatorKey.currentState;
      if (navigation is _NavigatorState) navigation.fails = false;
      await tester.pumpWidget(const SizedBox());
      await pumpSidebar(tester);
      await settleSidebarWork(tester, registry.closeAndWait);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.runAsync(() async {
        await AppDataOperations.instance.run(() async {});
        await manager.closeAndWait();
      });
      previousSettings.forEach((key, value) => appdata.settings[key] = value);
      appdata.implicitData = previousImplicit;
      App.dataPath = previousData;
      App.cachePath = previousCache;
      final temporaryRoot = Directory.systemTemp.resolveSymbolicLinksSync();
      final owned = root.resolveSymbolicLinksSync();
      expect(p.isWithin(temporaryRoot, owned), isTrue);
      expect(p.basename(owned), startsWith('venera-favorite-create-'));
      root.deleteSync(recursive: true);
    });
    await tester.runAsync(() async {
      await manager.init();
      for (final name in folders) {
        await manager.createFolder(name);
      }
    });
    await tester.pumpWidget(tree());
  }

  Future<void> open() => newFolder(context);

  Route<dynamic> route(WidgetTester tester) =>
      ModalRoute.of(tester.element(find.byType(CreateFavoriteFolderDialog)))!;

  Future<void> replaceConnection(WidgetTester tester) async {
    await tester.runAsync(() async {
      await manager.closeAndWait();
      final next = Directory(p.join(root.path, 'replacement'))..createSync();
      App.dataPath = next.path;
      App.cachePath = next.path;
      await manager.init();
    });
  }

  File jsonFile(String name) =>
      File(p.join(root.path, 'selected.json'))
        ..writeAsStringSync(jsonEncode({'name': name, 'comics': []}));
}

Future<void> _create(WidgetTester tester, String name) async {
  await tester.enterText(
    find.byKey(const ValueKey('favorite-folder-name')),
    name,
  );
  final action = tester
      .widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'))
      .onPressed!;
  await settleSidebarWork(
    tester,
    () => Future<void>.sync(() => Function.apply(action, const [])),
  );
  await pumpSidebar(tester);
}

LocalFavoritesPage _localPage() => LocalFavoritesPage(
  folder: 'Original folder',
  showFolders: () {},
  onFolderSelected: (_, _) {},
  updateFolderList: () {},
);

void _openTransfer(_FolderCreationHost host, WidgetTester tester) {
  final context = tester.element(find.byType(LocalFavoritesPage));
  showFavoriteTransferDialog(
    context: context,
    manager: host.manager,
    source: 'Original folder',
    comics: const [],
    move: false,
    isCurrent: () => context.mounted,
    onCommitted: () {},
  );
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
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/file_selector'),
        null,
      );
    });
  });

  for (final scenario in [
    (width: 390.0, create: true),
    (width: 390.0, create: false),
    (width: 1200.0, create: true),
    (width: 1200.0, create: false),
  ]) {
    testWidgets('real folder menu can reopen after closing: $scenario', (
      tester,
    ) async {
      tester.view.physicalSize = Size(scenario.width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = _FolderCreationHost()
        ..content = Navigator(
          onGenerateRoute: (_) =>
              MaterialPageRoute<void>(builder: (_) => const FavoritesPage()),
        );
      await host.mount(tester);
      await tester.pumpAndSettle();
      if (scenario.width < 600) {
        await tester.tap(find.byIcon(Icons.menu).hitTestable());
        await tester.pumpAndSettle();
      }
      for (final name in ['First new folder', 'Second new folder']) {
        await tester.tap(find.byIcon(Icons.more_horiz).hitTestable());
        await tester.pumpAndSettle();
        expect(
          find.text('Create Folder').hitTestable(),
          findsOneWidget,
          reason: 'Menu before creating $name',
        );
        await tester.tap(find.text('Create Folder').hitTestable());
        await tester.pumpAndSettle();
        expect(find.byType(CreateFavoriteFolderDialog), findsOneWidget);
        if (scenario.create) {
          await _create(tester, name);
        } else {
          await tester.tap(
            find.descendant(
              of: find.byType(CreateFavoriteFolderDialog),
              matching: find.byIcon(Icons.close),
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(find.byType(CreateFavoriteFolderDialog), findsNothing);
        expect(host.manager.folderNames.contains(name), scenario.create);
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final built in [false, true]) {
    testWidgets('creation presentation ends after Navigator disposal: $built', (
      tester,
    ) async {
      final host = _FolderCreationHost();
      await host.mount(tester);
      var ended = false;
      host.open().then((_) => ended = true).ignore();
      if (built) {
        await pumpSidebar(tester);
      } else {
        await tester.idle();
      }
      await tester.pumpWidget(const SizedBox());
      await pumpSidebar(tester);
      expect(ended, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  for (final reason in ['closed', 'frozen', 'covered']) {
    testWidgets('original caller cannot create a dialog after $reason', (
      tester,
    ) async {
      final host = _FolderCreationHost();
      await host.mount(tester);
      if (reason == 'closed') {
        await settleSidebarWork(tester, host.registry.closeAndWait);
      } else if (reason == 'frozen') {
        host.allowed = false;
      } else {
        host.navigator.push(
          MaterialPageRoute<void>(builder: (_) => const Text('Newer page')),
        );
        await pumpSidebar(tester);
      }
      host.open().ignore();
      await pumpSidebar(tester);
      expect(find.byType(CreateFavoriteFolderDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('application closes only its original creation dialog', (
    tester,
  ) async {
    final host = _FolderCreationHost();
    await host.mount(tester);
    var ended = false;
    host.open().then((_) => ended = true).ignore();
    await pumpSidebar(tester);
    final original = host.route(tester);
    final newer = MaterialPageRoute<void>(builder: (_) => const Text('Newer'));
    host.navigator.push(newer);
    await pumpSidebar(tester);
    await settleSidebarWork(tester, host.registry.closeAndWait);
    expect(original.isActive, isFalse);
    expect(newer.isCurrent, isTrue);
    expect(ended, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('creation does not write into a reopened favorites connection', (
    tester,
  ) async {
    final host = _FolderCreationHost();
    await host.mount(tester);
    host.open().ignore();
    await pumpSidebar(tester);
    await tester.enterText(
      find.byKey(const ValueKey('favorite-folder-name')),
      'Original creation',
    );
    final retained = tester
        .widget<FilledButton>(find.byType(FilledButton))
        .onPressed!;
    await host.replaceConnection(tester);
    final creating = Future<void>.sync(
      () => Function.apply(retained, const []),
    );
    await settleSidebarWork(tester, () => creating);
    expect(host.manager.folderNames, isNot(contains('Original creation')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('late selected import cannot use a replacement connection', (
    tester,
  ) async {
    final host = _FolderCreationHost();
    await host.mount(tester);
    final file = host.jsonFile('Original import');
    final selected = Completer<List<String>?>();
    var pickers = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/file_selector'),
          (_) {
            pickers++;
            return selected.future;
          },
        );
    addTearDown(() {
      if (!selected.isCompleted) selected.complete(null);
    });
    host.open().ignore();
    await pumpSidebar(tester);
    final action = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Import from file'))
        .onPressed!;
    final importing = Future<void>.sync(() => Function.apply(action, const []));
    await tester.pump();
    expect(pickers, 1);
    await host.replaceConnection(tester);
    selected.complete([file.path]);
    await settleSidebarWork(tester, () => importing);
    await pumpSidebar(tester);
    expect(host.manager.folderNames, isNot(contains('Original import')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed creation-dialog removal stays with the original host', (
    tester,
  ) async {
    final host = _FolderCreationHost();
    await host.mount(tester);
    Object? presentationError;
    final result = host.open().catchError((Object error) {
      presentationError = error;
    });
    await pumpSidebar(tester);
    final original = host.route(tester);
    host.navigator.fails = true;
    Object? error;
    await settleSidebarWork(
      tester,
      () => host.registry.closeAndWait().catchError((Object value) {
        error = value;
      }),
    );
    expect(error, isA<SelectionCleanupFailure>());
    expect(sidebarCauses(error!), contains(same(host.navigator.failure)));
    await settleSidebarWork(tester, () => result);
    expect(
      sidebarCauses(presentationError!),
      contains(same(host.navigator.failure)),
    );
    expect(host.navigator.attempts, [original]);
    host.navigator.fails = false;
    await settleSidebarWork(tester, host.registry.closeAndWait);
    expect(host.navigator.attempts, [original, original]);
    expect(original.isActive, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('window joins a late picker and reports failed presentation', (
    tester,
  ) async {
    final host = _FolderCreationHost()..window = true;
    await host.mount(tester);
    final selected = Completer<List<String>?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/file_selector'),
          (_) => selected.future,
        );
    addTearDown(() {
      if (!selected.isCompleted) selected.complete(null);
    });
    host.open().ignore();
    await pumpSidebar(tester);
    final original = host.route(tester);
    await tester.tap(find.text('Import from file'));
    await tester.pump();
    host.navigator.fails = true;
    final window = tester.state(find.byType(WindowFrame)) as WindowListener;
    window.onWindowClose();
    await pumpSidebar(tester);
    expect(host.exits, 0);
    selected.complete(null);
    await pumpSidebar(tester);
    expect(host.exits, 0);
    final failure = tester.takeException();
    expect(failure, isA<SelectionCleanupFailure>());
    expect(sidebarCauses(failure!), contains(same(host.navigator.failure)));
    expect(host.navigator.attempts, [original]);
    host.navigator.fails = false;
    window.onWindowClose();
    await pumpSidebar(tester);
    expect(host.exits, 1);
    expect(host.navigator.attempts, [original, original]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('real creation and JSON import keep the existing stored format', (
    tester,
  ) async {
    final host = _FolderCreationHost();
    await host.mount(tester);
    final create = host.open();
    await pumpSidebar(tester);
    await tester.enterText(
      find.byKey(const ValueKey('favorite-folder-name')),
      'Created',
    );
    await tester.tap(find.text('Create'));
    await settleSidebarWork(tester, () => create);
    expect(host.manager.folderNames, contains('Created'));
    final file = host.jsonFile('Imported');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/file_selector'),
          (_) async => [file.path],
        );
    final importing = host.open();
    await pumpSidebar(tester);
    await tester.tap(find.text('Import from file'));
    await settleSidebarWork(tester, () => importing);
    await pumpSidebar(tester);
    expect(host.manager.folderNames, containsAll(['Created', 'Imported']));
    expect(host.manager.folderComics('Imported'), 0);
    expect(tester.takeException(), isNull);
  });

  for (final title in ['Create Folder', 'Sort']) {
    testWidgets('removed sidebar rejects a late $title publication', (
      tester,
    ) async {
      final host = _FolderCreationHost();
      final visible = ValueNotifier(true);
      host.content = ValueListenableBuilder<bool>(
        valueListenable: visible,
        builder: (_, show, _) => show
            ? FavoritesFolderSidebar(
                selectedFolder: null,
                isNetworkSelected: false,
                onFolderSelected: (_, _) {},
              )
            : const Text('Sidebar removed'),
      );
      await host.mount(tester);
      addTearDown(visible.dispose);
      tester
          .widget<MenuButton>(find.byType(MenuButton))
          .entries
          .singleWhere((entry) => entry.text == title)
          .onClick();
      await pumpSidebar(tester);
      visible.value = false;
      await pumpSidebar(tester);
      host.navigator.pop();
      await pumpSidebar(tester);
      await settleSidebarWork(
        tester,
        () => AppDataOperations.instance.run(() async {}),
      );
      await pumpSidebar(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'sidebar disposal releases its original manager without recreating one',
    (tester) async {
      final host = _FolderCreationHost();
      final visible = ValueNotifier(true);
      host.content = ValueListenableBuilder<bool>(
        valueListenable: visible,
        builder: (_, show, _) => show
            ? FavoritesFolderSidebar(
                selectedFolder: null,
                isNetworkSelected: false,
                onFolderSelected: (_, _) {},
              )
            : const Text('Sidebar removed'),
      );
      await host.mount(tester);
      addTearDown(visible.dispose);
      final original = LocalFavoritesManager.cache;
      visible.value = false;
      await pumpSidebar(tester);
      expect(LocalFavoritesManager.cache, same(original));
      expect(tester.takeException(), isNull);
    },
  );

  for (final importing in [false, true]) {
    testWidgets(
      'queued folder write rejects a database replaced before admission: import=$importing',
      (tester) async {
        final host = _FolderCreationHost();
        await host.mount(tester);
        final name = importing ? 'Queued import' : 'Queued create';
        final file = host.jsonFile(name);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/file_selector'),
              (_) async => [file.path],
            );
        host.open().ignore();
        await pumpSidebar(tester);
        await tester.enterText(
          find.byKey(const ValueKey('favorite-folder-name')),
          name,
        );
        final release = Completer<void>();
        final replacement = AppDataOperations.instance.run(() async {
          await release.future;
          await host.manager.closeAndWait();
          final next = Directory(p.join(host.root.path, 'queued-replacement'))
            ..createSync();
          App.dataPath = next.path;
          App.cachePath = next.path;
          await host.manager.init();
        });
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final action = importing
            ? tester
                  .widget<TextButton>(
                    find.widgetWithText(TextButton, 'Import from file'),
                  )
                  .onPressed!
            : tester.widget<FilledButton>(find.byType(FilledButton)).onPressed!;
        var ended = false;
        final writing = Future<void>.sync(
          () => Function.apply(action, const []),
        ).then<void>((_) => ended = true);
        await pumpSidebar(tester);
        expect(ended, isFalse);
        release.complete();
        await settleSidebarWork(
          tester,
          () => Future.wait([replacement, writing]),
        );
        await pumpSidebar(tester);
        expect(host.manager.folderNames, isNot(contains(name)));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('local transfer popup receives the original new folder list', (
    tester,
  ) async {
    final host = _FolderCreationHost()..content = _localPage();
    await host.mount(tester);
    await tester.runAsync(() => host.manager.createFolder('Original folder'));
    await tester.pump();
    _openTransfer(host, tester);
    await pumpSidebar(tester);
    await tester.tap(find.widgetWithText(TextButton, 'New Folder'));
    await pumpSidebar(tester);
    await _create(tester, 'New destination');
    expect(
      find.widgetWithText(CheckboxListTile, 'New destination'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(CheckboxListTile, 'Original folder'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'removed local transfer popup cannot receive a late folder list',
    (tester) async {
      final host = _FolderCreationHost()..content = _localPage();
      await host.mount(tester);
      await tester.runAsync(() => host.manager.createFolder('Original folder'));
      await tester.pump();
      _openTransfer(host, tester);
      await pumpSidebar(tester);
      final popup = tester
          .widget<PopupIndicatorWidget>(find.byType(PopupIndicatorWidget))
          .route!;
      await tester.tap(find.widgetWithText(TextButton, 'New Folder'));
      await pumpSidebar(tester);
      await tester.enterText(
        find.byKey(const ValueKey('favorite-folder-name')),
        'Accepted creation',
      );
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final action = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'))
          .onPressed!;
      final writing = Future<void>.sync(() => Function.apply(action, const []));
      await tester.pump();
      host.navigator.removeRoute(popup);
      host.navigator.pop();
      await pumpSidebar(tester);
      release.complete();
      await settleSidebarWork(tester, () => Future.wait([exclusive, writing]));
      await pumpSidebar(tester);
      expect(host.manager.folderNames, contains('Accepted creation'));
      expect(find.byType(LocalFavoritesPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'covered local transfer popup cannot open a new creation dialog',
    (tester) async {
      final host = _FolderCreationHost()..content = _localPage();
      await host.mount(tester);
      await tester.runAsync(() => host.manager.createFolder('Original folder'));
      await tester.pump();
      _openTransfer(host, tester);
      await pumpSidebar(tester);
      final retained = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'New Folder'))
          .onPressed!;
      final newer = MaterialPageRoute<void>(
        builder: (_) => const Text('Newer page'),
      );
      host.navigator.push(newer);
      await pumpSidebar(tester);
      retained();
      await pumpSidebar(tester);
      expect(find.byType(CreateFavoriteFolderDialog), findsNothing);
      expect(newer.isCurrent, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('covered local transfer popup rejects late folder publication', (
    tester,
  ) async {
    final host = _FolderCreationHost()..content = _localPage();
    await host.mount(tester);
    await tester.runAsync(() => host.manager.createFolder('Original folder'));
    await tester.pump();
    _openTransfer(host, tester);
    await pumpSidebar(tester);
    await tester.tap(find.widgetWithText(TextButton, 'New Folder'));
    await pumpSidebar(tester);
    final creation = host.route(tester);
    await tester.enterText(
      find.byKey(const ValueKey('favorite-folder-name')),
      'Background destination',
    );
    final release = Completer<void>();
    final exclusive = AppDataOperations.instance.run(() => release.future);
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final action = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'))
        .onPressed!;
    final writing = Future<void>.sync(() => Function.apply(action, const []));
    await tester.pump();
    final newer = MaterialPageRoute<void>(
      builder: (_) => const Text('Newer page'),
    );
    host.navigator.push(newer);
    await pumpSidebar(tester);
    release.complete();
    await settleSidebarWork(tester, () => Future.wait([exclusive, writing]));
    expect(newer.isCurrent, isTrue);
    host.navigator.removeRoute(creation);
    await pumpSidebar(tester);
    host.navigator.pop();
    await pumpSidebar(tester);
    expect(host.manager.folderNames, contains('Background destination'));
    expect(
      find.widgetWithText(CheckboxListTile, 'Background destination'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  for (final retarget in [false, true]) {
    testWidgets(
      'comic detail folder publication stays with its comic: retarget=$retarget',
      (tester) async {
        final source = _Source();
        configureComicSourceRegistry(
          all: () => [source],
          find: (key) => key == source.key ? source : null,
          fromIntKey: (key) => key == source.key.hashCode ? source : null,
          isEmpty: () => false,
        );
        addTearDown(
          () => configureComicSourceRegistry(
            all: () => [],
            find: (_) => null,
            fromIntKey: (_) => null,
            isEmpty: () => true,
          ),
        );
        final selected = ValueNotifier('original');
        addTearDown(selected.dispose);
        final host = _FolderCreationHost();
        host.content = ValueListenableBuilder<String>(
          valueListenable: selected,
          builder: (_, id, _) => ComicFavoritePanel(
            cid: id,
            type: ComicType(source.key.hashCode),
            isFavorite: null,
            onFavorite: (_, _) {},
            favoriteItem: FavoriteItem(
              id: id,
              name: 'Synthetic comic',
              coverPath: '',
              author: '',
              type: ComicType(source.key.hashCode),
              tags: [],
            ),
          ),
        );
        await host.mount(tester);
        await tester.tap(
          find.byKey(const ValueKey('comic-favorite-new-folder')),
        );
        await pumpSidebar(tester);
        await tester.enterText(
          find.byKey(const ValueKey('favorite-folder-name')),
          'Created for original',
        );
        final release = Completer<void>();
        final exclusive = AppDataOperations.instance.run(() => release.future);
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final action = tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'))
            .onPressed!;
        final writing = Future<void>.sync(
          () => Function.apply(action, const []),
        );
        await tester.pump();
        if (retarget) {
          selected.value = 'replacement';
          await tester.pump();
        }
        release.complete();
        await settleSidebarWork(
          tester,
          () => Future.wait([exclusive, writing]),
        );
        await pumpSidebar(tester);
        expect(host.manager.folderNames, contains('Created for original'));
        expect(
          find.widgetWithText(ListTile, 'Created for original'),
          retarget ? findsNothing : findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final scenario in [
    (size: const Size(375, 812), scale: 1.0),
    (size: const Size(812, 375), scale: 1.0),
    (size: const Size(1024, 768), scale: 1.0),
    (size: const Size(375, 812), scale: 2.0),
    (size: const Size(1024, 768), scale: 2.0),
  ]) {
    testWidgets(
      'detail favorites fill the viewport and keep folder creation visible: $scenario',
      (tester) async {
        tester.view.physicalSize = scenario.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final source = _Source();
        _registerSource(source);
        final localChanges = <bool?>[];
        final host = _FolderCreationHost()
          ..textScale = scenario.scale
          ..content = _detailPanel(
            source,
            onFavorite: (local, _) => localChanges.add(local),
          );
        await host.mount(
          tester,
          folders: List.generate(10, (i) => 'QA Folder ${i + 1}'),
        );
        appdata.settings[FavoritePreferences.autoCloseFavoritePanel.key] =
            false;
        await pumpSidebar(tester);
        final browser = find.byType(FavoriteFolderBrowser);
        expect(
          tester.getBottomLeft(browser).dy,
          closeTo(scenario.size.height, 0.01),
        );
        expect(
          tester.getSize(browser).height,
          greaterThan(scenario.size.height - 64),
        );
        final button = find.byKey(const ValueKey('comic-favorite-new-folder'));
        final position = tester.getCenter(button);
        expect(position.dy, lessThan(56));
        expect(position.dx, greaterThan(scenario.size.width - 64));
        final scrolling = find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        );
        expect(scrolling, findsOneWidget);
        final last = find.widgetWithText(ListTile, 'QA Folder 10');
        await tester.scrollUntilVisible(
          last,
          250,
          scrollable: scrolling,
          maxScrolls: 20,
        );
        await Scrollable.ensureVisible(tester.element(last), alignment: 0.5);
        await tester.pumpAndSettle();
        expect(last.hitTestable(), findsOneWidget);
        expect(tester.getCenter(button), position);
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              host.repaint.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            final directory = Directory('build/issues-ui-qa')
              ..createSync(recursive: true);
            File(
              '${directory.path}/favorite-panel-${scenario.size.width.toInt()}x${scenario.size.height.toInt()}-${scenario.scale}.png',
            ).writeAsBytesSync(
              bytes.buffer.asUint8List(
                bytes.offsetInBytes,
                bytes.lengthInBytes,
              ),
            );
          } finally {
            image.dispose();
          }
        });
        await tester.tap(last);
        await settleSidebarWork(
          tester,
          () => AppDataOperations.instance.run(() async {}),
        );
        expect(host.manager.find('qa-comic', ComicType(source.key.hashCode)), [
          'QA Folder 10',
        ]);
        expect(localChanges, [true]);
        await tester.tap(button);
        await pumpSidebar(tester);
        await _create(tester, 'Created from fixed toolbar');
        final search = find.byKey(const ValueKey('favorite-folder-search'));
        await tester.scrollUntilVisible(
          search,
          -300,
          maxScrolls: 12,
          scrollable: scrolling,
        );
        await tester.enterText(search, 'Created from fixed toolbar');
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(ListTile, 'Created from fixed toolbar'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final localFirst in [false, true]) {
    testWidgets(
      'detail favorites retain section ordering and network mutations: localFirst=$localFirst',
      (tester) async {
        var mutations = 0;
        final source = _Source(
          network: FavoriteData(
            key: 'qa-network',
            title: 'Remote',
            multiFolder: false,
            loadComic: null,
            loadNext: null,
            addOrDelFavorite: (_, _, _, _) async {
              mutations++;
              return const Res(true);
            },
          ),
        );
        _registerSource(source);
        final networkChanges = <bool?>[];
        final host = _FolderCreationHost()
          ..content = _detailPanel(
            source,
            onFavorite: (_, network) => networkChanges.add(network),
          );
        final previous =
            appdata.settings[FavoritePreferences.localFavoritesFirst.key];
        appdata.settings[FavoritePreferences.localFavoritesFirst.key] =
            localFirst;
        addTearDown(
          () => appdata.settings[FavoritePreferences.localFavoritesFirst.key] =
              previous,
        );
        await host.mount(tester, folders: ['Local QA']);
        appdata.settings[FavoritePreferences.autoCloseFavoritePanel.key] =
            false;
        await tester.pumpAndSettle();
        final localY = tester.getTopLeft(find.text('Local Favorites')).dy;
        final networkY = tester
            .getTopLeft(find.text('Network Favorites').first)
            .dy;
        expect(localFirst ? localY < networkY : networkY < localY, isTrue);
        await tester.tap(
          find.descendant(
            of: find.byType(NetworkFavoriteSection),
            matching: find.text('Add'),
          ),
        );
        await tester.pumpAndSettle();
        expect(mutations, 1);
        expect(networkChanges, [true]);
        expect(find.text('Remove'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
