import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/features/favorites/favorite_folder_path.dart';
import 'package:venera_next/foundation/appdata.dart';

const _parent = 'Parent / collection with a long name';
const _current = 'Child / collection with a long name';

void main() {
  final captureRoot = Platform.environment['VENERA_NAV_QA_DIR'];
  setUpAll(() async {
    if (captureRoot == null || !Platform.isWindows) return;
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final font = File(r'C:\Windows\Fonts\segoeui.ttf');
    if (!font.existsSync()) return;
    final loader = FontLoader('FavoritePathQA')
      ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
    await loader.load();
  });

  for (final size in [
    const Size(375, 800),
    const Size(450, 900),
    const Size(812, 375),
    const Size(768, 1024),
    const Size(1024, 768),
  ]) {
    for (final brightness in Brightness.values) {
      for (final textScale in [1.0, 3.2]) {
        testWidgets(
          'folder path remains usable at ${size.width} $brightness scale $textScale',
          (tester) async {
            final previousLanguage = appdata.settings['language'];
            appdata.settings['language'] = 'en-US';
            addTearDown(() => appdata.settings['language'] = previousLanguage);
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            var parents = 0;
            var pickers = 0;
            final screen = GlobalKey();
            await tester.pumpWidget(
              RepaintBoundary(
                key: screen,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: ThemeData(
                    colorScheme: ColorScheme.fromSeed(
                      seedColor: const Color(0xff6750a4),
                      brightness: brightness,
                    ),
                    fontFamily: captureRoot == null ? null : 'FavoritePathQA',
                  ),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(textScale),
                      disableAnimations: textScale > 1,
                      padding: const EdgeInsets.only(top: 24, bottom: 24),
                    ),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: Column(
                      children: [
                        Appbar(
                          leading: IconButton(
                            tooltip: 'Folders',
                            onPressed: () => pickers++,
                            icon: const Icon(Icons.menu),
                          ),
                          title: FavoriteFolderPath(
                            currentName: _current,
                            parentName: _parent,
                            onParentSelected: () => parents++,
                            onCurrentSelected: () => pickers++,
                          ),
                          actions: [
                            for (final icon in [
                              Icons.search,
                              Icons.sort,
                              Icons.more_vert,
                            ])
                              IconButton(
                                tooltip: icon == Icons.search
                                    ? 'Search'
                                    : icon == Icons.sort
                                    ? 'Sort'
                                    : 'More',
                                onPressed: () {},
                                icon: Icon(icon),
                              ),
                          ],
                        ),
                        const Expanded(
                          child: Center(
                            child: Text('Direct favorites in the child folder'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final parent = find.byKey(const ValueKey('favorite-path-parent'));
            final current = find.byKey(const ValueKey('favorite-path-current'));
            final semantics = tester.ensureSemantics();
            try {
              await tester.pump();
              expect(
                tester.getSemantics(parent).label,
                contains(_parent),
                reason: tester.getSemantics(parent).toStringDeep(),
              );
              expect(
                tester.getSemantics(current).label,
                contains(_current),
                reason: tester.getSemantics(current).toStringDeep(),
              );
            } finally {
              semantics.dispose();
            }
            for (final target in [parent, current]) {
              final bounds = tester.getRect(target);
              expect(bounds.width, greaterThanOrEqualTo(48));
              expect(bounds.height, greaterThanOrEqualTo(48));
              expect(bounds.top, greaterThanOrEqualTo(24));
            }
            await tester.tap(parent);
            await tester.pumpAndSettle();
            expect(parents, 1);
            expect(pickers, 0);
            await tester.tap(current);
            await tester.pumpAndSettle();
            expect(pickers, 1);
            expect(parents, 1);

            if (captureRoot != null) {
              await tester.runAsync(() async {
                final boundary =
                    screen.currentContext!.findRenderObject()
                        as RenderRepaintBoundary;
                final image = await boundary.toImage();
                try {
                  final bytes = await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  final directory = Directory(captureRoot)
                    ..createSync(recursive: true);
                  File(
                    '${directory.path}/favorite-path-${brightness.name}-${size.width.toInt()}-$textScale.png',
                  ).writeAsBytesSync(bytes!.buffer.asUint8List());
                } finally {
                  image.dispose();
                }
              });
            }
          },
        );
      }
    }
  }

  testWidgets('extremely narrow toolbar keeps the parent control usable', (
    tester,
  ) async {
    var parents = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 55,
              height: 52,
              child: FavoriteFolderPath(
                currentName: _current,
                parentName: _parent,
                onParentSelected: () => parents++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final parent = find.byKey(const ValueKey('favorite-path-parent'));
    expect(tester.getSize(parent), const Size(48, 48));
    expect(find.text(_current), findsOneWidget);
    await tester.tap(parent);
    await tester.pumpAndSettle();
    expect(parents, 1);
  });

  testWidgets(
    'desktop current folder is read-only and parent works by keyboard',
    (tester) async {
      var parents = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FavoriteFolderPath(
              currentName: _current,
              parentName: _parent,
              onParentSelected: () => parents++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('favorite-path-current')), findsNothing);
      expect(find.text(_current), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(parents, 1);
    },
  );
}
