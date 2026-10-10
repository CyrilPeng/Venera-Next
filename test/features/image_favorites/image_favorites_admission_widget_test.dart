import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/history/image_favorites_repository.dart';
import 'package:venera_next/features/image_favorites/image_favorites_gallery_page.dart';
import 'package:venera_next/features/image_favorites/image_favorites_page.dart';
import 'package:venera_next/features/image_favorites/image_favorites_summary.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import '../history/image_favorites_repository_test.dart' show comic;

void main() {
  late ImageFavoriteManager imageManager;
  setUpAll(() {
    App.dataPath = Directory.systemTemp.path;
    App.cachePath = Directory.systemTemp.path;
  });

  Future<HistoryManager> prepare() async {
    final root = Directory.systemTemp.createTempSync('image-admission-ui-');
    final previousData = App.dataPath;
    final previousCache = App.cachePath;
    App.dataPath = root.path;
    App.cachePath = root.path;
    final history = HistoryManager.create();
    imageManager = ImageFavoriteManager.create(history: history);
    await history.init();
    addTearDown(() {
      expect(history.hasPendingWrites, isFalse);
      history.close();
      imageManager.dispose();
      history.dispose();
      App.dataPath = previousData;
      App.cachePath = previousCache;
      root.deleteSync(recursive: true);
    });
    return history;
  }

  testWidgets('pending search reads finish safely after the page is removed', (
    tester,
  ) async {
    await prepare();
    final release = Completer<void>();
    final replacement = AppDataOperations.instance.run(() => release.future);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ImageFavoritesPage(manager: imageManager)),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'old query');
    await tester.enterText(find.byType(TextField), 'new query');
    await tester.pumpWidget(const SizedBox());
    release.complete();
    await replacement;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('query failure exposes retry and repaired storage can load', (
    tester,
  ) async {
    final history = await prepare();
    history.imageFavoritesDatabase.execute('DROP TABLE image_favorites');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ImageFavoritesPage(manager: imageManager)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    ImageFavoritesRepository(history.imageFavoritesDatabase).initialize();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a deleted underlying gallery cannot pop an unrelated route', (
    tester,
  ) async {
    await prepare();
    final navigator = GlobalKey<NavigatorState>();
    final empty = comic('gone')..imageFavoritesEp.clear();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: ImageFavoritesGalleryPage(manager: imageManager, comic: empty),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Unrelated route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    imageManager.notifyChanges();
    await tester.pumpAndSettle();
    expect(find.text('Unrelated route'), findsOneWidget);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(ImageFavoritesGalleryPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('queued summary refresh cannot publish after unmount', (
    tester,
  ) async {
    await prepare();
    final release = Completer<void>();
    final replacement = AppDataOperations.instance.run(() => release.future);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [ImageFavoritesSummary(manager: imageManager)],
          ),
        ),
      ),
    );
    imageManager.notifyChanges();
    await tester.pumpWidget(const SizedBox());
    release.complete();
    await replacement;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
