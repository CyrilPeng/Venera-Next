import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/components/button.dart';

void main() {
  setUpAll(() async {
    final path = Platform.environment['WINDOW_OWNER_QA_FONT'];
    if (path == null) return;
    await (FontLoader(
      'MenuQA',
    )..addFont(File(path).readAsBytes().then(ByteData.sublistView))).load();
    await (FontLoader('MaterialIcons')..addFont(
          File(
            'build/windows/x64/runner/Release/data/flutter_assets/fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });

  for (final dispose in [false, true]) {
    testWidgets('menu action is revoked by pop observer; dispose=$dispose', (
      tester,
    ) async {
      final f = _Fixture();
      final observer = _PopObserver();
      await f.mount(tester, observer: observer);
      f.owner.currentState!.open();
      await tester.pumpAndSettle();
      observer.onPop = () {
        final menus = f.owner.currentState!.contextMenus;
        if (dispose) {
          menus.dispose();
        } else {
          menus.close();
        }
      };
      await tester.tap(find.text('Action 0'));
      await tester.pumpAndSettle();
      expect(f.calls, isEmpty);
      expect(f.navigator.currentState!.canPop(), isFalse);
      await f.dispose(tester);
    });
  }

  testWidgets('MenuButton replacement and removal retire its original menu', (
    tester,
  ) async {
    final entries = ValueNotifier([
      MenuEntry(text: 'Original button action', onClick: () {}),
    ]);
    final visible = ValueNotifier(true);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (_, show, _) => show
                ? ValueListenableBuilder<List<MenuEntry>>(
                    valueListenable: entries,
                    builder: (_, value, _) => MenuButton(entries: value),
                  )
                : const SizedBox(),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(MenuButton));
    await tester.pumpAndSettle();
    expect(find.text('Original button action'), findsOneWidget);
    entries.value = [
      MenuEntry(text: 'Replacement button action', onClick: () {}),
    ];
    await tester.pumpAndSettle();
    expect(find.text('Original button action'), findsNothing);
    await tester.tap(find.byType(MenuButton));
    await tester.pumpAndSettle();
    expect(find.text('Replacement button action'), findsOneWidget);
    visible.value = false;
    await tester.pumpAndSettle();
    expect(find.text('Replacement button action'), findsNothing);
    expect(navigator.currentState!.canPop(), isFalse);
    await tester.pumpWidget(const SizedBox());
    entries.dispose();
    visible.dispose();
  });

  testWidgets(
    'row region keeps the same target on rebuild and retires a replacement',
    (tester) async {
      final target = ValueNotifier(0);
      final calls = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: target,
              builder: (_, value, _) => ContextMenuRegion(
                identity: value ~/ 2,
                builder: (context, menus) => TextButton(
                  onPressed: () => ContextMenuRegion.of(context).show(
                    context,
                    const Offset(50, 50),
                    [
                      MenuEntry(
                        text: 'Row action',
                        onClick: () => calls.add(value),
                      ),
                    ],
                  ),
                  child: const Text('Row'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Row'));
      await tester.pumpAndSettle();
      target.value = 1;
      await tester.pumpAndSettle();
      expect(find.text('Row action'), findsOneWidget);
      target.value = 2;
      await tester.pumpAndSettle();
      expect(find.text('Row action'), findsNothing);
      expect(calls, isEmpty);
      await tester.pumpWidget(const SizedBox());
      target.dispose();
    },
  );

  for (final spec in [
    (const Size(375, 667), Brightness.light, 1.0),
    (const Size(667, 375), Brightness.dark, 3.2),
    (const Size(1024, 768), Brightness.light, 2.0),
  ]) {
    testWidgets(
      'context menu presentation and keyboard endpoints at ${spec.$1}',
      (tester) async {
        tester.view.physicalSize = spec.$1;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final semantics = tester.ensureSemantics();
        final highlight = FocusManager.instance.highlightStrategy;
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        addTearDown(() => FocusManager.instance.highlightStrategy = highlight);
        final boundaryKey = GlobalKey();
        late BuildContext anchor;
        final menus = MenuRouteController();
        final calls = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: spec.$2,
              fontFamily: Platform.environment['WINDOW_OWNER_QA_FONT'] == null
                  ? null
                  : 'MenuQA',
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: true,
                padding: const EdgeInsets.fromLTRB(12, 24, 12, 20),
                textScaler: TextScaler.linear(spec.$3),
              ),
              child: RepaintBoundary(key: boundaryKey, child: child!),
            ),
            home: Builder(
              builder: (context) {
                anchor = context;
                return const Scaffold(
                  body: Center(child: Text('Comic library')),
                );
              },
            ),
          ),
        );
        final handle = menus.show(
          anchor,
          Offset(spec.$1.width - 24, 40),
          List.generate(
            9,
            (i) => MenuEntry(
              text: 'Action $i with a descriptive label',
              icon: Icons.book_outlined,
              onClick: () => calls.add(i),
            ),
          ),
        )!;
        await tester.pump();
        await tester.pump();
        expect(handle.isCurrent, isTrue);
        final popup = ModalRoute.of(
          tester.element(find.text('Action 0 with a descriptive label')),
        )!;
        expect(popup.transitionDuration, Duration.zero);
        expect(popup.animation!.value, 1);
        expect(
          find.bySemanticsLabel('Action 0 with a descriptive label'),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.end);
        await tester.pump();
        final last = find.text('Action 8 with a descriptive label');
        expect(
          tester
              .getRect(last)
              .overlaps(tester.getRect(find.byType(Scrollable))),
          isTrue,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.home);
        await tester.pump();
        expect(
          tester
              .getRect(find.text('Action 0 with a descriptive label'))
              .overlaps(tester.getRect(find.byType(Scrollable))),
          isTrue,
        );
        final directory = Platform.environment['CONTEXT_MENU_QA_DIRECTORY'];
        if (directory != null) {
          final shadows = debugDisableShadows;
          debugDisableShadows = false;
          tester.element(find.byType(MaterialApp)).markNeedsBuild();
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final boundary =
                boundaryKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final picture = await boundary.toImage(pixelRatio: 1);
            final bytes = await picture.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(directory).create(recursive: true);
            await File(
              '$directory/menu-${spec.$1.width.toInt()}-${spec.$1.height.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            picture.dispose();
          });
          debugDisableShadows = shadows;
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.end);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(calls, [8]);
        expect(tester.takeException(), isNull);
        menus.dispose();
        semantics.dispose();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('owner removal retires its menu while the page route survives', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    f.owner.currentState!.open();
    await tester.pumpAndSettle();
    expect(find.text('Action 0'), findsOneWidget);
    f.visible.value = false;
    await tester.pumpAndSettle();
    expect(find.text('Action 0'), findsNothing);
    expect(f.navigator.currentState!.canPop(), isFalse);
    expect(f.calls, isEmpty);
    await f.dispose(tester);
  });

  testWidgets(
    'old callbacks and exact-route close preserve an unrelated cover',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      final handle = f.owner.currentState!.open()!;
      await tester.pumpAndSettle();
      final callback = tester
          .widget<InkWell>(
            find.ancestor(
              of: find.text('Action 0'),
              matching: find.byType(InkWell),
            ),
          )
          .onTap!;
      f.navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Cover')),
        ),
      );
      await tester.pumpAndSettle();
      callback();
      expect(f.calls, isEmpty);
      handle.close();
      await tester.pumpAndSettle();
      expect(find.text('Cover'), findsOneWidget);
      callback();
      expect(f.calls, isEmpty);
      f.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('Action 0'), findsNothing);
      expect(f.navigator.currentState!.canPop(), isFalse);
      await f.dispose(tester);
    },
  );

  testWidgets('target invalidation removes only its own menu', (tester) async {
    final f = _Fixture();
    await f.mount(tester);
    f.owner.currentState!.open();
    await tester.pumpAndSettle();
    f.valid.value = false;
    await tester.pumpAndSettle();
    expect(find.text('Action 0'), findsNothing);
    expect(f.calls, isEmpty);
    await f.dispose(tester);
  });

  testWidgets('replacement ignores an old handle and old menu callbacks', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    final old = f.owner.currentState!.open()!;
    await tester.pumpAndSettle();
    final callback = tester
        .widget<InkWell>(
          find.ancestor(
            of: find.text('Action 0'),
            matching: find.byType(InkWell),
          ),
        )
        .onTap!;
    f.owner.currentState!.open();
    await tester.pumpAndSettle();
    old.close();
    callback();
    await tester.pump();
    expect(find.text('Action 0'), findsOneWidget);
    expect(f.calls, isEmpty);
    await tester.tap(find.text('Action 1'));
    await tester.pumpAndSettle();
    expect(f.calls, [1]);
    await f.dispose(tester);
  });

  testWidgets('closing a pending menu prevents any push', (tester) async {
    final f = _Fixture();
    await f.mount(tester);
    final handle = f.owner.currentState!.open()!;
    handle.close();
    await tester.pumpAndSettle();
    expect(f.navigator.currentState!.canPop(), isFalse);
    f.owner.currentState!.contextMenus.dispose();
    expect(f.owner.currentState!.open(), isNull);
    await f.dispose(tester);
  });

  testWidgets('menu captures entries before delayed route insertion', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    final entries = [
      MenuEntry(text: 'Original', onClick: () => f.calls.add(4)),
    ];
    f.owner.currentState!.contextMenus.show(
      f.owner.currentContext!,
      const Offset(100, 100),
      entries,
    );
    entries[0] = MenuEntry(text: 'Replacement', onClick: () => f.calls.add(5));
    await tester.pumpAndSettle();
    expect(find.text('Replacement'), findsNothing);
    await tester.tap(find.text('Original'));
    await tester.pumpAndSettle();
    expect(f.calls, [4]);
    await f.dispose(tester);
  });

  testWidgets('keyboard arrows select once and Escape restores the owner', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    f.owner.currentState!.open();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(f.calls, [1]);
    f.owner.currentState!.open();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Action 0'), findsNothing);
    expect(f.navigator.currentState!.canPop(), isFalse);
    expect(f.calls, [1]);
    await f.dispose(tester);
  });

  testWidgets('a throwing action still closes and permits the next menu', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    final error = StateError('action failed');
    f.owner.currentState!.contextMenus.show(
      f.owner.currentContext!,
      const Offset(100, 100),
      [MenuEntry(text: 'Fail', onClick: () => throw error)],
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fail'));
    expect(tester.takeException(), same(error));
    await tester.pumpAndSettle();
    f.owner.currentState!.open();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Action 0'));
    await tester.pumpAndSettle();
    expect(f.calls, [0]);
    await f.dispose(tester);
  });

  testWidgets(
    'nested navigation uses the root menu and retains both owner routes',
    (tester) async {
      final f = _Fixture();
      final inner = GlobalKey<NavigatorState>();
      await f.mount(tester, inner: inner);
      await tester.pumpAndSettle();
      expect(f.owner.currentState!.open(), isNotNull);
      await tester.pumpAndSettle();
      expect(f.navigator.currentState!.canPop(), isTrue);
      expect(inner.currentState!.canPop(), isFalse);
      await tester.tap(find.text('Action 0'));
      await tester.pumpAndSettle();
      expect(f.calls, [0]);
      expect(f.navigator.currentState!.canPop(), isFalse);
      expect(inner.currentState!.canPop(), isFalse);
      await f.dispose(tester);
    },
  );

  testWidgets('empty menu does not add a route', (tester) async {
    final menus = MenuRouteController();
    late BuildContext anchor;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            anchor = context;
            return const Scaffold(body: Text('Owner'));
          },
        ),
      ),
    );
    menus.show(anchor, const Offset(100, 100), []);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(Navigator.of(anchor).canPop(), isFalse);
    menus.dispose();
  });
  for (final size in [const Size(210, 320), const Size(667, 375)]) {
    testWidgets(
      'menu fits safe viewport and scrolls scaled long text at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        late BuildContext anchor;
        final calls = <int>[];
        final menus = MenuRouteController();
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(3.2),
                padding: const EdgeInsets.fromLTRB(12, 24, 12, 20),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: Builder(
              builder: (context) {
                anchor = context;
                return const Scaffold(body: Text('Owner'));
              },
            ),
          ),
        );
        menus.show(
          anchor,
          Offset(size.width, size.height),
          List.generate(
            12,
            (i) => MenuEntry(
              icon: Icons.book,
              text: 'Action $i with a long translated label',
              onClick: () => calls.add(i),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final scrollable = find.byType(Scrollable);
        expect(scrollable, findsOneWidget);
        final bounds = tester.getRect(scrollable);
        expect(bounds.left, greaterThanOrEqualTo(12));
        expect(bounds.top, greaterThanOrEqualTo(24));
        expect(bounds.right, lessThanOrEqualTo(size.width - 12));
        expect(bounds.bottom, lessThanOrEqualTo(size.height - 20));
        await tester.scrollUntilVisible(
          find.text('Action 11 with a long translated label'),
          300,
          scrollable: scrollable,
        );
        final visibleText = tester
            .getRect(find.text('Action 11 with a long translated label'))
            .intersect(bounds);
        expect(visibleText.isEmpty, isFalse);
        await tester.tapAt(visibleText.center);
        await tester.pumpAndSettle();
        expect(calls, [11]);
        menus.dispose();
      },
    );
  }
}

