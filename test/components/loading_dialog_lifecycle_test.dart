import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/selection_operation.dart';

void main() {
  late BuildContext context;
  late GlobalKey<NavigatorState> navigator;
  late SelectionTaskRegistry tasks;
  var allowed = true;

  setUp(() {
    rootBundle.clear();
    navigator = GlobalKey<NavigatorState>();
    tasks = SelectionTaskRegistry();
    allowed = true;
    final language = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
    addTearDown(() => appdata.settings['language'] = language);
  });

  Future<void> host(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      builder: (_, child) => SelectionTasksScope(
        registry: tasks,
        child: NavigationAdmission(
          allowsNavigation: () => allowed,
          child: child!,
        ),
      ),
      home: Builder(
        builder: (value) {
          context = value;
          return const Scaffold();
        },
      ),
    ),
  );

  Future<void> frames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  for (final cancelOnDismiss in [false, true]) {
    testWidgets(
      'unbuilt loading route closes automatically; cancellation=$cancelOnDismiss',
      (tester) async {
        await host(tester);
        var cancelled = 0;
        var closed = 0;
        final controller = showLoadingDialog(
          context,
          cancelOnDismiss: cancelOnDismiss,
          onCancel: () => cancelled++,
          onClosed: () => closed++,
        );
        await tester.pumpWidget(const SizedBox());
        await frames(tester);
        expect(controller.closed, isTrue);
        expect(controller.isCurrent, isFalse);
        expect(closed, 1);
        expect(cancelled, cancelOnDismiss ? 1 : 0);
        controller.close();
        expect(closed, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('loading cancellation rejects synchronous button reentry', (
    tester,
  ) async {
    await host(tester);
    var cancellations = 0;
    var closedDuringCancellation = false;
    VoidCallback? cancel;
    late LoadingDialogController controller;
    controller = showLoadingDialog(
      context,
      onCancel: () {
        cancellations++;
        if (cancellations == 1) {
          cancel!();
          closedDuringCancellation = controller.closed;
        }
      },
    );
    await frames(tester);
    cancel = tester.widget<FilledButton>(find.byType(FilledButton)).onPressed!;
    cancel();
    await frames(tester);
    expect(cancellations, 1);
    expect(closedDuringCancellation, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final state in ['frozen', 'covered', 'replaced', 'disposed']) {
    testWidgets('old loading cancellation rejects an inactive host: $state', (
      tester,
    ) async {
      await host(tester);
      var cancellations = 0;
      final controller = showLoadingDialog(
        context,
        cancelOnDismiss: false,
        onCancel: () => cancellations++,
      );
      await frames(tester);
      final cancel = tester
          .widget<FilledButton>(find.byType(FilledButton))
          .onPressed!;
      MaterialPageRoute<void>? newer;
      if (state == 'frozen') {
        allowed = false;
      } else if (state == 'covered') {
        newer = MaterialPageRoute<void>(builder: (_) => const Scaffold());
        navigator.currentState!.push(newer);
        await frames(tester);
      } else if (state == 'replaced') {
        tasks = SelectionTaskRegistry();
        await host(tester);
      } else {
        await tester.pumpWidget(const SizedBox());
      }
      cancel();
      await frames(tester);
      expect(cancellations, 0);
      if (newer != null) expect(newer.isCurrent, isTrue);
      controller.close();
      await frames(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'loading cancel retries only route removal after the callback ran',
    (tester) async {
      await host(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, _) => _FailingNavigator(
            key: navigator,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (value) {
                context = value;
                return const Scaffold();
              },
            ),
          ),
        ),
      );
      final original = navigator.currentState! as _FailingNavigatorState;
      var cancellations = 0;
      final controller = showLoadingDialog(
        context,
        onCancel: () => cancellations++,
      );
      await frames(tester);
      final cancel = tester
          .widget<FilledButton>(find.byType(FilledButton))
          .onPressed!;
      expect(cancel, throwsA(same(original.failure)));
      expect(cancellations, 1);
      expect(controller.closed, isFalse);
      original.fails = false;
      cancel();
      await frames(tester);
      expect(cancellations, 1);
      expect(original.removals, 2);
      expect(controller.closed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

class _FailingNavigator extends Navigator {
  const _FailingNavigator({super.key, super.onGenerateRoute});
  @override
  NavigatorState createState() => _FailingNavigatorState();
}

class _FailingNavigatorState extends NavigatorState {
  bool fails = true;
  int removals = 0;
  final failure = StateError('original loading removal failed');
  @override
  void removeRoute<T extends Object?>(Route<T> route, [T? result]) {
    removals++;
    if (fails) throw failure;
    super.removeRoute(route, result);
  }
}
