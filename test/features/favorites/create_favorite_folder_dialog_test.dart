import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/favorites/create_favorite_folder_dialog.dart';

void main() {
  for (final fail in [false, true]) {
    testWidgets(
      'dismissed import does not commit or affect replacement; fail=$fail',
      (tester) async {
        final pending = Completer<String?>();
        var imports = 0;
        var reads = 0;
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(navigatorKey: navigator, home: const Scaffold()),
        );
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => CreateFavoriteFolderDialog(
              validate: (_) => null,
              create: (_) {},
              selectImport: (_) {
                reads++;
                return pending.future;
              },
              importJson: (_) => imports++,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Import from file'));
        await tester.tap(find.text('Import from file'));
        expect(reads, 1);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Replacement')),
          ),
        );
        await tester.pumpAndSettle();
        if (fail) {
          pending.completeError(StateError('read failed'));
        } else {
          pending.complete('{}');
        }
        await tester.pumpAndSettle();
        expect(imports, 0);
        expect(find.text('Replacement'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'read and import errors release controls and allow successful retry',
    (tester) async {
      var reads = 0;
      var imports = 0;
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Home')),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => CreateFavoriteFolderDialog(
            validate: (_) => null,
            create: (_) {},
            selectImport: (_) async {
              if (++reads == 1) throw StateError('read');
              return '{}';
            },
            importJson: (_) {
              if (++imports == 1) throw StateError('invalid json');
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Import from file'));
        await tester.pumpAndSettle();
        if (i < 2) expect(find.text('Failed to import'), findsOneWidget);
      }
      expect(reads, 3);
      expect(imports, 2);
      expect(find.text('Home'), findsOneWidget);
    },
  );

  testWidgets(
    'validation and cancelled selection preserve editable folder draft',
    (tester) async {
      final created = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: CreateFavoriteFolderDialog(
            validate: (name) => name.isEmpty ? 'Required' : null,
            create: created.add,
            selectImport: (_) async => null,
            importJson: (_) => fail('unexpected import'),
          ),
        ),
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text('Required'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Draft');
      await tester.tap(find.text('Import from file'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Draft',
      );
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      expect(created, isEmpty);
    },
  );
}