class _Fixture {
  final navigator = GlobalKey<NavigatorState>();
  final owner = GlobalKey<_OwnerState>();
  final visible = ValueNotifier(true), valid = ValueNotifier(true);
  final calls = <int>[];
  Future<void> mount(
    WidgetTester tester, {
    GlobalKey<NavigatorState>? inner,
    NavigatorObserver? observer,
  }) => tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [?observer],
      home: inner == null
          ? _content()
          : Navigator(
              key: inner,
              onGenerateRoute: (_) =>
                  MaterialPageRoute<void>(builder: (_) => _content()),
            ),
    ),
  );
  Widget _content() => ValueListenableBuilder<bool>(
    valueListenable: visible,
    builder: (_, show, _) => show
        ? _Owner(key: owner, fixture: this)
        : const Scaffold(body: Text('Removed')),
  );
  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    visible.dispose();
    valid.dispose();
  }
}

class _PopObserver extends NavigatorObserver {
  VoidCallback? onPop;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onPop?.call();
}

class _Owner extends StatefulWidget {
  const _Owner({required this.fixture, super.key});
  final _Fixture fixture;
  @override
  State<_Owner> createState() => _OwnerState();
}

class _OwnerState extends State<_Owner> with ContextMenuOwner {
  @override
  Object get contextMenuIdentity => widget.fixture;
  ContextMenuHandle? open() => contextMenus.show(
    context,
    const Offset(100, 100),
    List.generate(
      3,
      (i) => MenuEntry(
        text: 'Action $i',
        onClick: () => widget.fixture.calls.add(i),
      ),
    ),
    isValid: () => widget.fixture.valid.value,
    changes: widget.fixture.valid,
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(onPressed: open, child: const Text('Open')),
    ),
  );
}
