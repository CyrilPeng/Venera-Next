import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/reader/chapter_menu.dart';
import 'package:venera_next/features/reader/chapters.dart';
import 'package:venera_next/features/reader/sidebar_binding.dart';

Widget _page(
  ReaderChapterMenuData data, {
  ValueChanged<int>? select,
  VoidCallback? close,
}) => MaterialApp(
  home: ReaderChaptersView(
    data: data,
    onSelect: select ?? (_) {},
    onClose: close ?? () {},
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = Platform.environment['CHAPTER_MENU_QA_FONT'];
    if (font == null) return;
    await (FontLoader(
      'ChapterMenuQA',
    )..addFont(File(font).readAsBytes().then(ByteData.sublistView))).load();
    await (FontLoader('MaterialIcons')..addFont(
          File(
            'build/windows/x64/runner/Release/data/flutter_assets/fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });

  test(
    'snapshot preserves group order, repeated IDs and download metadata',
    () {
      final source = ComicChapters.grouped({
        'empty': {},
        'one': {'same': 'First', 'b': 'Second'},
        'gap': {},
        'two': {'same': 'Third'},
      });
      final menu = ReaderChapterMenuData(
        source,
        currentChapter: 3,
        downloaded: ['same'],
      );
      expect(menu.length, 3);
      expect(menu.initialGroup, 3);
      final entries = menu.groups.expand((g) => g.entries).toList();
      expect(entries.map((e) => e.index), [1, 2, 3]);
      expect(entries.map((e) => e.id), ['same', 'b', 'same']);
      expect(entries.map((e) => e.downloaded), [true, false, true]);
      expect(menu.matches(source), isTrue);
    },
  );

  test(
    'snapshot deep copies input and rejects in-place mutations and regrouping',
    () {
      final chapters = {'a': 'First', 'b': 'Second'};
      final groups = {'one': chapters};
      final downloads = ['a'];
      final source = ComicChapters.grouped(groups);
      final menu = ReaderChapterMenuData(
        source,
        currentChapter: 1,
        downloaded: downloads,
      );
      downloads.clear();
      expect(menu.groups.first.entries.first.downloaded, isTrue);
      expect(() => menu.groups.clear(), throwsUnsupportedError);
      expect(() => menu.groups.first.entries.clear(), throwsUnsupportedError);
      chapters['a'] = 'Edited';
      expect(menu.groups.first.entries.first.title, 'First');
      expect(menu.matches(source), isFalse);
      chapters['a'] = 'First';
      expect(menu.matches(source), isTrue);
      chapters.remove('a');
      chapters['a'] = 'First';
      expect(menu.matches(source), isFalse);
      expect(
        menu.matches(const ComicChapters({'a': 'First', 'b': 'Second'})),
        isFalse,
      );
      groups['empty'] = {};
      expect(menu.groups, hasLength(1));
    },
  );

  test(
    'invalid current position falls back safely and empty grouped length is zero',
    () {
      for (final source in [
        const ComicChapters({}),
        const ComicChapters.grouped({}),
        const ComicChapters.grouped({'empty': {}}),
      ]) {
        expect(source.length, 0);
        final menu = ReaderChapterMenuData(source, currentChapter: 99);
        expect(menu.length, 0);
        expect(menu.initialGroup, 0);
        expect(menu.matches(source), isTrue);
      }
      final menu = ReaderChapterMenuData(
        const ComicChapters.grouped({
          'empty': {},
          'available': {'a': 'First'},
        }),
        currentChapter: -1,
      );
      expect(menu.initialGroup, 1);
    },
  );

  test('request rejects invalid and retired selections before navigation', () {
    final selections = <int>[];
    var current = true;
    final request = ReaderChapterMenuRequest(
      data: ReaderChapterMenuData(
        const ComicChapters({'a': 'First'}),
        currentChapter: 1,
      ),
      isCurrent: () => current,
      select: (index) {
        selections.add(index);
        return true;
      },
    );
    expect(request.select(0), isFalse);
    expect(request.select(2), isFalse);
    expect(request.select(1), isTrue);
    current = false;
    expect(request.select(1), isFalse);
    expect(selections, [1]);
  });

  testWidgets('ascending and descending selections retain original indices', (
    tester,
  ) async {
    final selections = <int>[];
    final data = ReaderChapterMenuData(
      const ComicChapters({'one': 'First', 'two': 'Second', 'three': 'Third'}),
      currentChapter: 2,
    );
    await tester.pumpWidget(_page(data, select: selections.add));
    await tester.pumpAndSettle();
    final position = tester
        .widget<Scrollbar>(find.byType(Scrollbar))
        .controller!
        .position;
    expect(position.maxScrollExtent, position.minScrollExtent);
    await tester.tap(find.text('Third'));
    await tester.tap(find.text('Ascending'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Third')).dy,
      lessThan(tester.getTopLeft(find.text('First')).dy),
    );
    await tester.tap(find.text('First'));
    expect(selections, [3, 1]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('group tabs handle empty groups and repeated chapter IDs', (
    tester,
  ) async {
    final selections = <int>[];
    final data = ReaderChapterMenuData(
      const ComicChapters.grouped({
        'empty': {},
        'one': {'same': 'First'},
        'two': {'same': 'Second'},
      }),
      currentChapter: 2,
    );
    await tester.pumpWidget(_page(data, select: selections.add));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second'));
    await tester.tap(find.text('empty'));
    await tester.pumpAndSettle();
    expect(find.text('No data'), findsOneWidget);
    await tester.tap(find.text('one'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('First'));
    expect(selections, [2, 1]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty and out-of-range menus remain operable', (tester) async {
    var closed = 0;
    for (final chapters in [
      const ComicChapters({}),
      const ComicChapters.grouped({}),
      const ComicChapters.grouped({'empty': {}}),
    ]) {
      await tester.pumpWidget(
        _page(
          ReaderChapterMenuData(chapters, currentChapter: 99),
          close: () => closed++,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No data'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      expect(tester.takeException(), isNull);
    }
    expect(closed, 3);
  });

  testWidgets(
    'large variable-height list anchors current chapter and stays lazy',
    (tester) async {
      final data = ReaderChapterMenuData(
        ComicChapters({
          for (var i = 1; i <= 1000; i++)
            '$i': 'Chapter $i${i.isEven ? ' with a long subtitle ' * 4 : ''}',
        }),
        currentChapter: 901,
      );
      await tester.pumpWidget(_page(data));
      await tester.pumpAndSettle();
      expect(find.text('Chapter 901').hitTestable(), findsOneWidget);
      expect(find.byType(InkWell).evaluate().length, lessThan(80));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Chapter 899').hitTestable(), findsOneWidget);
    },
  );

  testWidgets(
    'end positioning exposes preceding chapters without blank viewport',
    (tester) async {
      final data = ReaderChapterMenuData(
        ComicChapters({for (var i = 1; i <= 100; i++) '$i': 'Chapter $i'}),
        currentChapter: 100,
      );
      await tester.pumpWidget(_page(data));
      await tester.pumpAndSettle();
      expect(find.text('Chapter 99').hitTestable(), findsOneWidget);
      expect(find.text('Chapter 100').hitTestable(), findsOneWidget);
      expect(
        tester.getBottomRight(find.text('Chapter 100')).dy,
        greaterThan(500),
      );
    },
  );

  testWidgets('replacement and removal dispose list and tab controllers', (
    tester,
  ) async {
    final data = ReaderChapterMenuData(
      const ComicChapters.grouped({
        'one': {'a': 'First'},
        'two': {'b': 'Second'},
      }),
      currentChapter: 1,
    );
    await tester.pumpWidget(_page(data));
    await tester.pumpAndSettle();
    final scroll = tester.widget<Scrollbar>(find.byType(Scrollbar)).controller!;
    final tab = DefaultTabController.of(tester.element(find.byType(TabBar)));
    tab.animateTo(1);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pumpWidget(
      _page(
        ReaderChapterMenuData(
          const ComicChapters({'new': 'New chapter'}),
          currentChapter: 1,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(() => scroll.addListener(() {}), throwsFlutterError);
    expect(() => tab.addListener(() {}), throwsFlutterError);
    final next = tester.widget<Scrollbar>(find.byType(Scrollbar)).controller!;
    await tester.pumpWidget(const SizedBox());
    expect(() => next.addListener(() {}), throwsFlutterError);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'keyboard activation and selected/download semantics survive sorting',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final selections = <int>[];
      await tester.pumpWidget(
        _page(
          ReaderChapterMenuData(
            const ComicChapters({'a': 'First', 'b': 'Second'}),
            currentChapter: 1,
            downloaded: ['a'],
          ),
          select: selections.add,
        ),
      );
      await tester.pumpAndSettle();
      final node = tester.getSemantics(find.text('First'));
      expect(node.flagsCollection.isSelected, ui.Tristate.isTrue);
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.label, contains('Chapter downloaded'));
      Focus.of(tester.element(find.text('First'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(selections, [1]);
      await tester.tap(find.text('Ascending'));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.text('First')).flagsCollection.isSelected,
        ui.Tristate.isTrue,
      );
      semantics.dispose();
    },
  );

  for (final scenario in [
    (size: const Size(375, 667), dark: false, scale: 1.0, grouped: false),
    (size: const Size(375, 667), dark: true, scale: 3.0, grouped: true),
    (size: const Size(667, 375), dark: false, scale: 3.0, grouped: false),
    (size: const Size(667, 375), dark: true, scale: 2.0, grouped: true),
    (size: const Size(1024, 768), dark: false, scale: 2.0, grouped: true),
    (size: const Size(1024, 768), dark: true, scale: 3.0, grouped: false),
  ]) {
    testWidgets('chapter drawer layout $scenario', (tester) async {
      await tester.binding.setSurfaceSize(scenario.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final title =
          'Chapter 2 — A very long chapter title that must wrap without hiding the download status';
      final chapters = {'one': 'Chapter 1', 'two': title, 'three': 'Chapter 3'};
      final data = ReaderChapterMenuData(
        scenario.grouped
            ? ComicChapters.grouped({
                'Volume one': chapters,
                'Volume two': {'x': 'Extra chapter'},
              })
            : ComicChapters(chapters),
        currentChapter: 2,
        downloaded: ['two'],
      );
      final repaint = GlobalKey();
      late BuildContext parent;
      final sidebar = ReaderSidebarBinding(
        canOpen: () => true,
        acquireInteraction: () => () {},
        onError: (error, stack) => Error.throwWithStackTrace(error, stack),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: scenario.dark ? Brightness.dark : Brightness.light,
            fontFamily: Platform.environment['CHAPTER_MENU_QA_FONT'] == null
                ? null
                : 'ChapterMenuQA',
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: scenario.size,
              textScaler: TextScaler.linear(scenario.scale),
              disableAnimations: scenario.scale > 1,
              padding: const EdgeInsets.only(top: 24, bottom: 20),
            ),
            child: RepaintBoundary(key: repaint, child: child!),
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                parent = context;
                return const Center(child: Text('Reading a comic'));
              },
            ),
          ),
        ),
      );
      ReaderSidebarHandle? handle;
      handle = sidebar.show(
        parent,
        ReaderChaptersView(
          data: data,
          onSelect: (_) {},
          onClose: () => handle?.close(),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final paragraph = tester.renderObject<RenderParagraph>(find.text(title));
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(paragraph.size.width, lessThanOrEqualTo(352));
      final colors = Theme.of(tester.element(find.text(title))).colorScheme;
      double contrast(Color foreground) {
        final a = foreground.computeLuminance();
        final b = colors.surface.computeLuminance();
        return a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
      }

      expect(contrast(colors.onSurface), greaterThanOrEqualTo(4.5));
      expect(contrast(colors.primary), greaterThanOrEqualTo(4.5));
      expect(contrast(colors.secondary), greaterThanOrEqualTo(3));
      expect(
        tester.getSize(find.byTooltip('Back')).height,
        greaterThanOrEqualTo(48),
      );
      final route = ModalRoute.of(tester.element(find.text('Chapters')))!;
      expect(
        route.transitionDuration,
        scenario.scale > 1 ? Duration.zero : const Duration(milliseconds: 300),
      );
      final output = Platform.environment['CHAPTER_MENU_QA_DIR'];
      if (output != null) {
        await tester.runAsync(() async {
          final boundary =
              repaint.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final name =
                '${scenario.size.width.toInt()}-${scenario.dark ? 'dark' : 'light'}-${scenario.scale.toInt()}x';
            final file = File('$output/$name.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -1200),
      );
      await tester.pumpAndSettle();
      expect(find.text('Chapter 3').hitTestable(), findsOneWidget);
      sidebar.dispose();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });
  }
}
