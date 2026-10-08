import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/components/side_bar.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_details/actions.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/history/history_api.dart';
import 'package:venera_next/features/local_comics/images_download_task.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/selection_operation.dart';

import '../../components/sidebar_presentation_test.dart'
    show pumpSidebar, settleSidebarWork;

class _Source extends Fake implements ComicSource {
  @override
  final String key = 'chapter-selection-source';
  @override
  ArchiveDownloader? get archiveDownloader => null;
}

ComicDetails _comic([String id = 'original']) => ComicDetails.fromJson({
  'comicId': id,
  'title': 'Comic $id',
  'cover': '',
  'tags': <String, List<String>>{},
  'sourceKey': 'chapter-selection-source',
  'chapters': {
    'ten': 'Chapter ten',
    'two': 'Chapter two',
    'bonus': 'Bonus chapter',
  },
});

class _Actions with ComicPageActions {
  _Actions(this.context, this.comicSource);
  @override
  final BuildContext context;
  @override
  final ComicSource comicSource;
  @override
  final contextMenus = MenuRouteController();
  @override
  ComicDetails comic = _comic();
  @override
  History? get history => null;
  @override
  bool isComicActive(ComicDetails value) =>
      context.mounted && identical(value, comic);
  int updates = 0;
  @override
  void update() => updates++;
  @override
  void onReadEnd() {}
}

class _AfterSelection extends NavigatorObserver {
  VoidCallback? onAccepted;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is SideBarRoute) {
      unawaited(route.popped.then((_) => onAccepted?.call()));
    }
  }
}

class _Host {
  final navigator = GlobalKey<NavigatorState>();
  final observer = _AfterSelection();
  final source = _Source();
  final registries = <SelectionTaskRegistry>[];
  SelectionTaskRegistry registry = SelectionTaskRegistry();
  _Actions? _actions;
  _Actions get actions => _actions!;
  bool allowed = true;
  bool failing = false;

  Widget tree() => MaterialApp(
    builder: (_, _) => SelectionTasksScope(
      registry: registry,
      child: NavigationAdmission(
        allowsNavigation: () => allowed,
        child: failing
            ? _FailingPopNavigator(
                key: navigator,
                observers: [observer],
                onGenerateRoute: _home,
              )
            : Navigator(
                key: navigator,
                observers: [observer],
                onGenerateRoute: _home,
              ),
      ),
    ),
  );

  Route<void> _home(RouteSettings settings) => MaterialPageRoute<void>(
    builder: (context) {
      _actions ??= _Actions(context, source);
      return const Scaffold(body: Text('Original comic'));
    },
  );

  Future<void> mount(WidgetTester tester, LocalManager library) async {
    registries.add(registry);
    await tester.pumpWidget(tree());
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await pumpSidebar(tester);
      for (final original in registries) {
        await settleSidebarWork(tester, original.closeAndWait);
      }
      await settleSidebarWork(tester, () => library.pendingDownloadTaskWrites);
    });
  }
}

CheckboxListTile _chapter(WidgetTester tester, String title) =>
    tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, title, skipOffstage: false),
    );

VoidCallback _all(WidgetTester tester) => tester
    .widget<TextButton>(find.widgetWithText(TextButton, 'Download All'))
    .onPressed!;

VoidCallback _selected(WidgetTester tester) => tester
    .widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Download Selected'),
    )
    .onPressed!;

SideBarRoute<dynamic> _route(WidgetTester tester) =>
    ModalRoute.of(tester.element(find.text('Download All')))!
        as SideBarRoute<dynamic>;

