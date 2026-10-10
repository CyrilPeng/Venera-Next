import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/history/image_favorites.dart';
import 'package:venera_next/features/history/image_favorites_models.dart';
import 'package:venera_next/features/image_favorites/image_favorites_summary.dart';

class _Images extends ChangeNotifier implements ImageFavoriteManager {
  final reply = Completer<ImageFavoritesComputed>();
  bool get observed => hasListeners;

  @override
  Future<ImageFavoritesComputed> compute() => reply.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'summary replacement detaches listeners and ignores old statistics',
    (tester) async {
      final old = _Images(), current = _Images();
      addTearDown(old.dispose);
      addTearDown(current.dispose);
      Widget view(ImageFavoriteManager manager) => MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [ImageFavoritesSummary(manager: manager)],
          ),
        ),
      );
      await tester.pumpWidget(view(old));
      expect(old.observed, isTrue);
      await tester.pumpWidget(view(current));
      expect(old.observed, isFalse);
      expect(current.observed, isTrue);
      current.reply.complete(
        const ImageFavoritesComputed(
          [TextWithCount('Current library', 2)],
          [],
          [],
          2,
        ),
      );
      await tester.pump();
      old.reply.complete(
        const ImageFavoritesComputed(
          [TextWithCount('Retired library', 1)],
          [],
          [],
          1,
        ),
      );
      await tester.pump();
      expect(find.text('Current library'), findsOneWidget);
      expect(find.text('Retired library'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      expect(current.observed, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
