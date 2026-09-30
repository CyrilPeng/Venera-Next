import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/volume_controller.dart';

ReaderVolumeController controller({
  required Stream<Object?> Function() events,
  required List<String> actions,
  bool Function()? nextPage,
  bool Function()? previousPage,
  void Function(Object, StackTrace)? onError,
}) => ReaderVolumeController(
  events: events,
  nextPage:
      nextPage ??
      () {
        actions.add('next page');
        return false;
      },
  previousPage:
      previousPage ??
      () {
        actions.add('previous page');
        return false;
      },
  nextChapter: () => actions.add('next chapter'),
  previousChapter: () => actions.add('previous chapter end'),
  onError: onError ?? (error, stack) => fail('$error'),
);

void main() {
  test(
    'volume events navigate pages, falling back to chapter boundaries',
    () async {
      final source = StreamController<Object?>(sync: true);
      final actions = <String>[];
      var pageAvailable = true;
      final reader = controller(
        events: () => source.stream,
        actions: actions,
        nextPage: () {
          actions.add('next page');
          return pageAvailable;
        },
        previousPage: () {
          actions.add('previous page');
          return pageAvailable;
        },
      );
      await reader.setEnabled(true);
      source.add(1);
      source.add(2);
      source.add('unknown');
      pageAvailable = false;
      source.add(1);
      source.add(2);
      expect(actions, [
        'previous page',
        'next page',
        'previous page',
        'previous chapter end',
        'next page',
        'next chapter',
      ]);
      await reader.dispose();
      await source.close();
    },
  );

  test(
    'rapid disable/enable waits for old cancellation and suppresses queued input',
    () async {
      final cancelled = Completer<void>();
      final old = StreamController<Object?>(
        sync: true,
        onCancel: () => cancelled.future,
      );
      final current = StreamController<Object?>(sync: true);
      var connects = 0;
      final actions = <String>[];
      final reader = controller(
        events: () => ++connects == 1 ? old.stream : current.stream,
        actions: actions,
      );
      await reader.setEnabled(true);
      await reader.setEnabled(true);
      expect(connects, 1);
      final disabling = reader.setEnabled(false);
      old.add(
        1,
      ); // The state change must suppress input before cancellation runs.
      final enabling = reader.setEnabled(true);
      old.add(2); // A retiring generation must not act after re-enabling.
      await Future<void>.delayed(Duration.zero);
      expect(connects, 1);
      expect(actions, isEmpty);
      cancelled.complete();
      await Future.wait([disabling, enabling]);
      expect(connects, 2);
      current.add(2);
      expect(actions, ['next page', 'next chapter']);
      final closing = reader.dispose();
      current.add(1);
      await closing;
      await reader.setEnabled(true);
      expect(connects, 2);
      expect(actions, ['next page', 'next chapter']);
      await old.close();
      await current.close();
    },
  );

  test(
    'exit during cancellation never starts the requested replacement',
    () async {
      final cancelled = Completer<void>();
      final source = StreamController<Object?>(
        onCancel: () => cancelled.future,
      );
      var connects = 0;
      final reader = controller(
        events: () {
          connects++;
          return source.stream;
        },
        actions: [],
      );
      await reader.setEnabled(true);
      final off = reader.setEnabled(false);
      final on = reader.setEnabled(true);
      final closing = reader.dispose();
      expect(identical(closing, reader.dispose()), isTrue);
      cancelled.complete();
      await Future.wait([off, on, closing]);
      expect(connects, 1);
      await source.close();
    },
  );

  test(
    'connection and event failures are reported and a closed stream can reconnect',
    () async {
      final source = StreamController<Object?>(sync: true);
      final replacement = StreamController<Object?>(sync: true);
      final errors = <Object>[];
      final actions = <String>[];
      var connects = 0;
      final reader = controller(
        events: () {
          connects++;
          if (connects == 1) throw StateError('connect');
          return connects == 2 ? source.stream : replacement.stream;
        },
        actions: actions,
        onError: (error, stack) => errors.add(error),
      );
      await reader.setEnabled(true);
      await reader.setEnabled(true);
      source.addError(StateError('event'));
      source.add(2);
      expect(errors, hasLength(2));
      expect(actions, ['next page', 'next chapter']);
      await source.close();
      await reader.setEnabled(true);
      replacement.add(1);
      expect(connects, 3);
      expect(actions.last, 'previous chapter end');
      await reader.dispose();
      await replacement.close();
    },
  );
}