void main() {
  final published = <ImagesDownloadTask>[];
  final messages = <String>[];
  late LocalManager library;

  setUp(() async {
    rootBundle.clear();
    final root = Directory.systemTemp.createTempSync('venera-chapter-choice-');
    final ownedPath = root.resolveSymbolicLinksSync();
    final tempPath = Directory.systemTemp.resolveSymbolicLinksSync();
    LocalManager.resetForTesting();
    LocalManager.debugSkipComicSourceInit = true;
    App.dataPath = root.path;
    App.cachePath = root.path;
    File('${root.path}/local_path').writeAsStringSync(root.path);
    final initialized = App.isInitialized;
    final muted = Log.isMuted;
    final language = appdata.settings['language'];
    App.isInitialized = false;
    Log.isMuted = true;
    appdata.settings['language'] = 'en-US';
    published.clear();
    messages.clear();
    registerShowMessageHandler((_, message) => messages.add(message));
    library = LocalManager();
    addTearDown(() {
      LocalManager.resetForTesting();
      App.isInitialized = initialized;
      Log.isMuted = muted;
      appdata.settings['language'] = language;
      registerShowMessageHandler((_, _) {});
      expect(
        ownedPath.startsWith('$tempPath${Platform.pathSeparator}'),
        isTrue,
      );
      expect(root.resolveSymbolicLinksSync(), ownedPath);
      root.deleteSync(recursive: true);
    });
    await library.init();
    void recordPublication() {
      // Observe the production queue and remove the synthetic task before its
      // existing revision guard can start downloads or allocate directories.
      for (final task in library.downloadingTasks.toList()) {
        if (task is ImagesDownloadTask) {
          published.add(task);
          library.removeTask(task);
        }
      }
    }

    library.addListener(recordPublication);
    addTearDown(() => library.removeListener(recordPublication));
  });

  for (final built in [false, true]) {
    testWidgets(
      'ordinary download ends with Navigator disposal: built=$built',
      (tester) async {
        final host = _Host();
        await host.mount(tester, library);
        var finished = false;
        host.actions.download().then((_) => finished = true).ignore();
        if (built) {
          await pumpSidebar(tester);
        } else {
          await tester.idle();
        }
        await tester.pumpWidget(const SizedBox());
        await pumpSidebar(tester);
        expect(finished, isTrue);
        expect(published, isEmpty);
        expect(messages, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final state in ['covered', 'frozen', 'target', 'replacement']) {
    testWidgets('retained chapter controls reject inactive input: $state', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester, library);
      host.actions.download().ignore();
      await pumpSidebar(tester);
      _chapter(tester, 'Chapter ten').onChanged!(true);
      await pumpSidebar(tester);
      final toggle = _chapter(tester, 'Chapter ten').onChanged!;
      final all = _all(tester);
      final selected = _selected(tester);
      final original = _route(tester);
      Route<void>? newer;
      if (state == 'covered') {
        newer = MaterialPageRoute<void>(
          builder: (_) => const Text('Newer page'),
        );
        host.navigator.currentState!.push(newer);
        await pumpSidebar(tester);
      } else if (state == 'frozen') {
        host.allowed = false;
      } else if (state == 'target') {
        host.actions.comic = _comic('replacement');
      } else {
        host.registry = SelectionTaskRegistry();
        host.registries.add(host.registry);
        await tester.pumpWidget(host.tree());
        await pumpSidebar(tester);
      }
      toggle(false);
      await pumpSidebar(tester);
      expect(_chapter(tester, 'Chapter ten').value, isTrue);
      all();
      selected();
      await pumpSidebar(tester);
      expect(original.isActive, isTrue);
      expect(newer?.isCurrent ?? original.isCurrent, isTrue);
      expect(published, isEmpty);
      expect(messages, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'selected chapters keep source IDs, selection order and deduplication',
    (tester) async {
      final host = _Host();
      await host.mount(tester, library);
      final result = host.actions.download();
      await host.actions.download();
      await pumpSidebar(tester);
      _chapter(tester, 'Bonus chapter').onChanged!(true);
      _chapter(tester, 'Chapter ten').onChanged!(true);
      await pumpSidebar(tester);
      _selected(tester)();
      await settleSidebarWork(tester, () => result);
      expect(published, hasLength(1));
      expect(published.single.chapters, ['bonus', 'ten']);
      expect(published.single.source, same(host.source));
      expect(published.single.comic, same(host.actions.comic));
      expect(published.single.isPaused, isTrue);
      expect(host.actions.updates, 1);
      expect(messages, ['Download started']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Download All excludes already downloaded chapter IDs', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester, library);
    final comic = host.actions.comic;
    await library.add(
      LocalComic(
        id: comic.id,
        title: comic.title,
        subtitle: '',
        tags: const [],
        directory: 'synthetic-book',
        chapters: comic.chapters,
        cover: '',
        comicType: comic.comicType,
        downloadedChapters: const ['two'],
        createdAt: DateTime.utc(2026, 10, 8),
      ),
    );
    final result = host.actions.download();
    await pumpSidebar(tester);
    expect(_chapter(tester, 'Chapter two').value, isTrue);
    expect(_chapter(tester, 'Chapter two').onChanged, isNull);
    _all(tester)();
    await settleSidebarWork(tester, () => result);
    expect(published.single.chapters, ['ten', 'bonus']);
    expect(tester.takeException(), isNull);
  });

  for (final dismissal in ['back', 'barrier']) {
    testWidgets('ordinary chapter $dismissal publishes no selection', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester, library);
      final result = host.actions.download();
      await pumpSidebar(tester);
      _chapter(tester, 'Chapter ten').onChanged!(true);
      if (dismissal == 'back') {
        host.navigator.currentState!.pop();
      } else {
        await tester.tapAt(const Offset(1, 1));
      }
      await settleSidebarWork(tester, () => result);
      expect(published, isEmpty);
      expect(messages, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a newer route after selection prevents queue publication', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester, library);
    final result = host.actions.download();
    await pumpSidebar(tester);
    host.observer.onAccepted = () => host.navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('Newer page')),
    );
    _all(tester)();
    await settleSidebarWork(tester, () => result);
    await pumpSidebar(tester);
    expect(published, isEmpty);
    expect(messages, isEmpty);
    expect(find.text('Newer page'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed confirmation followed by Back publishes no selection', (
    tester,
  ) async {
    final host = _Host()..failing = true;
    await host.mount(tester, library);
    final result = host.actions.download();
    await pumpSidebar(tester);
    final navigator = host.navigator.currentState! as _FailingPopNavigatorState;
    navigator.fails = true;
    expect(_all(tester), throwsA(same(navigator.failure)));
    navigator.fails = false;
    navigator.pop();
    await settleSidebarWork(tester, () => result);
    expect(published, isEmpty);
    expect(messages, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('published IDs use the chapter order presented to the user', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester, library);
    final result = host.actions.download();
    await pumpSidebar(tester);
    _chapter(tester, 'Bonus chapter').onChanged!(true);
    await pumpSidebar(tester);
    host.actions.comic.chapters!.allChapters
      ..clear()
      ..addAll({'changed': 'Changed chapter'});
    _selected(tester)();
    await settleSidebarWork(tester, () => result);
    expect(published.single.chapters, ['bonus']);
    expect(messages, ['Download started']);
    expect(tester.takeException(), isNull);
  });
}

class _FailingPopNavigator extends Navigator {
  const _FailingPopNavigator({
    super.key,
    super.observers,
    super.onGenerateRoute,
  });
  @override
  NavigatorState createState() => _FailingPopNavigatorState();
}

class _FailingPopNavigatorState extends NavigatorState {
  bool fails = false;
  final failure = StateError('chapter confirmation pop failed');
  @override
  void pop<T extends Object?>([T? result]) {
    if (fails) throw failure;
    super.pop(result);
  }
}
