import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_details/actions.dart';
import 'package:venera_next/features/comic_details/archive_download_dialog.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/history/history_api.dart';
import 'package:venera_next/features/local_comics/archive_download_task.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/selection_operation.dart';

import 'archive_selection_ownership_test.dart'
    show drainArchiveWork, frames, option;

class _Source extends Fake implements ComicSource {
  _Source(this.archiveDownloader);
  @override
  final String key = 'archive-action-source';
  @override
  final ArchiveDownloader archiveDownloader;
}

ComicDetails _comic([String id = 'original']) => ComicDetails.fromJson({
  'comicId': id,
  'title': 'Comic $id',
  'cover': '',
  'tags': <String, List<String>>{},
  'sourceKey': 'archive-action-source',
  'chapters': {'one': 'Chapter one'},
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
    if (route is PopupRoute) {
      unawaited(
        route.popped.then((value) {
          if (value is ArchiveDownloadSelection) onAccepted?.call();
        }),
      );
    }
  }
}

void main() {
  final messages = <String>[];
  final published = <ArchiveDownloadTask>[];
  late LocalManager library;
  late _Source source;
  var lists = 0, links = 0;

  setUp(() {
    rootBundle.clear();
    final root = Directory.systemTemp.createTempSync('venera-archive-choice-');
    final ownedPath = root.resolveSymbolicLinksSync();
    final tempPath = Directory.systemTemp.resolveSymbolicLinksSync();
    LocalManager.resetForTesting();
    App.dataPath = root.path;
    App.cachePath = root.path;
    final initialized = App.isInitialized;
    final muted = Log.isMuted;
    final language = appdata.settings['language'];
    App.isInitialized = false;
    Log.isMuted = true;
    appdata.settings['language'] = 'en-US';
    messages.clear();
    published.clear();
    lists = links = 0;
    registerShowMessageHandler((_, message) => messages.add(message));
    source = _Source(
      ArchiveDownloader(
        (id) async {
          expectSync(id, 'original');
          lists++;
          return Res([option()]);
        },
        (id, archive) async {
          expectSync(id, 'original');
          expectSync(archive, 'original');
          links++;
          return const Res('  synthetic-archive  ');
        },
      ),
    );
    configureComicSourceRegistry(
      all: () => [source],
      find: (key) => key == source.key ? source : null,
      fromIntKey: (key) => key == source.key.hashCode ? source : null,
      isEmpty: () => false,
    );
    library = LocalManager();
    void recordPublication() {
      // Observe the real queue, then remove the synthetic task synchronously.
      // The queue's revision guard prevents starting any downloader or I/O.
      for (final task in library.downloadingTasks.toList()) {
        if (task is ArchiveDownloadTask) {
          published.add(task);
          library.removeTask(task);
        }
      }
    }

    library.addListener(recordPublication);
    addTearDown(() async {
      library.removeListener(recordPublication);
      LocalManager.resetForTesting();
      configureComicSourceRegistry(
        all: () => [],
        find: (_) => null,
        fromIntKey: (_) => null,
        isEmpty: () => true,
      );
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
  });

  Future<
    ({
      GlobalKey<NavigatorState> navigator,
      _Actions actions,
      SelectionTaskRegistry registry,
      ValueNotifier<bool> allowed,
      _AfterSelection observer,
    })
  >
  mount(WidgetTester tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final registry = SelectionTaskRegistry();
    final allowed = ValueNotifier(true);
    final observer = _AfterSelection();
    late _Actions actions;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [observer],
        builder: (_, child) => SelectionTasksScope(
          registry: registry,
          child: NavigationAdmission(
            allowsNavigation: () => allowed.value,
            child: child!,
          ),
        ),
        home: Builder(
          builder: (context) {
            actions = _Actions(context, source);
            return const Scaffold(body: Text('Original comic'));
          },
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      await drainArchiveWork(tester, registry.closeAndWait);
      await drainArchiveWork(tester, () => library.pendingDownloadTaskWrites);
      allowed.dispose();
    });
    return (
      navigator: navigator,
      actions: actions,
      registry: registry,
      allowed: allowed,
      observer: observer,
    );
  }

  Future<void> choose(WidgetTester tester) async {
    await frames(tester);
    await tester.tap(find.text('Archive').first);
    await frames(tester);
    tester.widget<RadioGroup<int>>(find.byType(RadioGroup<int>)).onChanged(0);
    await frames(tester);
    await tester.tap(find.text('Confirm'));
    await frames(tester);
  }

  for (final covered in [false, true]) {
    testWidgets(
      'download action rejects inactive presentation: covered=$covered',
      (tester) async {
        final host = await mount(tester);
        if (covered) {
          host.navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Newer page')),
            ),
          );
          await frames(tester);
        } else {
          host.allowed.value = false;
        }
        final operation = host.actions.download();
        operation.ignore();
        await frames(tester);
        expect(find.byType(ArchiveDownloadDialog), findsNothing);
        expect(published, isEmpty);
        expect(messages, isEmpty);
        await drainArchiveWork(tester, () => operation);
      },
    );
  }

  for (final invalidation in ['frozen', 'covered', 'closed', 'target']) {
    testWidgets(
      'download publication rechecks the original owner: $invalidation',
      (tester) async {
        final host = await mount(tester);
        host.observer.onAccepted = () {
          if (invalidation == 'frozen') {
            host.allowed.value = false;
          } else if (invalidation == 'covered') {
            host.navigator.currentState!.push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Newer page')),
              ),
            );
          } else if (invalidation == 'closed') {
            unawaited(host.registry.closeAndWait());
          } else {
            host.actions.comic = _comic('replacement');
          }
        };
        final operation = host.actions.download();
        await choose(tester);
        await drainArchiveWork(tester, () => operation);
        expect(published, isEmpty);
        expect(messages, isEmpty);
        expect(host.actions.updates, 0);
        expect(links, 1);
        if (invalidation == 'covered') {
          expect(find.text('Newer page'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final built in [false, true]) {
    testWidgets(
      'download action finishes after Navigator disposal: built=$built',
      (tester) async {
        final host = await mount(tester);
        var finished = false;
        final operation = host.actions.download().then((_) => finished = true);
        operation.ignore();
        if (built) {
          await frames(tester);
        } else {
          await tester.idle();
        }
        await tester.pumpWidget(const SizedBox());
        await frames(tester);
        expect(finished, isTrue);
        expect(published, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('accepted archive is published once with the original data', (
    tester,
  ) async {
    final host = await mount(tester);
    final operation = host.actions.download();
    await host.actions.download();
    await choose(tester);
    await drainArchiveWork(tester, () => operation);
    expect(published, hasLength(1));
    expect(published.single.comic, same(host.actions.comic));
    expect(published.single.archiveUrl, 'synthetic-archive');
    expect(published.single.isPaused, isTrue);
    expect(lists, 1);
    expect(links, 1);
    expect(host.actions.updates, 1);
    expect(messages, ['Download started']);
    expect(tester.takeException(), isNull);
  });
}
