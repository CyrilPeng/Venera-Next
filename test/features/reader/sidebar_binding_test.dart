import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/side_bar.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/sidebar_binding.dart';
import 'package:venera_next/foundation/navigation_admission.dart';

class _Host extends StatefulWidget {
  const _Host({super.key, required this.binding});
  final ReaderSidebarBinding binding;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  void open(String text) => widget.binding.show(context, Text(text));

  @override
  void dispose() {
    widget.binding.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  late ReaderSidebarBinding binding;
  late List<String> events;
  late List<Object> errors;
  late bool allowed;
  late GlobalKey<_HostState> host;
  late GlobalKey<NavigatorState> navigator;
  late ValueNotifier<bool> visible;

  setUp(() {
    events = [];
    errors = [];
    allowed = true;
    host = GlobalKey<_HostState>();
    navigator = GlobalKey<NavigatorState>();
    visible = ValueNotifier(true);
    binding = ReaderSidebarBinding(
      canOpen: () => allowed,
      acquireInteraction: () {
        events.add('pause');
        return () => events.add('release');
      },
      onError: (error, _) => errors.add(error),
    );
  });

  tearDown(() {
    binding.dispose();
    visible.dispose();
  });

  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: ValueListenableBuilder<bool>(
        valueListenable: visible,
        builder: (_, show, _) => show
            ? _Host(key: host, binding: binding)
            : const Text('reader removed'),
      ),
    ),
  );

  testWidgets('duplicate pending/open requests share one pause and sidebar', (
    tester,
  ) async {
    await mount(tester);
    host.currentState!.open('first');
    host.currentState!.open('duplicate');
    expect(events, ['pause']);
    await tester.pumpAndSettle();
    host.currentState!.open('another duplicate');
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);
    expect(find.text('duplicate'), findsNothing);
    expect(find.text('another duplicate'), findsNothing);
    expect(events, ['pause']);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(events, ['pause', 'release']);
    host.currentState!.open('retry');
    await tester.pumpAndSettle();
    expect(find.text('retry'), findsOneWidget);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(events, ['pause', 'release', 'pause', 'release']);
    expect(errors, isEmpty);
  });

  testWidgets(
    'replacement closes the old route without retiring a new request',
    (tester) async {
      await mount(tester);
      host.currentState!.open('old');
      await tester.pumpAndSettle();
      binding.close();
      host.currentState!.open('new');
      await tester.pumpAndSettle();
      expect(find.text('old'), findsNothing);
      expect(find.text('new'), findsOneWidget);
      expect(events, ['pause', 'pause', 'release']);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(events, ['pause', 'pause', 'release', 'release']);
      expect(errors, isEmpty);
    },
  );

  testWidgets('host navigation hold cancels a queued sidebar and can resume', (
    tester,
  ) async {
    var admitting = true;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => NavigationAdmission(
          allowsNavigation: () => admitting,
          child: child!,
        ),
        home: _Host(key: host, binding: binding),
      ),
    );
    host.currentState!.open('old sidebar');
    admitting = false;
    await tester.pumpAndSettle();
    expect(events, ['pause', 'release']);
    expect(find.text('old sidebar'), findsNothing);
    host.currentState!.open('blocked sidebar');
    expect(events, ['pause', 'release']);
    admitting = true;
    host.currentState!.open('new sidebar');
    await tester.pumpAndSettle();
    expect(find.text('new sidebar'), findsOneWidget);
    expect(errors, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'permission is checked before acquiring and again before opening',
    (tester) async {
      await mount(tester);
      allowed = false;
      host.currentState!.open('blocked');
      expect(events, isEmpty);
      allowed = true;
      host.currentState!.open('pending');
      allowed = false;
      await tester.pumpAndSettle();
      expect(find.text('pending'), findsNothing);
      expect(events, ['pause', 'release']);
      allowed = true;
      host.currentState!.open('allowed');
      await tester.pumpAndSettle();
      expect(find.text('allowed'), findsOneWidget);
      expect(errors, isEmpty);
    },
  );

  testWidgets('disposing before the frame cancels opening and releases once', (
    tester,
  ) async {
    await mount(tester);
    host.currentState!.open('pending');
    binding.dispose();
    binding.dispose();
    host.currentState!.open('after disposal');
    await tester.pumpAndSettle();
    expect(events, ['pause', 'release']);
    expect(find.text('pending'), findsNothing);
    expect(find.text('after disposal'), findsNothing);
    expect(errors, isEmpty);
  });

  testWidgets(
    'unmount removes only the owned sidebar from a surviving navigator',
    (tester) async {
      await mount(tester);
      host.currentState!.open('owned sidebar');
      await tester.pumpAndSettle();
      final unrelated = MaterialPageRoute<void>(
        builder: (_) => const Text('unrelated page'),
      );
      navigator.currentState!.push(unrelated);
      await tester.pumpAndSettle();
      visible.value = false;
      await tester.pumpAndSettle();
      expect(unrelated.isActive, isTrue);
      expect(find.text('unrelated page'), findsOneWidget);
      expect(events, ['pause', 'release']);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('owned sidebar'), findsNothing);
      expect(find.text('reader removed'), findsOneWidget);
      expect(errors, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('route lookup failure releases the pause and permits retry', (
    tester,
  ) async {
    await tester.pumpWidget(_Host(key: host, binding: binding));
    host.currentState!.open('no navigator');
    await tester.pump();
    expect(events, ['pause', 'release']);
    expect(errors.single, isA<FlutterError>());
    host.currentState!.open('retry lookup');
    await tester.pump();
    expect(events, ['pause', 'release', 'pause', 'release']);
    expect(errors, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing the navigator and owner releases interaction once', (
    tester,
  ) async {
    await mount(tester);
    host.currentState!.open('owned');
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(events, ['pause', 'release']);
    expect(errors, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sidebar width and existing route defaults are preserved', (
    tester,
  ) async {
    await mount(tester);
    binding.show(host.currentContext!, const Text('comments'), width: 500);
    await tester.pumpAndSettle();
    final context = tester.element(find.text('comments'));
    final route = ModalRoute.of(context)! as SideBarRoute<void>;
    expect(route.width, 500);
    expect(route.addTopPadding, isFalse);
    expect(route.addBottomPadding, isTrue);
    expect(route.dismissible, isTrue);
    expect(route.showBarrier, isTrue);
    expect(errors, isEmpty);
  });

  testWidgets('closing a sidebar preserves other automatic-reading pauses', (
    tester,
  ) async {
    final reader = AutoReadingController(
      settings: () => const AutoReadingSettings(),
      canAdvance: () => true,
      advance: (_) => AutoReadingStep.advanced,
    );
    final sidebarReason = Object();
    binding = ReaderSidebarBinding(
      canOpen: () => true,
      acquireInteraction: () {
        reader.pause(sidebarReason, true);
        return () => reader.pause(sidebarReason, false);
      },
      onError: (error, _) => errors.add(error),
    );
    await mount(tester);
    reader.start();
    host.currentState!.open('paused sidebar');
    await tester.pumpAndSettle();
    expect(reader.status, AutoReadingStatus.paused);
    reader.pause('pointer', true);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(reader.status, AutoReadingStatus.paused);
    reader.pause('pointer', false);
    expect(reader.status, AutoReadingStatus.running);
    reader.stop();
    reader.dispose();
    expect(errors, isEmpty);
  });

  testWidgets('acquisition failure leaves a retryable binding', (tester) async {
    var fail = true;
    binding = ReaderSidebarBinding(
      canOpen: () => true,
      acquireInteraction: () {
        if (fail) throw StateError('cannot pause');
        events.add('pause');
        return () => events.add('release');
      },
      onError: (error, _) => errors.add(error),
    );
    await mount(tester);
    host.currentState!.open('failed');
    expect(errors.single, isA<StateError>());
    fail = false;
    host.currentState!.open('retry');
    await tester.pumpAndSettle();
    expect(find.text('retry'), findsOneWidget);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(events, ['pause', 'release']);
  });

  testWidgets(
    'release failure is reported once and does not retain the route',
    (tester) async {
      binding = ReaderSidebarBinding(
        canOpen: () => true,
        acquireInteraction: () => () {
          events.add('release');
          throw StateError('cannot release');
        },
        onError: (error, _) => errors.add(error),
      );
      await mount(tester);
      host.currentState!.open('owned');
      await tester.pumpAndSettle();
      visible.value = false;
      await tester.pumpAndSettle();
      expect(find.text('owned'), findsNothing);
      expect(events, ['release']);
      expect(errors.single, isA<StateError>());
      expect(tester.takeException(), isNull);
    },
  );
}
