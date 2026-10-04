import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/images.dart';
import 'package:venera_next/foundation/image_work.dart';
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
  ImageWork? imageWork,
  Future<void> Function(RequestScope)? before,
  required Future<List<String>> Function(RequestScope) load,
  Future<void> Function()? prepare,
  required List<String> events,
}) => MaterialApp(
  home: ReaderImages(
    controller: controller,
    imageWork: imageWork,
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
  for (final phase in ['before', 'load', 'prepare']) {
    for (final fails in [false, true]) {
      testWidgets(
        'mounted content joins cancelled $phase and reloads on resume; fails=$fails',
        (tester) async {
          final controller = _controller();
          final work = ImageWork();
          final gate = Completer<void>();
          final failure = StateError(
            'original $phase failed after cancellation',
          );
          final events = <String>[];
          final scopes = <RequestScope>[];
          var attempts = 0;
          await tester.pumpWidget(
            _view(
              controller,
              imageWork: work,
              events: events,
              before: (scope) async {
                scopes.add(scope);
                attempts++;
                if (attempts == 1 && phase == 'before') await gate.future;
              },
              load: (_) async {
                if (attempts == 1 && phase == 'load') await gate.future;
                return ['attempt-$attempts'];
              },
              prepare: () async {
                if (attempts == 1 && phase == 'prepare') await gate.future;
              },
            ),
          );
          await tester.pump();
          expect(attempts, 1);
          var prepared = false;
          final preparing = work.prepareForExit();
          Future<void>? failedPreparation;
          if (fails) {
            failedPreparation = expectLater(
              preparing,
              throwsA(
                isA<ImageWorkFailure>().having(
                  (error) => error.failures.single.error,
                  'original failure',
                  same(failure),
                ),
              ),
            ).then((_) => prepared = true);
          } else {
            unawaited(preparing.then((_) => prepared = true));
          }
          await tester.pump();
          expect(scopes.single.isCancelled, isTrue);
          expect(prepared, isFalse);
          expect(events, ['loading']);
          expect(find.byType(ReaderImages), findsOneWidget);
          if (fails) {
            gate.completeError(failure);
          } else {
            gate.complete();
          }
          await tester.pump();
          if (fails) {
            await failedPreparation;
          } else {
            final release = await preparing;
            expect(attempts, 1);
            release();
          }
          await tester.pumpAndSettle();
          expect(attempts, 2);
          expect(controller.content.images, ['attempt-2']);
          expect(events, [
            'loading',
            'loading',
            'committed',
            'settled',
            'ready',
          ]);
          await tester.pumpWidget(const SizedBox());
          await work.dispose();
          controller.dispose();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'content first built while held waits for the final hold release',
    (tester) async {
      final controller = _controller();
      final work = ImageWork();
      final first = work.holdForExit();
      final last = work.holdForExit();
      var loads = 0;
      final events = <String>[];
      Widget build() => _view(
        controller,
        imageWork: work,
        events: events,
        load: (_) async {
          loads++;
          return ['ready'];
        },
      );
      await tester.pumpWidget(build());
      await tester.pumpWidget(build());
      expect(loads, 0);
      first();
      await tester.pump();
      expect(loads, 0);
      last();
      last();
      await tester.pumpAndSettle();
      expect(loads, 1);
      expect(events, ['loading', 'loading', 'committed', 'settled', 'ready']);
      await tester.pumpWidget(const SizedBox());
      await work.dispose();
      controller.dispose();
    },
  );

  for (final changeController in [false, true]) {
    testWidgets(
      'content ownership transfer ignores old completion and resume; controller=$changeController',
      (tester) async {
        final oldController = _controller();
        final nextController = changeController ? _controller() : oldController;
        final oldWork = ImageWork();
        final nextWork = ImageWork();
        final original = Completer<List<String>>();
        final oldEvents = <String>[];
        final nextEvents = <String>[];
        await tester.pumpWidget(
          _view(
            oldController,
            imageWork: oldWork,
            events: oldEvents,
            load: (_) => original.future,
          ),
        );
        var prepared = false;
        final preparing = oldWork.prepareForExit().then((release) {
          prepared = true;
          return release;
        });
        var nextLoads = 0;
        await tester.pumpWidget(
          _view(
            nextController,
            imageWork: nextWork,
            events: nextEvents,
            load: (_) async {
              nextLoads++;
              return ['current'];
            },
          ),
        );
        await tester.pumpAndSettle();
        expect(prepared, isFalse);
        expect(nextLoads, 1);
        original.complete(['old']);
        await tester.pump();
        (await preparing)();
        await tester.pumpAndSettle();
        expect(nextLoads, 1);
        expect(nextController.content.images, ['current']);
        expect(oldEvents, ['loading']);
        expect(nextEvents, ['loading', 'committed', 'settled', 'ready']);
        await tester.pumpWidget(const SizedBox());
        await oldWork.dispose();
        await nextWork.dispose();
        oldController.dispose();
        if (changeController) nextController.dispose();
      },
    );
  }

  testWidgets(
    'controller replacement keeps late failure with shared image work',
    (tester) async {
      final oldController = _controller();
      final currentController = _controller();
      final work = ImageWork();
      final original = Completer<List<String>>();
      final failure = StateError('old controller failed after replacement');
      final currentEvents = <String>[];
      RequestScope? oldScope;
      await tester.pumpWidget(
        _view(
          oldController,
          imageWork: work,
          events: [],
          load: (scope) {
            oldScope = scope;
            return original.future;
          },
        ),
      );
      var currentLoads = 0;
      await tester.pumpWidget(
        _view(
          currentController,
          imageWork: work,
          events: currentEvents,
          load: (_) async {
            currentLoads++;
            return ['current'];
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(oldScope!.isCancelled, isTrue);
      var prepared = false;
      final preparing = expectLater(
        work.prepareForExit(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (error) => error.failures.single.error,
            'retired controller failure',
            same(failure),
          ),
        ),
      ).then((_) => prepared = true);
      await tester.pump();
      expect(prepared, isFalse);
      original.completeError(failure);
      await tester.pump();
      await preparing;
      await tester.pumpAndSettle();
      expect(currentLoads, 1);
      expect(currentController.content.images, ['current']);
      expect(currentEvents, ['loading', 'committed', 'settled', 'ready']);
      await tester.pumpWidget(const SizedBox());
      await work.dispose();
      oldController.dispose();
      currentController.dispose();
    },
  );

  testWidgets(
    'unmounted content retains its late failure without rebinding on resume',
    (tester) async {
      final controller = _controller();
      final work = ImageWork();
      final original = Completer<List<String>>();
      final events = <String>[];
      final failure = StateError('late original chapter failure');
      await tester.pumpWidget(
        _view(
          controller,
          imageWork: work,
          events: events,
          load: (_) => original.future,
        ),
      );
      await tester.pumpWidget(const SizedBox());
      final observed = expectLater(
        work.prepareForExit(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (error) => error.failures.single.error,
            'late failure',
            same(failure),
          ),
        ),
      );
      original.completeError(failure);
      await tester.pump();
      await observed;
      expect(events, ['loading']);
      await work.dispose();
      controller.dispose();
      expect(tester.takeException(), isNull);
    },
  );

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
