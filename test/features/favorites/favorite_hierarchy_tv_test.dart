import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/tv_navigation.dart';
import 'package:venera_next/features/favorites/favorite_folder.dart';
import 'package:venera_next/features/favorites/favorite_folder_browser.dart';

FavoriteFolderTree _tree() => FavoriteFolderTree(const [
  FavoriteFolder(id: 'parent', name: 'Parent', order: 0),
  FavoriteFolder(id: 'child', name: 'Child', parentId: 'parent', order: 0),
  FavoriteFolder(id: 'other', name: 'Other', order: 1),
]);

Widget _app(Widget child) {
  final navigator = GlobalKey<NavigatorState>();
  return MaterialApp(
    navigatorKey: navigator,
    builder: (context, child) => TvNavigation(
      enabled: true,
      onBack: () => unawaited(navigator.currentState!.maybePop()),
      child: child!,
    ),
    home: Scaffold(body: child),
  );
}

Future<void> _focus(WidgetTester tester, Finder target) async {
  final focus = Focus.of(tester.element(target));
  focus.requestFocus();
  await tester.pumpAndSettle();
  expect(focus.hasPrimaryFocus, isTrue);
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(
    key,
    physicalKey: key == LogicalKeyboardKey.goBack
        ? PhysicalKeyboardKey.escape
        : null,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('TV directions keep folder expansion separate from selection', (
    tester,
  ) async {
    final selected = <String>[];
    await tester.pumpWidget(
      _app(FavoriteFolderBrowser(tree: _tree(), onSelected: selected.add)),
    );
    await _focus(tester, find.text('Parent'));
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    await _press(tester, LogicalKeyboardKey.select);
    expect(find.text('Child'), findsOneWidget);
    expect(selected, isEmpty);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    await _press(tester, LogicalKeyboardKey.select);
    expect(selected, ['Parent']);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.select);
    expect(selected, ['Parent', 'Child']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV transfer cannot select its disabled parent as destination', (
    tester,
  ) async {
    final selected = <String>[];
    await tester.pumpWidget(
      _app(
        FavoriteFolderBrowser(
          tree: _tree(),
          hidden: const {'Parent'},
          disabled: const {'Parent'},
          checkboxes: true,
          onSelected: selected.add,
        ),
      ),
    );
    final parent = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, 'Parent'),
    );
    expect(parent.onChanged, isNull);
    await _focus(tester, find.byIcon(Icons.chevron_right));
    await _press(tester, LogicalKeyboardKey.select);
    await _focus(tester, find.text('Child'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(selected, ['Child']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV folder picker returns the key and restores remote focus', (
    tester,
  ) async {
    final selected = <String?>[];
    await tester.pumpWidget(
      _app(
        Center(
          child: FavoriteFolderSelect(
            tree: _tree(),
            current: 'Child',
            onChanged: selected.add,
          ),
        ),
      ),
    );
    await _focus(tester, find.text('Parent / Child'));
    await _press(tester, LogicalKeyboardKey.select);
    expect(find.byType(AlertDialog), findsOneWidget);
    await _focus(tester, find.text('Child'));
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.select);
    expect(selected, ['Other']);
    expect(find.byType(AlertDialog), findsNothing);
    await _press(tester, LogicalKeyboardKey.select);
    expect(find.byType(AlertDialog), findsOneWidget);
    await _press(tester, LogicalKeyboardKey.goBack);
    expect(find.byType(AlertDialog), findsNothing);
    expect(selected, ['Other']);
    await _press(tester, LogicalKeyboardKey.select);
    expect(find.byType(AlertDialog), findsOneWidget);
    await _press(tester, LogicalKeyboardKey.gameButtonB);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV remote can leave search and reach a nested folder', (
    tester,
  ) async {
    final selected = <String>[];
    await tester.pumpWidget(
      _app(FavoriteFolderBrowser(tree: _tree(), onSelected: selected.add)),
    );
    await tester.enterText(
      find.byKey(const ValueKey('favorite-folder-search')),
      'Child',
    );
    await tester.pumpAndSettle();
    final field = tester.widget<EditableText>(find.byType(EditableText));
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(field.controller.selection.baseOffset, 4);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(field.controller.selection.baseOffset, 5);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(field.focusNode.hasFocus, isFalse);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.select);
    expect(selected, ['Child']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV remote scrolls a lazy folder list without pointer input', (
    tester,
  ) async {
    final selected = <String>[];
    await tester.pumpWidget(
      _app(
        SizedBox(
          height: 240,
          child: FavoriteFolderBrowser(
            tree: FavoriteFolderTree.flat([
              for (var index = 0; index < 40; index++) 'Folder $index',
            ]),
            onSelected: selected.add,
          ),
        ),
      ),
    );
    await _focus(tester, find.text('Folder 0'));
    for (var index = 0; index < 20; index++) {
      await _press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(find.text('Folder 20').hitTestable(), findsOneWidget);
    await _press(tester, LogicalKeyboardKey.select);
    expect(selected, ['Folder 20']);
    expect(tester.takeException(), isNull);
  });
}
