import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/async_confirm_dialog.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:window_manager/window_manager.dart';

import 'sidebar_presentation_test.dart'
    show pumpSidebar, settleSidebarWork, sidebarCauses;

class _Navigator extends Navigator {
  const _Navigator({super.key, super.onGenerateRoute});
  @override
  NavigatorState createState() => _NavigatorState();
}

class _NavigatorState extends NavigatorState {
  bool failPop = false;
  bool failRemove = false;
  final failure = StateError('original confirm route close');
  final stack = StackTrace.fromString('original confirm route close stack');
  @override
  void pop<T extends Object?>([T? result]) {
    if (failPop) Error.throwWithStackTrace(failure, stack);
    super.pop(result);
  }

  @override
  void removeRoute<T extends Object?>(Route<T> route, [T? result]) {
    if (failRemove) Error.throwWithStackTrace(failure, stack);
    super.removeRoute(route, result);
  }
}

class _Host {
  final key = GlobalKey<_NavigatorState>();
  final original = SelectionTaskRegistry();
  final content = ValueNotifier<bool>(true);
  late SelectionTaskRegistry registry = original;
  late BuildContext context;
  bool allowed = true;
  bool window = false;
  bool multipleWindows = false;
  bool useSecondWindow = false;
  final firstWindow = GlobalKey();
  final secondWindow = GlobalKey();
  int secondExits = 0;
  double textScale = 1;
  int exits = 0;
  bool ended = false;
  Object? presentationError;
  StackTrace? presentationStack;
  _NavigatorState get navigator => key.currentState!;

  Widget app() => MaterialApp(
    builder: (context, _) {
      Widget child = _Navigator(
        key: key,
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: content,
              builder: (_, visible, _) => visible
                  ? Builder(
                      builder: (value) {
                        this.context = value;
                        return const Text('Original caller');
                      },
                    )
                  : const Text('Replacement caller'),
            ),
          ),
        ),
      );
      if (multipleWindows) {
        child = Row(
          children: [
            Expanded(
              child: WindowFrame(
                useSecondWindow ? const SizedBox() : child,
                key: firstWindow,
                onExit: () => exits++,
              ),
            ),
            Expanded(
              child: WindowFrame(
                useSecondWindow ? child : const SizedBox(),
                key: secondWindow,
                onExit: () => secondExits++,
              ),
            ),
          ],
        );
      } else if (window) {
        child = WindowFrame(child, onExit: () => exits++);
      }
      return MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: SelectionTasksScope(
          registry: registry,
          child: NavigationAdmission(
            allowsNavigation: () => allowed,
            child: child,
          ),
        ),
      );
    },
  );

  Future<void> mount(WidgetTester tester) async {
    addTearDown(() async {
      key.currentState?.failRemove = false;
      key.currentState?.failPop = false;
      await tester.pumpWidget(const SizedBox());
      await pumpSidebar(tester);
      for (final tasks in {original, registry}) {
        await settleSidebarWork(tester, tasks.closeAndWait);
      }
      content.dispose();
    });
    await tester.pumpWidget(app());
  }

  Future<void> show(Future<void> Function() action) {
    return showAsyncConfirmDialog(
      context: context,
      title: 'Original confirmation',
      content: 'Delete original records?',
      onConfirm: action,
    ).then<void>(
      (_) => ended = true,
      onError: (Object error, StackTrace stack) {
        presentationError = error;
        presentationStack = stack;
        ended = true;
      },
    );
  }

  Future<void> open(WidgetTester tester, Future<void> Function() action) async {
    unawaited(show(action));
    await pumpSidebar(tester);
  }

  Route<void> cover() {
    final route = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('Newer page')),
    );
    navigator.push(route);
    return route;
  }

  void closeWindow(WidgetTester tester) =>
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
}

VoidCallback _confirm(WidgetTester tester) => tester
    .widget<Button>(
      find.descendant(
        of: find.byType(ContentDialog),
        matching: find.byType(Button),
      ),
    )
    .onPressed;

VoidCallback _cancel(WidgetTester tester) => tester
    .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
    .onPressed!;

Future<void> _invoke(VoidCallback callback) =>
    Future<void>.sync(() => Function.apply(callback, const []));

