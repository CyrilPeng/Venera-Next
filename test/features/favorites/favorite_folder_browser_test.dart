import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/features/favorites/favorite_folder.dart';
import 'package:venera_next/features/favorites/favorite_folder_browser.dart';
import 'package:venera_next/foundation/app_profile.dart';

FavoriteFolderTree _tree() => FavoriteFolderTree(const [
  FavoriteFolder(id: 'reading', name: 'Reading', order: 0),
  FavoriteFolder(
    id: 'weekly',
    name: 'Every week',
    order: 0,
    parentId: 'reading',
  ),
  FavoriteFolder(id: 'paused', name: 'Paused', order: 1, parentId: 'reading'),
  FavoriteFolder(id: 'short', name: 'Short stories', order: 1),
]);

void main() {
  final visualQa = Platform.environment['FAVORITES_VISUAL_QA'] == '1';
  setUpAll(() async {
    if (!visualQa) return;
    final font = File(r'C:\Windows\Fonts\segoeui.ttf');
    if (await font.exists()) {
      await (FontLoader(
        'FavoritesVisualQA',
      )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets(
    'expansion and selection are separate; search reveals matching ancestry',
    (tester) async {
      final selected = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FavoriteFolderBrowser(
              tree: _tree(),
              onSelected: selected.add,
            ),
          ),
        ),
      );
      expect(find.text('Every week'), findsNothing);
      await tester.tap(find.text('Reading'));
      expect(selected, ['Reading']);
      expect(find.text('Every week'), findsNothing);
      await tester.tap(find.byTooltip('Expand folder'));
      await tester.pumpAndSettle();
      expect(find.text('Every week'), findsOneWidget);
      expect(selected, ['Reading']);
      await tester.tap(find.byTooltip('Collapse folder'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('favorite-folder-search')),
        'week',
      );
      await tester.pumpAndSettle();
      expect(find.text('Reading'), findsOneWidget);
      expect(find.text('Every week'), findsOneWidget);
      expect(find.text('Reading / Every week'), findsOneWidget);
      expect(find.text('Short stories'), findsNothing);
      await tester.tap(find.text('Every week'));
      expect(selected, ['Reading', 'Every week']);
      expect(_tree().named('Every week')!.parentId, 'reading');
    },
  );

  testWidgets(
    'selected child reveals its parent and disabled destinations cannot be chosen',
    (tester) async {
      final selected = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FavoriteFolderBrowser(
              tree: _tree(),
              selected: const {'Every week'},
              disabled: const {'Reading'},
              checkboxes: true,
              onSelected: selected.add,
            ),
          ),
        ),
      );
      expect(find.text('Every week'), findsOneWidget);
      final parent = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, 'Reading'),
      );
      expect(parent.onChanged, isNull);
      await tester.tap(find.text('Paused'));
      expect(selected, ['Paused']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search keeps editing keys and uses build-specific TV traversal',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FavoriteFolderBrowser(tree: _tree(), onSelected: (_) {}),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('favorite-folder-search')),
        'week',
      );
      await tester.pumpAndSettle();
      final field = tester.widget<EditableText>(find.byType(EditableText));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(field.controller.selection.baseOffset, 3);
      expect(field.focusNode.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(field.focusNode.hasFocus, !AppProfile.current.isTv);
      expect(field.controller.text, 'week');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('large flat lists build lazily and can locate the last folder', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FavoriteFolderBrowser(
            tree: FavoriteFolderTree.flat([
              for (var i = 0; i < 600; i++) 'Folder $i',
            ]),
            onSelected: (_) {},
          ),
        ),
      ),
    );
    expect(find.byType(ListTile).evaluate().length, lessThan(40));
    await tester.enterText(
      find.byKey(const ValueKey('favorite-folder-search')),
      'Folder 599',
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Folder 599'), findsOneWidget);
    expect(find.text('Folder 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'shared selector displays paths but returns the original folder key',
    (tester) async {
      final selected = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: FavoriteFolderSelect(
                tree: _tree(),
                current: 'Every week',
                onChanged: selected.add,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Reading / Every week'), findsOneWidget);
      await tester.tap(find.byType(Select));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('favorite-folder-search')),
        'Paused',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Paused'));
      await tester.pumpAndSettle();
      expect(selected, ['Paused']);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'removing a selector while its owned menu is open does not publish a late choice',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FavoriteFolderSelect(
              tree: _tree(),
              current: null,
              onChanged: (_) => calls++,
            ),
          ),
        ),
      );
      await tester.tap(find.byType(Select));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in [
    (size: const Size(256, 740), scale: 2.0, dark: true),
    (size: const Size(375, 740), scale: 2.0, dark: false),
    (size: const Size(812, 375), scale: 2.0, dark: true),
    (size: const Size(1024, 768), scale: 1.0, dark: false),
  ]) {
    testWidgets('folder browser remains usable at $scenario', (tester) async {
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: (scenario.dark ? ThemeData.dark() : ThemeData.light())
              .copyWith(
                textTheme:
                    (scenario.dark ? ThemeData.dark() : ThemeData.light())
                        .textTheme
                        .apply(
                          fontFamily: visualQa ? 'FavoritesVisualQA' : null,
                        ),
              ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scenario.scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(
              body: FavoriteFolderBrowser(
                tree: _tree(),
                selected: const {'Every week'},
                countFor: (_) => 1234,
                onSelected: (_) {},
                headers: const [ListTile(title: Text('Local favorites'))],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (visualQa) {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final path =
            'build/favorites-hierarchy-qa/${scenario.size.width.toInt()}-${scenario.dark}.png';
        await tester.runAsync(() async {
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(path);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
}
