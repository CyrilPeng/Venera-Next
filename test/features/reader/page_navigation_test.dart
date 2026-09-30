import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/reader_controller.dart';

void main() {
  test('a completed replacement releases an unfinished animation', () async {
    final controller = _Controller();
    final reader = _navigation(controller);
    reader.toPage(150);
    reader.toPage(200);
    controller.animations[1].complete();
    await pumpEventQueue();
    expect(reader.state.isAnimating, isFalse);
    reader.toPage(250);
    controller.animations[0].complete();
    await pumpEventQueue();
    expect(reader.state.isAnimating, isTrue);
    controller.animations[2].complete();
    await pumpEventQueue();
    expect(reader.state.isAnimating, isFalse);
    reader.dispose();
  });

  test(
    'direct navigation cancels animation state and preserves destination',
    () async {
      final controller = _Controller();
      final reader = _navigation(controller);
      reader.toPage(150);
      reader.toPage(200, animated: false);
      expect(reader.state.isAnimating, isFalse);
      expect(controller.destination, 200);
      controller.animations.single.complete();
      await pumpEventQueue();
      expect(reader.state.page, 200);
      expect(reader.state.isAnimating, isFalse);
      reader.dispose();
    },
  );

  for (final synchronous in [false, true]) {
    test(
      'failed animation releases input (synchronous=$synchronous)',
      () async {
        final errors = <Object>[];
        final controller = _Controller()..throwSynchronously = synchronous;
        final reader = _navigation(
          controller,
          onError: (error, stack) => errors.add(error),
        );
        reader.toPage(200);
        if (!synchronous) {
          controller.animations.single.completeError(StateError('interrupted'));
        }
        await pumpEventQueue();
        expect(reader.state.isAnimating, isFalse);
        expect(errors, hasLength(1));
        reader.dispose();
      },
    );
  }
}

ReaderController _navigation(
  ReaderNavigationViewport viewport, {
  void Function(Object, StackTrace)? onError,
}) => ReaderController(
  pageCount: () => 300,
  chapterCount: () => 1,
  animationEnabled: () => true,
  viewport: () => viewport,
  onChanged: () {},
  onPageChanged: () {},
  onError: onError ?? (error, stack) => fail('$error'),
);

class _Controller implements ReaderNavigationViewport {
  final animations = <Completer<void>>[];
  bool throwSynchronously = false;
  int? destination;

  @override
  Future<void> animateToPage(int page) {
    if (throwSynchronously) throw StateError('interrupted');
    final animation = Completer<void>();
    animations.add(animation);
    return animation.future;
  }

  @override
  void toPage(int page) => destination = page;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