void main() {
  setUp(() {
    final language = appdata.settings['language'];
    final muted = Log.isMuted;
    appdata.settings['language'] = 'en-US';
    Log.isMuted = true;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (_) async => false,
    );
    addTearDown(() {
      appdata.settings['language'] = language;
      Log.isMuted = muted;
      messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      );
    });
  });

  for (final state in PersistenceCommitState.values) {
    testWidgets('confirmation permits only known uncommitted replay: $state', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      var calls = 0;
      await host.open(tester, () async {
        if (++calls == 1) {
          throw PersistenceFailure(
            commitState: state,
            cause: StateError('original persistence failure'),
            stackTrace: StackTrace.current,
          );
        }
      });
      await _invoke(_confirm(tester));
      await pumpSidebar(tester);
      expect(
        find.textContaining('original persistence failure'),
        findsOneWidget,
      );
      await _invoke(_confirm(tester));
      await pumpSidebar(tester);
      expect(calls, state == PersistenceCommitState.notCommitted ? 2 : 1);
      expect(host.ended, isTrue);
    });
  }

  testWidgets('successful work survives a failed pop without replay', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    var calls = 0;
    await host.open(tester, () async => calls++);
    host.navigator.failPop = true;
    await _invoke(_confirm(tester));
    await pumpSidebar(tester);
    expect(find.text('OK'), findsOneWidget);
    expect(find.textContaining('original confirm route close'), findsOneWidget);
    host.navigator.failPop = false;
    await _invoke(_confirm(tester));
    await pumpSidebar(tester);
    expect(calls, 1);
    expect(host.ended, isTrue);
  });

  for (final state in ['covered', 'frozen', 'removed', 'replaced']) {
    testWidgets('retained confirm rejects retired caller: $state', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      var calls = 0;
      await host.open(tester, () async => calls++);
      final press = _confirm(tester);
      if (state == 'covered') {
        host.cover();
      } else if (state == 'frozen') {
        host.allowed = false;
      } else if (state == 'removed') {
        host.content.value = false;
      } else {
        host.registry = SelectionTaskRegistry();
        await tester.pumpWidget(host.app());
      }
      await pumpSidebar(tester);
      await _invoke(press);
      await pumpSidebar(tester);
      expect(calls, 0);
      expect(tester.takeException(), isNull);
    });
  }

  for (final state in ['covered', 'frozen', 'replaced']) {
    testWidgets('retained cancel respects original route and host: $state', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      await host.open(tester, () async {});
      final press = _cancel(tester);
      Route<void>? newer;
      if (state == 'covered') {
        newer = host.cover();
      } else if (state == 'frozen') {
        host.allowed = false;
      } else {
        host.registry = SelectionTaskRegistry();
        await tester.pumpWidget(host.app());
      }
      await pumpSidebar(tester);
      press();
      await pumpSidebar(tester);
      expect(host.ended, isFalse);
      if (newer != null) expect(newer.isCurrent, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  for (final state in ['covered', 'frozen', 'closed', 'removed']) {
    testWidgets('inactive caller cannot present confirmation: $state', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      if (state == 'covered') {
        host.cover();
      } else if (state == 'frozen') {
        host.allowed = false;
      } else if (state == 'closed') {
        await settleSidebarWork(tester, host.original.closeAndWait);
      } else {
        host.content.value = false;
      }
      await pumpSidebar(tester);
      unawaited(host.show(() async {}));
      await pumpSidebar(tester);
      expect(find.byType(ContentDialog), findsNothing);
      expect(host.presentationError, isNull);
      expect(host.ended, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  for (final built in [false, true]) {
    testWidgets(
      'confirmation waiter ends with Navigator disposal: built=$built',
      (tester) async {
        final host = _Host();
        await host.mount(tester);
        unawaited(host.show(() async {}));
        if (built) {
          await pumpSidebar(tester);
        } else {
          await tester.idle();
        }
        await tester.pumpWidget(const SizedBox());
        await pumpSidebar(tester);
        expect(host.ended, isTrue);
        expect(host.presentationError, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'application close removes only its confirmation under another route',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      await host.open(tester, () async {});
      final newer = host.cover();
      await pumpSidebar(tester);
      await settleSidebarWork(tester, host.original.closeAndWait);
      await pumpSidebar(tester);
      expect(host.ended, isTrue);
      expect(newer.isCurrent, isTrue);
      expect(find.byType(ContentDialog, skipOffstage: false), findsNothing);
    },
  );

  for (final window in [false, true]) {
    for (final fails in [false, true]) {
      testWidgets(
        'original host joins accepted confirmation: window=$window failure=$fails',
        (tester) async {
          final host = _Host()..window = window;
          await host.mount(tester);
          final pending = Completer<void>();
          final failure = StateError('original confirmation write');
          final stack = StackTrace.fromString(
            'original confirmation write stack',
          );
          await host.open(tester, () => pending.future);
          final pressed = _invoke(_confirm(tester));
          await pumpSidebar(tester);
          var closed = false;
          Object? closeError;
          Future<void>? closing;
          if (window) {
            host.closeWindow(tester);
          } else {
            closing = host.original.closeAndWait().then<void>(
              (_) => closed = true,
              onError: (Object error) => closeError = error,
            );
          }
          try {
            await pumpSidebar(tester);
            expect(window ? host.exits != 0 : closed, isFalse);
          } finally {
            if (fails) {
              pending.completeError(failure, stack);
            } else {
              pending.complete();
            }
            await settleSidebarWork(tester, () => pressed);
            if (closing != null) {
              await settleSidebarWork(tester, () => closing!);
            }
            await pumpSidebar(tester);
          }
          if (window) {
            expect(host.exits, fails ? 0 : 1);
            if (fails) {
              final report = tester.takeException();
              expect(report, same(failure));
              expect(sidebarCauses(report!), contains(same(failure)));
            }
          } else if (fails) {
            expect(closeError, isA<SelectionCleanupFailure>());
            expect(sidebarCauses(closeError!), contains(same(failure)));
          } else {
            expect(closed, isTrue);
          }
          expect(host.ended, isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'accepted confirmation remains with original registry after replacement',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      final pending = Completer<void>();
      await host.open(tester, () => pending.future);
      final pressed = _invoke(_confirm(tester));
      await pumpSidebar(tester);
      host.registry = SelectionTaskRegistry();
      await tester.pumpWidget(host.app());
      var oldClosed = false;
      var newClosed = false;
      final closing = host.original.closeAndWait().then<void>(
        (_) => oldClosed = true,
      );
      final replacement = host.registry.closeAndWait().then<void>(
        (_) => newClosed = true,
      );
      try {
        await pumpSidebar(tester);
        expect(oldClosed, isFalse);
        expect(newClosed, isTrue);
      } finally {
        pending.complete();
        await settleSidebarWork(
          tester,
          () => Future.wait([pressed, closing, replacement]),
        );
      }
      expect(host.ended, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'confirmation registers before synchronous shutdown and duplicate reentry',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      final pending = Completer<void>();
      var calls = 0;
      var closed = false;
      Future<void>? closing;
      late VoidCallback press;
      await host.open(tester, () {
        calls++;
        if (calls == 1) {
          press();
          closing = host.original.closeAndWait().then<void>(
            (_) => closed = true,
          );
        }
        return pending.future;
      });
      press = _confirm(tester);
      final pressed = _invoke(press);
      try {
        await pumpSidebar(tester);
        expect(calls, 1);
        expect(closed, isFalse);
      } finally {
        pending.complete();
        await settleSidebarWork(tester, () async {
          await pressed;
          await closing;
        });
      }
      expect(closed, isTrue);
    },
  );

  testWidgets(
    'covered failure is visible on return and unknown write cannot replay',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      final pending = Completer<void>();
      var calls = 0;
      await host.open(tester, () {
        calls++;
        return pending.future;
      });
      final pressed = _invoke(_confirm(tester));
      await pumpSidebar(tester);
      final newer = host.cover();
      await pumpSidebar(tester);
      pending.completeError(
        PersistenceFailure(
          commitState: PersistenceCommitState.unknown,
          cause: StateError('covered write result'),
          stackTrace: StackTrace.current,
        ),
      );
      await settleSidebarWork(tester, () => pressed);
      expect(newer.isCurrent, isTrue);
      host.navigator.pop();
      await pumpSidebar(tester);
      expect(find.textContaining('covered write result'), findsOneWidget);
      await _invoke(_confirm(tester));
      await pumpSidebar(tester);
      expect(calls, 1);
      expect(host.ended, isTrue);
    },
  );

  testWidgets(
    'busy confirmation keeps an accessible name and blocks cancellation',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      final semantics = tester.ensureSemantics();
      final pending = Completer<void>();
      await host.open(tester, () => pending.future);
      final cancel = _cancel(tester);
      final pressed = _invoke(_confirm(tester));
      try {
        await tester.pump();
        cancel();
        await tester.pump();
        expect(host.ended, isFalse);
        expect(find.bySemanticsLabel('Confirm'), findsOneWidget);
      } finally {
        pending.complete();
        await settleSidebarWork(tester, () => pressed);
        semantics.dispose();
      }
    },
  );

  testWidgets('removed caller can still dismiss its visible confirmation', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    await host.open(tester, () async {});
    host.content.value = false;
    await pumpSidebar(tester);
    _cancel(tester)();
    await pumpSidebar(tester);
    expect(host.ended, isTrue);
    expect(find.text('Replacement caller'), findsOneWidget);
  });

  testWidgets(
    'failed route cleanup ends waiter and preserves original failure for retry',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      await host.open(tester, () async {});
      host.navigator.failRemove = true;
      Object? failure;
      await settleSidebarWork(
        tester,
        () => host.original.closeAndWait().catchError((Object error) {
          failure = error;
        }),
      );
      expect(failure, isA<SelectionCleanupFailure>());
      expect(host.presentationError, isA<SelectionCleanupFailure>());
      expect(sidebarCauses(failure!), contains(same(host.navigator.failure)));
      expect(host.ended, isTrue);
      expect(find.text('Original confirmation'), findsOneWidget);
      host.navigator.failRemove = false;
      await settleSidebarWork(tester, host.original.closeAndWait);
      await pumpSidebar(tester);
      expect(find.text('Original confirmation'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final fails in [false, true]) {
    testWidgets(
      'moving a confirmation does not transfer its window task: failure=$fails',
      (tester) async {
        final host = _Host()..multipleWindows = true;
        await host.mount(tester);
        final pending = Completer<void>();
        final failure = StateError('original window confirmation');
        await host.open(tester, () => pending.future);
        final pressed = _invoke(_confirm(tester));
        await pumpSidebar(tester);
        host.useSecondWindow = true;
        await tester.pumpWidget(host.app());
        (tester.state(find.byKey(host.secondWindow)) as WindowListener)
            .onWindowClose();
        await pumpSidebar(tester);
        (tester.state(find.byKey(host.firstWindow)) as WindowListener)
            .onWindowClose();
        try {
          await pumpSidebar(tester);
          expect(host.secondExits, 1);
          expect(host.exits, 0);
        } finally {
          if (fails) {
            pending.completeError(failure);
          } else {
            pending.complete();
          }
          await settleSidebarWork(tester, () => pressed);
          await pumpSidebar(tester);
        }
        expect(host.exits, fails ? 0 : 1);
        expect(tester.takeException(), fails ? same(failure) : isNull);
        expect(host.ended, isTrue);
      },
    );
  }

  testWidgets(
    'failed cleanup and pending write both survive original host shutdown',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      final pending = Completer<void>();
      final writeFailure = StateError('original write and cleanup');
      await host.open(tester, () => pending.future);
      final pressed = _invoke(_confirm(tester));
      await pumpSidebar(tester);
      host.navigator.failRemove = true;
      Object? reported;
      final closing = host.original.closeAndWait().catchError((Object error) {
        reported = error;
      });
      try {
        await pumpSidebar(tester);
        expect(reported, isNull);
        expect(host.ended, isFalse);
      } finally {
        pending.completeError(writeFailure);
        await settleSidebarWork(tester, () => Future.wait([pressed, closing]));
      }
      expect(
        sidebarCauses(reported!),
        containsAll([same(writeFailure), same(host.navigator.failure)]),
      );
      expect(
        sidebarCauses(host.presentationError!),
        contains(same(host.navigator.failure)),
      );
      host.navigator.failRemove = false;
      await settleSidebarWork(tester, host.original.closeAndWait);
      await pumpSidebar(tester);
      expect(find.byType(ContentDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final busy in [false, true]) {
    testWidgets(
      'retained title close honors the busy state and original registry: busy=$busy',
      (tester) async {
        final host = _Host();
        await host.mount(tester);
        final pending = Completer<void>();
        await host.open(tester, () => pending.future);
        final close = tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.close))
            .onPressed!;
        Future<void>? pressed;
        if (busy) {
          pressed = _invoke(_confirm(tester));
        } else {
          host.registry = SelectionTaskRegistry();
          await tester.pumpWidget(host.app());
        }
        try {
          await pumpSidebar(tester);
          close();
          await pumpSidebar(tester);
          expect(host.ended, isFalse);
        } finally {
          pending.complete();
          if (pressed != null) await settleSidebarWork(tester, () => pressed!);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'large text keeps both confirmation actions within a narrow viewport',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = _Host()..textScale = 2.5;
      await host.mount(tester);
      await host.open(tester, () async {});
      expect(tester.takeException(), isNull);
      for (final label in ['Cancel', 'Confirm']) {
        final box = tester.getRect(find.text(label));
        expect(box.left, greaterThanOrEqualTo(0));
        expect(box.right, lessThanOrEqualTo(320));
      }
    },
  );
}
