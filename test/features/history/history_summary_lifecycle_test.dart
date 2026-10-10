import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/history/history_model.dart';
import 'package:venera_next/features/history/history_summary.dart';
import 'package:venera_next/features/history/history_page.dart';
import 'package:venera_next/foundation/app.dart';

class _History extends HistoryManager {
  _History() : super.create();
  bool get observed => hasListeners;
  int queries = 0;
  @override
  List<History> getRecent() {
    queries++;
    return super.getRecent();
  }

  @override
  int count() {
    queries++;
    return super.count();
  }
}

class _Changes extends ChangeNotifier {
  bool get observed => hasListeners;
}

void main() {
  late Directory root;
  late _History history;
  late LocalFavoritesManager favorites;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('history-summary-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    history = _History();
    favorites = LocalFavoritesManager.independent();
    addTearDown(() {
      history.close();
      history.dispose();
      favorites.dispose();
      root.deleteSync(recursive: true);
    });
    await history.init();
  });
  Widget app() => MaterialApp(
    home: Scaffold(
      body: CustomScrollView(
        slivers: [HistorySummary(manager: history, favoriteChanges: favorites)],
      ),
    ),
  );

  testWidgets('summary navigation keeps its explicitly supplied history', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.byType(HistoryPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    expect(history.observed, isFalse);
  });

  testWidgets('summary detaches from the originally observed history owner', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    expect(history.observed, isTrue);
    final replacement = _History();
    addTearDown(replacement.dispose);
    await tester.pumpWidget(const SizedBox());
    expect(history.observed, isFalse);
  });

  testWidgets(
    'favorite notification after history closes cannot query its database',
    (tester) async {
      await tester.pumpWidget(app());
      history.close();
      favorites.notifyListeners();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'history summary transfers borrowed listeners on explicit replacement',
    (tester) async {
      final second = _History();
      final firstChanges = _Changes(), secondChanges = _Changes();
      addTearDown(second.dispose);
      addTearDown(firstChanges.dispose);
      addTearDown(secondChanges.dispose);
      Widget view(HistoryManager? owner, Listenable? changes) => MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [HistorySummary(manager: owner, favoriteChanges: changes)],
          ),
        ),
      );
      await tester.pumpWidget(view(history, firstChanges));
      expect(history.observed, isTrue);
      expect(firstChanges.observed, isTrue);
      await tester.pumpWidget(view(second, secondChanges));
      expect(history.observed, isFalse);
      expect(firstChanges.observed, isFalse);
      expect(second.observed, isTrue);
      expect(secondChanges.observed, isTrue);
      firstChanges.notifyListeners();
      secondChanges.notifyListeners();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(view(null, null));
      expect(second.observed, isFalse);
      expect(secondChanges.observed, isFalse);
      secondChanges.notifyListeners();
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'history summary queries on notifications, not on theme rebuilds',
    (tester) async {
      Widget view(Brightness brightness) => MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              HistorySummary(manager: history, favoriteChanges: favorites),
            ],
          ),
        ),
      );
      await tester.pumpWidget(view(Brightness.light));
      final queries = history.queries;
      expect(queries, 2);
      await tester.pumpWidget(view(Brightness.dark));
      await tester.pumpAndSettle();
      expect(history.queries, queries);
      favorites.notifyListeners();
      await tester.pump();
      expect(history.queries, queries + 2);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
