import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/favorites/favorite_models.dart';
import 'package:venera_next/features/follow_updates/follow_updates_folder_dialog.dart';
import 'package:venera_next/features/follow_updates/follow_updates_manager.dart';
import 'package:venera_next/features/follow_updates/follow_updates_page.dart';
import 'package:venera_next/features/follow_updates/follow_updates_runtime.dart';
import 'package:venera_next/features/follow_updates/follow_updates_scope.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:window_manager/window_manager.dart';

final _gates = <Completer<void>>[];
final _jobs = <_Job>[];

class _Job extends Fake implements FollowUpdateJob {
  _Job() {
    _jobs.add(this);
  }
  final completed = Completer<void>();
  final events = StreamController<int>();
  bool cancelled = false;
  @override
  bool get isCancelled => cancelled;
  @override
  Stream<int> get updatedCounts => events.stream;
  @override
  Stream<UpdateProgress> get progress =>
      events.stream.map((value) => UpdateProgress(10, value, 0, 0));
  @override
  Future<void> get done => completed.future;
  @override
  void cancel() {
    cancelled = true;
  }
}

Future<void> _flush(WidgetTester tester, Future<void> work) async {
  var done = false;
  Object? error;
  work.then<void>(
    (_) => done = true,
    onError: (Object e) {
      error = e;
      done = true;
    },
  );
  for (var i = 0; i < 500 && !done; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(done, isTrue);
  expect(error, isNull);
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 500 && !condition(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

(Completer<void>, Future<void>) _block() {
  final gate = Completer<void>();
  _gates.add(gate);
  return (gate, AppDataOperations.instance.run(() => gate.future));
}

Future<
  ({
    Directory root,
    LocalFavoritesManager manager,
    FollowUpdatesRuntime runtime,
  })
>
_prepare(WidgetTester tester) async {
  final root = Directory.systemTemp.createTempSync('follow-folder-');
  final previousPath = App.dataPath;
  final previous = Map<String, dynamic>.from(
    appdata.toJson()['settings'] as Map,
  );
  App.dataPath = root.path;
  App.cachePath = root.path;
  _favoritesOwner = null;
  final manager = _favoritesForView();
  appdata.settings['language'] = 'en-US';
  appdata.settings['disableSyncFields'] = '';
  await tester.runAsync(() async {
    await manager.init();
    await manager.createFolder('A');
    await manager.createFolder('B');
    await manager.prepareTableForFollowUpdates('A', clearData: false);
    await manager.prepareTableForFollowUpdates('B', clearData: false);
    await manager.setFollowUpdatesFolder(
      null,
      generation: manager.connectionGeneration,
    );
  });
  final runtime = FollowUpdatesRuntime(
    folder: () => null,
    isChecking: () => false,
    waitForDownload: () async {},
    createTask: (_) => throw StateError('Unexpected background task'),
    onError: (_, _) {},
    observeChanges: (_) => () {},
  );
  registerShowMessageHandler((_, _) {});
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (_) async => false,
  );
  addTearDown(() async {
    for (final gate in _gates) {
      if (!gate.isCompleted) gate.complete();
    }
    _gates.clear();
    for (final job in _jobs) {
      if (!job.completed.isCompleted) job.completed.complete();
      unawaited(job.events.close());
    }
    _jobs.clear();
    await tester.pumpWidget(const SizedBox());
    await _flush(tester, appdata.saveData(false));
    await tester.runAsync(manager.closeAndWait);
    _favoritesOwner = null;
    runtime.dispose();
    previous.forEach((key, value) => appdata.settings[key] = value);
    App.dataPath = previousPath;
    root.deleteSync(recursive: true);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
  });
  return (root: root, manager: manager, runtime: runtime);
}

Map _saved(Directory root) =>
    (jsonDecode(File('${root.path}/appdata.json').readAsStringSync())
            as Map)['settings']
        as Map;

Future<void> _open(
  WidgetTester tester,
  FollowUpdatesRuntime runtime, {
  FollowUpdateJob Function(String)? createCheck,
  Future<void> Function()? onExit,
}) async {
  await tester.pumpWidget(
    _libraryView(
      MaterialApp(
        builder: onExit == null
            ? null
            : (_, child) => WindowFrame(child!, onExit: onExit),
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => FollowUpdatesFolderDialog(
                    runtime: runtime,
                    onSaved: () {},
                    createCheck: createCheck,
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Future<void> _chooseA(WidgetTester tester) async {
  final select = tester.widget<Select>(find.byType(Select));
  select.onTap!(select.values.indexOf('A'));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  App.dataPath = Directory.systemTemp.path;

  testWidgets(
    'stale preview cleanup preserves newer selection and restored folder',
    (tester) async {
      final f = await _prepare(tester);
      appdata.settings['followUpdatesFolder'] = 'missing';
      var (gate, exclusive) = _block();
      final selected = appdata.updateSettings((draft) {
        draft['followUpdatesFolder'] = 'B';
      });
      final cleanup = f.manager.clearMissingFollowUpdatesFolder(
        'missing',
        generation: f.manager.connectionGeneration,
      );
      gate.complete();
      await _flush(tester, Future.wait([exclusive, selected, cleanup]));
      expect(_saved(f.root)['followUpdatesFolder'], 'B');
      appdata.settings['followUpdatesFolder'] = 'restored';
      (gate, exclusive) = _block();
      final restored = AppDataOperations.instance.run(() async {
        await f.manager.createFolder('restored');
        await f.manager.prepareTableForFollowUpdates(
          'restored',
          clearData: false,
        );
      });
      final retry = f.manager.clearMissingFollowUpdatesFolder(
        'restored',
        generation: f.manager.connectionGeneration,
      );
      gate.complete();
      await _flush(tester, Future.wait([exclusive, restored, retry]));
      expect(_saved(f.root)['followUpdatesFolder'], 'restored');
    },
  );

  for (final remove in [false, true]) {
    testWidgets('folder references merge queued settings: remove=$remove', (
      tester,
    ) async {
      final f = await _prepare(tester);
      appdata.settings['followUpdatesFolder'] = 'A';
      appdata.settings['quickFavorite'] = 'A';
      final (gate, exclusive) = _block();
      final choice = appdata.updateSettings((draft) {
        draft['followUpdatesFolder'] = 'B';
        draft['readerMode'] = 'topToBottom';
      });
      final mutation = remove
          ? f.manager.deleteFolder('A')
          : f.manager.rename('A', 'Renamed');
      gate.complete();
      await _flush(tester, Future.wait([exclusive, choice, mutation]));
      expect(_saved(f.root)['followUpdatesFolder'], 'B');
      expect(_saved(f.root)['quickFavorite'], remove ? null : 'Renamed');
      expect(_saved(f.root)['readerMode'], 'topToBottom');
    });
  }

  testWidgets(
    'preview owns admitted invalid-folder repair across removal and close',
    (tester) async {
      final f = await _prepare(tester);
      appdata.settings['followUpdatesFolder'] = 'missing';
      final (gate, exclusive) = _block();
      var showing = true;
      var exits = 0;
      late StateSetter update;
      await tester.pumpWidget(
        FollowUpdatesScope(
          runtime: f.runtime,
          child: _libraryView(
            MaterialApp(
              builder: (_, child) => WindowFrame(
                child!,
                onExit: () async {
                  exits++;
                },
              ),
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (_, setState) {
                    update = setState;
                    return CustomScrollView(
                      slivers: [if (showing) const FollowUpdatesWidget()],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final owner = tester.state<SettingsSaveState>(
        find.byType(FollowUpdatesWidget),
      );
      expect(owner.savingSettings, isTrue);
      update(() => showing = false);
      await tester.pump();
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await tester.pump();
      expect(exits, 0);
      gate.complete();
      await _flush(
        tester,
        Future.wait([exclusive, owner.waitForSettingsSave()]),
      );
      await _until(tester, () => exits == 1);
      expect(_saved(f.root)['followUpdatesFolder'], isNull);
    },
  );

  testWidgets(
    'failed final selection save retries without repeating network check',
    (tester) async {
      final f = await _prepare(tester);
      await tester.runAsync(
        () => f.manager.addComic(
          'A',
          FavoriteItem(
            id: 'one',
            name: 'One',
            coverPath: '',
            author: '',
            type: ComicType.local,
            tags: const [],
          ),
        ),
      );
      var checks = 0;
      await _open(
        tester,
        f.runtime,
        createCheck: (_) {
          checks++;
          return _Job()..completed.complete();
        },
      );
      await _chooseA(tester);
      File('${f.root.path}/appdata.json').deleteSync();
      final blocked = Directory('${f.root.path}/appdata.json')..createSync();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await _until(tester, () => find.text('Retry').evaluate().isNotEmpty);
      expect(checks, 1);
      blocked.deleteSync();
      await tester.tap(find.text('Retry'));
      await _flush(
        tester,
        tester
            .state<SettingsSaveState>(find.byType(FollowUpdatesFolderDialog))
            .waitForSettingsSave(),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FollowUpdatesFolderDialog), findsNothing);
      expect(checks, 1);
      expect(_saved(f.root)['followUpdatesFolder'], 'A');
    },
  );

  testWidgets(
    'removed preparation cancels check and window waits for actual completion',
    (tester) async {
      final f = await _prepare(tester);
      await tester.runAsync(
        () => f.manager.addComic(
          'A',
          FavoriteItem(
            id: 'one',
            name: 'One',
            coverPath: '',
            author: '',
            type: ComicType.local,
            tags: const [],
          ),
        ),
      );
      final job = _Job();
      var checks = 0;
      var exits = 0;
      await _open(
        tester,
        f.runtime,
        createCheck: (_) {
          checks++;
          return job;
        },
        onExit: () async {
          exits++;
        },
      );
      await _chooseA(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await _until(tester, () => checks == 1);
      // A network check must not hold ordinary admission across its wait.
      var exclusiveEntered = false;
      await _flush(
        tester,
        AppDataOperations.instance.run(() {
          exclusiveEntered = true;
        }),
      );
      expect(exclusiveEntered, isTrue);
      final context = tester.element(find.byType(FollowUpdatesFolderDialog));
      Navigator.of(context).removeRoute(ModalRoute.of(context)!);
      await tester.pump();
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await tester.pump();
      expect(job.cancelled, isTrue);
      expect(exits, 0);
      job.completed.complete();
      await _until(tester, () => exits == 1);
      expect(appdata.settings['followUpdatesFolder'], isNull);
    },
  );

  testWidgets(
    'disable assignment survives dialog removal and is awaited by window',
    (tester) async {
      final f = await _prepare(tester);
      await _flush(
        tester,
        f.manager.setFollowUpdatesFolder(
          'B',
          generation: f.manager.connectionGeneration,
        ),
      );
      var exits = 0;
      await _open(
        tester,
        f.runtime,
        onExit: () async {
          exits++;
        },
      );
      final (gate, exclusive) = _block();
      final owner = tester.state<SettingsSaveState>(
        find.byType(FollowUpdatesFolderDialog),
      );
      await tester.tap(find.text('Disable'));
      await tester.pump();
      expect(owner.savingSettings, isTrue);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(find.byType(FollowUpdatesFolderDialog), findsOneWidget);
      final context = tester.element(find.byType(FollowUpdatesFolderDialog));
      Navigator.of(context).removeRoute(ModalRoute.of(context)!);
      await tester.pump();
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await tester.pump();
      expect(exits, 0);
      gate.complete();
      await _flush(
        tester,
        Future.wait([exclusive, owner.waitForSettingsSave()]),
      );
      await _until(tester, () => exits == 1);
      expect(_saved(f.root)['followUpdatesFolder'], isNull);
    },
  );

  testWidgets(
    'parent removal retires selector while queued preparation is cancelled',
    (tester) async {
      final f = await _prepare(tester);
      await tester.runAsync(() async {
        final comic = FavoriteItem(
          id: 'preserved',
          name: 'Preserved',
          coverPath: '',
          author: '',
          type: ComicType.local,
          tags: const [],
        );
        await f.manager.addComic('A', comic, null, '2026-01-01');
        await f.manager.updateUpdateTime(
          'A',
          comic.id,
          comic.type,
          '2026-01-02',
        );
      });
      var showing = true;
      var checks = 0;
      late StateSetter update;
      await tester.pumpWidget(
        FollowUpdatesScope(
          runtime: f.runtime,
          child: _libraryView(
            MaterialApp(
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (_, setState) {
                    update = setState;
                    return showing
                        ? FollowUpdatesPage(
                            createCheck: (_) {
                              checks++;
                              return _Job();
                            },
                          )
                        : const SizedBox();
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose Folder'));
      await tester.pumpAndSettle();
      await _chooseA(tester);
      final (gate, exclusive) = _block();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      update(() => showing = false);
      await tester.pump();
      await tester.pump();
      expect(find.byType(FollowUpdatesFolderDialog), findsNothing);
      gate.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      expect(checks, 0);
      expect(
        f.manager.getComicsWithUpdatesInfo('A').single.hasNewUpdate,
        isTrue,
      );
      expect(_saved(f.root)['followUpdatesFolder'], isNull);
    },
  );
  testWidgets('selector rejects database replacement after opening', (
    tester,
  ) async {
    final f = await _prepare(tester);
    var checks = 0;
    await _open(
      tester,
      f.runtime,
      createCheck: (_) {
        checks++;
        return _Job();
      },
    );
    await _chooseA(tester);
    await tester.runAsync(() async {
      await f.manager.closeAndWait();
      await f.manager.init();
    });
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await _until(
      tester,
      () => find.textContaining('replaced database').evaluate().isNotEmpty,
    );
    expect(checks, 0);
    expect(appdata.settings['followUpdatesFolder'], isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'narrow large-text preparation cancel waits for real check completion',
    (tester) async {
      final f = await _prepare(tester);
      await tester.runAsync(
        () => f.manager.addComic(
          'A',
          FavoriteItem(
            id: 'one',
            name: 'One',
            coverPath: '',
            author: '',
            type: ComicType.local,
            tags: const [],
          ),
        ),
      );
      tester.view.physicalSize = const Size(375, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final job = _Job();
      var checks = 0;
      await tester.pumpWidget(
        _libraryView(
          MaterialApp(
            theme: ThemeData.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.8)),
              child: child!,
            ),
            home: Scaffold(
              body: Center(
                child: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => FollowUpdatesFolderDialog(
                        runtime: f.runtime,
                        onSaved: () {},
                        createCheck: (_) {
                          checks++;
                          return job;
                        },
                      ),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await _chooseA(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await _until(tester, () => checks == 1);
      job.events.add(5);
      await tester.pump();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0.5,
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(job.cancelled, isTrue);
      expect(find.byType(FollowUpdatesFolderDialog), findsOneWidget);
      job.completed.complete();
      await _until(
        tester,
        () => find.byType(FollowUpdatesFolderDialog).evaluate().isEmpty,
      );
      expect(appdata.settings['followUpdatesFolder'], isNull);
      expect(tester.takeException(), isNull);
    },
  );
}

LocalFavoritesManager? _favoritesOwner;
LocalFavoritesManager _favoritesForView() =>
    _favoritesOwner ??= LocalFavoritesManager.independent();
Widget _libraryView(Widget child) {
  return FavoritesScope(manager: _favoritesForView(), child: child);
}
