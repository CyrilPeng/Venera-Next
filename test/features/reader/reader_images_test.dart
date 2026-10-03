import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/images.dart';
import 'package:venera_next/features/reader/reader_controller.dart';
import 'package:venera_next/network/request_scope.dart';

ReaderController _controller() => ReaderController(
  pageCount: () => 1,
  chapterCount: () => 1,
  animationEnabled: () => false,
  viewport: () => null,
  onChanged: () {},
  onPageChanged: () {},
  onError: (error, stack) => throw error,
);

Widget _view(
  ReaderController controller, {
  Future<void> Function(RequestScope)? before,
  required Future<List<String>> Function(RequestScope) load,
  Future<void> Function()? prepare,
  required List<String> events,
}) => MaterialApp(
  home: ReaderImages(
    controller: controller,
    beforeLoad: before ?? (_) async {},
    loadImages: load,
    prepareMode: prepare ?? () async {},
    onLoading: () => events.add('loading'),
    onCommitted: () => events.add('committed'),
    onReady: () => events.add('ready'),
    onSettled: () => events.add('settled'),
    contentBuilder: (_, content) {
      expect(content.isLoading, isFalse);
      expect(content.error, isNull);
      return const Text('content');
    },
    errorBuilder: (_, error, retry) => Column(
      children: [
        Text(error),
        TextButton(onPressed: retry, child: const Text('retry')),
      ],
    ),
  ),
);

void main() {
  for (final unmount in [false, true]) {
    testWidgets(
      'late retry callback cannot restart a new owner; unmount=$unmount',
      (tester) async {
        final old = _controller();
        final current = _controller();
        addTearDown(old.dispose);
        addTearDown(current.dispose);
        await tester.pumpWidget(
          _view(
            old,
            events: [],
            load: (_) async => throw StateError('offline'),
          ),
        );
        await tester.pumpAndSettle();
        final retry = tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'retry'))
            .onPressed!;
        final events = <String>[];
        if (unmount) {
          await tester.pumpWidget(const SizedBox());
        } else {
          await tester.pumpWidget(
            _view(current, events: events, load: (_) async => ['new']),
          );
          await tester.pumpAndSettle();
        }
        final before = List<String>.of(events);
        retry();
        await tester.pump();
        expect(events, before);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'loads independently, deduplicates rebuilds and preserves notification order',
    (tester) async {
      final controller = _controller();
      addTearDown(controller.dispose);
      final gate = Completer<List<String>>();
      final events = <String>[];
      var calls = 0;
      Widget build() => _view(
        controller,
        events: events,
        load: (_) {
          calls++;
          return gate.future;
        },
      );
      await tester.pumpWidget(build());
      await tester.pumpWidget(build());
      expect(calls, 1);
      expect(events, ['loading']);
      gate.complete(['image']);
      await tester.pumpAndSettle();
      expect(find.text('content'), findsOneWidget);
      expect(events, ['loading', 'committed', 'settled', 'ready']);
    },
  );

  testWidgets('error presentation retries with a new owned attempt', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    final events = <String>[];
    var calls = 0;
    await tester.pumpWidget(
      _view(
        controller,
        events: events,
        load: (_) async {
          if (++calls == 1) throw StateError('offline');
          return ['image'];
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('offline'), findsOneWidget);
    await tester.tap(find.text('retry'));
    await tester.pumpAndSettle();
    expect(find.text('content'), findsOneWidget);
    expect(calls, 2);
    expect(events, [
      'loading',
      'settled',
      'loading',
      'committed',
      'settled',
      'ready',
    ]);
  });

  for (final phase in ['before', 'load', 'prepare']) {
    testWidgets(
      'unmount during $phase cancels scope and ignores late failure',
      (tester) async {
        final controller = _controller();
        addTearDown(controller.dispose);
        final gate = Completer<void>();
        final events = <String>[];
        RequestScope? scope;
        await tester.pumpWidget(
          _view(
            controller,
            events: events,
            before: (value) async {
              scope = value;
              if (phase == 'before') await gate.future;
            },
            load: (_) async {
              if (phase == 'load') await gate.future;
              return ['image'];
            },
            prepare: () async {
              if (phase == 'prepare') await gate.future;
            },
          ),
        );
        await tester.pump();
        await tester.pumpWidget(const SizedBox());
        expect(scope!.isCancelled, isTrue);
        gate.completeError(StateError('late'));
        await tester.pump();
        expect(events, ['loading']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'retained view transfers controller ownership and rejects old completion',
    (tester) async {
      final old = _controller();
      final current = _controller();
      addTearDown(old.dispose);
      addTearDown(current.dispose);
      final gate = Completer<List<String>>();
      final oldEvents = <String>[];
      final currentEvents = <String>[];
      RequestScope? oldScope;
      await tester.pumpWidget(
        _view(
          old,
          events: oldEvents,
          load: (scope) {
            oldScope = scope;
            return gate.future;
          },
        ),
      );
      await tester.pumpWidget(
        _view(current, events: currentEvents, load: (_) async => ['current']),
      );
      await tester.pumpAndSettle();
      expect(oldScope!.isCancelled, isTrue);
      gate.complete(['old']);
      await tester.pump();
      expect(oldEvents, ['loading']);
      expect(currentEvents, ['loading', 'committed', 'settled', 'ready']);
      expect(current.content.images, ['current']);
    },
  );
}
