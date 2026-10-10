import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/image_favorites/image_favorites_summary.dart';
import 'package:venera_next/foundation/app.dart';
import '../history/image_favorites_repository_test.dart' show comic;

void main() {
  late ImageFavoriteManager imageManager;
  setUpAll(() {
    App.dataPath = Directory.systemTemp.path;
    App.cachePath = Directory.systemTemp.path;
  });
  late Directory root;
  late HistoryManager history;
  late String previousData;
  late String previousCache;
  Future<void> prepare() async {
    root = Directory.systemTemp.createTempSync('summary-lifecycle-');
    previousData = App.dataPath;
    previousCache = App.cachePath;
    App.dataPath = root.path;
    App.cachePath = root.path;
    history = HistoryManager.create();
    imageManager = ImageFavoriteManager.create(history: history);
    await history.init();
    await history.accessImageFavorites(
      (repository, _) => repository.save(comic('sample')),
    );
  }

  tearDown(() {
    expect(history.hasPendingWrites, isFalse);
    history.close();
    imageManager.dispose();
    history.dispose();
    App.dataPath = previousData;
    App.cachePath = previousCache;
    root.deleteSync(recursive: true);
  });

  testWidgets('chart switch without a smooth-scroll ancestor remains usable', (
    tester,
  ) async {
    await prepare();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [ImageFavoritesSummary(manager: imageManager)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Authors'));
    await tester.pumpAndSettle();
    expect(find.text('Author'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('chart frame callback is harmless after summary disposal', (
    tester,
  ) async {
    await prepare();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SmoothCustomScrollView(
            slivers: [ImageFavoritesSummary(manager: imageManager)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Authors'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid chart switches use the latest layout before scrolling', (
    tester,
  ) async {
    await prepare();
    final controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SmoothCustomScrollView(
            controller: controller,
            slivers: [
              SliverToBoxAdapter(child: SizedBox(height: 350)),
              ImageFavoritesSummary(manager: imageManager),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Authors'));
    await tester.tap(find.text('Comics'));
    await tester.pumpAndSettle();
    expect(find.text('Title sample'), findsOneWidget);
    expect(
      controller.offset,
      closeTo(controller.position.maxScrollExtent, 0.1),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
