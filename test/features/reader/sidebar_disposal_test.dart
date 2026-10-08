import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/side_bar.dart';
import 'package:venera_next/features/reader/sidebar_binding.dart';

import '../../components/sidebar_presentation_test.dart' show pumpSidebar;

void main() {
  for (final built in [false, true]) {
    testWidgets(
      'Navigator disposal releases a surviving reader binding: $built',
      (tester) async {
        final visible = ValueNotifier(true);
        final events = <String>[];
        final errors = <Object>[];
        final binding = ReaderSidebarBinding(
          canOpen: () => true,
          acquireInteraction: () {
            events.add('pause');
            return () => events.add('release');
          },
          onError: (error, _) => errors.add(error),
        );
        addTearDown(() {
          binding.dispose();
          visible.dispose();
        });
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            builder: (_, _) => ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, show, _) => show
                  ? Navigator(
                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                        builder: (value) {
                          context = value;
                          return const Scaffold();
                        },
                      ),
                    )
                  : const SizedBox(),
            ),
          ),
        );
        final handle = binding.show(context, const Text('Reader sidebar'))!;
        await tester.pump();
        if (built) await pumpSidebar(tester);
        visible.value = false;
        await pumpSidebar(tester);
        expect(handle.isCurrent, isFalse);
        expect(events, ['pause', 'release']);
        expect(errors, isEmpty);
        expect(tester.takeException(), isNull);
        visible.value = true;
        await pumpSidebar(tester);
        expect(
          binding.show(context, const Text('Replacement sidebar')),
          isNotNull,
        );
        await pumpSidebar(tester);
        expect(find.text('Replacement sidebar'), findsOneWidget);
        binding.close();
        await pumpSidebar(tester);
        expect(events, ['pause', 'release', 'pause', 'release']);
      },
    );
  }

  testWidgets('reader barrier cannot dismiss a retired chapter request', (
    tester,
  ) async {
    var current = true;
    final events = <String>[];
    final binding = ReaderSidebarBinding(
      canOpen: () => true,
      acquireInteraction: () {
        events.add('pause');
        return () => events.add('release');
      },
      onError: (error, stack) => Error.throwWithStackTrace(error, stack),
    );
    addTearDown(binding.dispose);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold();
          },
        ),
      ),
    );
    binding.show(
      context,
      const Text('Original chapter'),
      isRequestCurrent: () => current,
    );
    await tester.pumpAndSettle();
    final route =
        ModalRoute.of(tester.element(find.text('Original chapter')))!
            as SideBarRoute<void>;
    final listener = route.buildModalBarrier() as Listener;
    listener.onPointerDown!(const PointerDownEvent(position: Offset(1, 1)));
    current = false;
    (listener.child! as ModalBarrier).onDismiss!();
    await pumpSidebar(tester);
    expect(route.isCurrent, isTrue);
    expect(events, ['pause']);
    binding.close();
    await pumpSidebar(tester);
    expect(events, ['pause', 'release']);
    expect(tester.takeException(), isNull);
  });
}
