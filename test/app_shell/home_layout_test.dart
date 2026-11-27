import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_shell/home_page.dart';
import 'package:venera_next/components/tv_navigation.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/features/follow_updates/follow_updates_runtime.dart';
import 'package:venera_next/features/follow_updates/follow_updates_scope.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/history/history_scope.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';

const _modules = [
  'history',
  'read-later',
  'local-comics',
  'follow-updates',
  'comic-sources',
  'image-favorites',
];

Finder _module(String id) => find.byKey(ValueKey(id));
Finder get _editor => find.widgetWithText(AppBar, 'Customize home');

Finder _toggle(String id) =>
    find.descendant(of: _module(id), matching: find.byType(SwitchListTile));

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, 'Customize home'));
  await tester.pumpAndSettle();
  expect(_editor, findsOneWidget);
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Save'));
  final deadline = Stopwatch()..start();
  final editor = _editor;
  while (editor.evaluate().isNotEmpty && deadline.elapsed.inSeconds < 5) {
    // Let writes complete on the real clock and process the resulting pop on
    // the widget clock, including the settings save guard and its cleanup.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(editor, findsNothing, reason: 'Saving should return to the homepage');
  await tester.pumpAndSettle();
}

class _ReadCountingHistory extends HistoryManager {
  _ReadCountingHistory() : super.create();
  int recentReads = 0;

  @override
  List<History> getRecent() {
    recentReads++;
    return super.getRecent();
  }
}

void main() {
  testWidgets(
    'home layout saves drag, hides history, and restores using TV input',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'venera-home-layout-',
      );
      App.dataPath = App.cachePath = directory.path;
      appdata.settings['language'] = 'en-US';
      tester.view.physicalSize = const Size(375, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final history = _ReadCountingHistory();
      final pictures = ImageFavoriteManager.create(history: history);
      final local = LocalManager(initializeSources: () async {});
      final favorites = LocalFavoritesManager.independent();
      final follow = FollowUpdatesRuntime(
        folder: () => null,
        isChecking: () => false,
        waitForDownload: () async {},
        createTask: (_) => throw StateError('Unexpected update check'),
        onError: (_, _) {},
        observeChanges: (_) => () {},
      );
      final sync = DataSyncController(
        preferences: SyncPreferenceStore(
          readSetting: (key) => key == 'webdav'
              ? ['https://example.invalid/dav/', 'test', 'test']
              : null,
          writeSetting: (_, _) {},
          implicitData: () => {},
        ),
        transfer: () => throw StateError('Unexpected backup transfer'),
        saveSettings: () async {},
        persistImplicit: () {},
        observeChanges: (_) => () {},
      );

      Widget app({bool tv = false}) => FavoritesScope(
        manager: favorites,
        child: HistoryScope(
          manager: history,
          imageFavorites: pictures,
          child: FollowUpdatesScope(
            runtime: follow,
            child: DataSyncScope(
              controller: sync,
              child: MaterialApp(
                builder: (_, child) => TvNavigation(enabled: tv, child: child!),
                home: const Scaffold(body: HomePage()),
              ),
            ),
          ),
        ),
      );

      try {
        await tester.runAsync(() async {
          await history.init();
          await local.init();
          await favorites.init();
        });
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        expect(find.byType(HistorySummary), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('History')).dy,
          lessThan(tester.getTopLeft(find.text('Read later · 0')).dy),
        );
        await _open(tester);
        final drag = find.descendant(
          of: _module('image-favorites'),
          matching: find.byType(ReorderableDragStartListener),
        );
        final start = tester.getCenter(drag);
        final gesture = await tester.startGesture(start);
        await gesture.moveBy(const Offset(0, -24));
        await tester.pump(const Duration(milliseconds: 250));
        await gesture.moveTo(
          Offset(start.dx, tester.getTopLeft(_module('history')).dy - 8),
        );
        await tester.pumpAndSettle();
        await gesture.up();
        await tester.pumpAndSettle();
        expect(
          tester.getTopLeft(_module('image-favorites')).dy,
          lessThan(tester.getTopLeft(_module('read-later')).dy),
        );
        await tester.tap(_toggle('history'));
        await _save(tester);
        expect(find.byType(HistorySummary), findsNothing);

        final readsWhileHidden = history.recentReads;
        final comic = History(
          type: ComicType.local,
          time: DateTime.now(),
          id: 'test-comic',
          title: 'Read while the module is hidden',
          subtitle: '',
          cover: '',
          ep: 3,
          page: 8,
          readEpisode: {'3'},
          maxPage: 14,
          readDurationMs: 0,
        );
        await tester.runAsync(() => history.addHistory(comic));
        await tester.pump();
        expect(history.find(comic.id, comic.type)?.page, 8);
        expect(history.recentReads, readsWhileHidden);

        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          appdata.settings[HomePreferences.moduleOrder.key] = <String>[];
          appdata.settings[HomePreferences.hiddenModules.key] = <String>[];
          await appdata.loadDataForTesting(directory.path);
        });
        await tester.pumpWidget(app(tv: true));
        await tester.pumpAndSettle();
        expect(find.byType(HistorySummary), findsNothing);
        expect(
          tester.getTopLeft(find.text('Image Favorites')).dy,
          lessThan(tester.getTopLeft(find.text('Read later · 0')).dy),
        );
        await _open(tester);
        expect(find.byType(ReorderableDragStartListener), findsNothing);
        for (final id in _modules.where((id) => id != 'history')) {
          await tester.ensureVisible(_toggle(id));
          await tester.tap(_toggle(id));
          await tester.pump();
        }
        await _save(tester);
        for (final id in _modules) {
          expect(_module(id), findsNothing);
        }
        expect(find.text('Search'), findsOneWidget);
        expect(find.text('Sync Data'), findsOneWidget);
        await _open(tester);
        await tester.tap(
          find.widgetWithText(OutlinedButton, 'Restore defaults'),
        );
        await tester.pumpAndSettle();
        final moveDown = find.descendant(
          of: _module('history'),
          matching: find.byIcon(Icons.arrow_downward),
        );
        final target = Focus.of(tester.element(moveDown));
        Focus.of(tester.element(find.text('History'))).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(target.hasPrimaryFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        await _save(tester);

        expect(find.byType(HistorySummary), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('Read later · 0')).dy,
          lessThan(tester.getTopLeft(find.text('History')).dy),
        );
        expect(history.find(comic.id, comic.type)?.page, 8);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await favorites.closeAndWait();
          pictures.dispose();
          history.close();
          history.dispose();
          local.dispose();
          follow.dispose();
          sync.dispose();
          await directory.delete(recursive: true);
        });
      }
    },
  );
}
