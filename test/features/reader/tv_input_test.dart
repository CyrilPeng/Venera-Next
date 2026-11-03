import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/tv_navigation.dart';
import 'package:venera_next/features/reader/exit_guard.dart';
import 'package:venera_next/features/reader/tv_input.dart';

class _Harness extends StatefulWidget {
  const _Harness({super.key});
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool menuOpen = false;
  final keys = <KeyEvent>[];
  int cancelled = 0;
  int exits = 0;
  int actions = 0;

  @override
  Widget build(BuildContext context) => TvReaderInput(
    menuOpen: menuOpen,
    onToggleMenu: () => setState(() => menuOpen = !menuOpen),
    onReadKey: keys.add,
    onCancelReadKeys: () => cancelled++,
    onExit: () async => exits++,
    child: Column(
      children: [
        const Expanded(child: Center(child: Text('reading'))),
        if (menuOpen)
          Row(
            children: [
              TextButton(
                onPressed: () => actions++,
                child: const Text('first action'),
              ),
              TextButton(
                onPressed: () => actions++,
                child: const Text('second action'),
              ),
            ],
          ),
      ],
    ),
  );
}

void main() {
  testWidgets(
    'reader handles page keys but menus only handle focus and actions',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => TvNavigation(enabled: true, child: child!),
          home: Scaffold(body: _Harness(key: key)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(key.currentState!.keys, hasLength(2));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(key.currentState!.menuOpen, isTrue);
      expect(key.currentState!.cancelled, greaterThan(0));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(key.currentState!.keys, hasLength(2));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      expect(key.currentState!.actions, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(key.currentState!.menuOpen, isFalse);
      expect(key.currentState!.exits, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(key.currentState!.keys, hasLength(4));
      await tester.sendKeyEvent(
        LogicalKeyboardKey.goBack,
        physicalKey: PhysicalKeyboardKey.escape,
      );
      expect(key.currentState!.exits, 1);
    },
  );

  testWidgets('backgrounding cancels input and ignores remote repeats', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => TvNavigation(enabled: true, child: child!),
        home: Scaffold(body: _Harness(key: key)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final cancelled = key.currentState!.cancelled;
    expect(cancelled, greaterThan(0));
    final count = key.currentState!.keys.length;
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    expect(key.currentState!.keys, hasLength(count));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('system back closes the menu before starting guarded save', (
    tester,
  ) async {
    var menu = true;
    var saves = 0;
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const SizedBox()),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderExitGuard(
          onBackRequested: () {
            if (!menu) return false;
            menu = false;
            return true;
          },
          prepare: () async {
            saves++;
            return () {};
          },
          holdForLeave: () => () {},
          onError: (_, _) {},
          child: const Text('reader'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await navigator.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(menu, isFalse);
    expect(saves, 0);
    expect(find.text('reader'), findsOneWidget);
    await navigator.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(find.text('reader'), findsNothing);
  });
}
