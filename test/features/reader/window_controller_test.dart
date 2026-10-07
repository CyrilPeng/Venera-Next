import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/window_controller.dart';

class _Window {
  final events = <String>[];
  final errors = <Object>[];
  final listeners = <bool Function()>[];
  final frameIdentity = Object();
  Future<void> Function()? hiding, showing;
  Future<void> Function(bool)? fullscreen;
  void Function(bool)? frame;
  void Function(bool Function())? adding, removing;
  late final coordinator = ReaderWindowCoordinator(
    hide: () async {
      events.add('hide');
      await hiding?.call();
    },
    show: () async {
      events.add('show');
      await showing?.call();
    },
    setFullscreen: (value) async {
      events.add('fullscreen:$value');
      await fullscreen?.call(value);
    },
  );

  ReaderWindowController reader({
    Object? identity,
    void Function(bool)? setFrame,
    void Function(Object, StackTrace)? onError,
  }) => ReaderWindowController(
    coordinator: coordinator,
    frameIdentity: identity ?? frameIdentity,
    initialFrameVisible: true,
    setFrameVisible:
        setFrame ??
        (value) {
          events.add('frame:$value');
          frame?.call(value);
        },
    addCloseListener: (listener) {
      if (adding != null) {
        adding!(listener);
      } else {
        listeners.add(listener);
      }
    },
    removeCloseListener: (listener) {
      if (removing != null) {
        removing!(listener);
      } else {
        listeners.remove(listener);
      }
    },
    canPop: () => true,
    pop: () => events.add('pop'),
    onError: onError ?? (error, _) => errors.add(error),
  );
}

void main() {
  test(
    'idle shared coordinator does not retain a retired scheduling zone',
    () async {
      final window = _Window();
      final microtasks = <void Function()>[];
      var oldClosed = false;
      runZoned(
        () {
          final old = window.reader();
          unawaited(
            old
                .attach()
                .then((_) => old.dispose())
                .then((_) => oldClosed = true),
          );
        },
        zoneSpecification: ZoneSpecification(
          scheduleMicrotask: (self, parent, zone, task) {
            microtasks.add(() => zone.runGuarded(task));
          },
        ),
      );
      while (microtasks.isNotEmpty) {
        microtasks.removeAt(0)();
      }
      expect(oldClosed, isTrue);
      final current = window.reader();
      var attached = false;
      final attaching = current.attach().then((_) => attached = true);
      await Future<void>.delayed(Duration.zero);
      expect(microtasks, isEmpty);
      expect(attached, isTrue);
      await attaching;
      await current.dispose();
    },
  );

  test(
    'listener is registered once and retired callbacks cannot navigate',
    () async {
      final window = _Window();
      final reader = window.reader();
      await reader.attach();
      await reader.attach();
      final captured = window.listeners.single;
      expect(captured(), isFalse);
      expect(window.events, ['pop']);
      final closing = reader.dispose();
      expect(window.listeners, isEmpty);
      expect(captured(), isTrue);
      await closing;
      await reader.attach();
      expect(window.listeners, isEmpty);
    },
  );

  test(
    'fullscreen transition and release preserve window and frame order',
    () async {
      final window = _Window();
      final reader = window.reader();
      await reader.attach();
      await reader.toggle();
      expect(window.events, ['hide', 'fullscreen:true', 'show', 'frame:false']);
      final closing = reader.dispose();
      expect(identical(closing, reader.dispose()), isTrue);
      await closing;
      await reader.toggle();
      expect(window.events, [
        'hide',
        'fullscreen:true',
        'show',
        'frame:false',
        'hide',
        'fullscreen:false',
        'show',
        'frame:true',
      ]);
    },
  );

  test(
    'close waits for accepted native entry before restoring windowed mode',
    () async {
      final window = _Window();
      final entering = Completer<void>();
      window.fullscreen = (value) => value ? entering.future : Future.value();
      final reader = window.reader();
      await reader.attach();
      final opening = reader.toggle();
      await Future<void>.delayed(Duration.zero);
      final closing = reader.dispose();
      expect(window.events, ['hide', 'fullscreen:true']);
      entering.complete();
      await Future.wait([opening, closing]);
      expect(window.events.where((e) => e.startsWith('fullscreen')), [
        'fullscreen:true',
        'fullscreen:false',
      ]);
      expect(window.events, isNot(contains('frame:false')));
      expect(window.events.last, 'show');
    },
  );

  test('rapid toggles coalesce to the last requested state', () async {
    final window = _Window();
    final reader = window.reader();
    await reader.attach();
    await Future.wait([reader.toggle(), reader.toggle()]);
    expect(window.events, isEmpty);
    await Future.wait([reader.toggle(), reader.toggle(), reader.toggle()]);
    expect(window.events, ['hide', 'fullscreen:true', 'show', 'frame:false']);
    await reader.dispose();
  });

  test(
    'old reader close and captured listener cannot overwrite new fullscreen owner',
    () async {
      final window = _Window();
      final old = window.reader();
      await old.attach();
      final oldListener = window.listeners.single;
      await old.toggle();
      final current = window.reader();
      await current.attach();
      window.events.clear();
      expect(oldListener(), isTrue);
      await old.toggle();
      await old.dispose();
      expect(window.events, isEmpty);
      expect(window.listeners, hasLength(1));
      await current.toggle();
      expect(window.events, ['hide', 'fullscreen:false', 'show', 'frame:true']);
      await current.dispose();
    },
  );

  test('new reader release restores underlying owner preference', () async {
    final window = _Window();
    final old = window.reader();
    await old.attach();
    await old.toggle();
    final current = window.reader();
    await current.attach();
    await current.toggle();
    window.events.clear();
    await current.dispose();
    expect(window.events, ['hide', 'fullscreen:true', 'show', 'frame:false']);
    await old.dispose();
  });

  test(
    'window preparation holds input and restores latest preference on resume',
    () async {
      final window = _Window();
      final reader = window.reader();
      await reader.attach();
      await reader.toggle();
      await reader.setHeld(true);
      window.events.clear();
      await reader.toggle();
      expect(window.listeners.single(), isTrue);
      expect(window.events, isEmpty);
      await reader.setHeld(false);
      expect(window.events, ['hide', 'fullscreen:true', 'show', 'frame:false']);
      await reader.dispose();
      window.events.clear();
      await reader.setHeld(false);
      expect(window.events, isEmpty);
    },
  );

  test('all transition failures preserve original causes and stacks', () async {
    final window = _Window();
    final errors = List.generate(4, (i) => StateError('step $i'));
    final stacks = List.generate(
      4,
      (i) => StackTrace.fromString('original $i'),
    );
    final reader = window.reader();
    await reader.attach();
    await reader.toggle();
    window.hiding = () => Future.error(errors[0], stacks[0]);
    window.fullscreen = (_) => Future.error(errors[1], stacks[1]);
    window.showing = () => Future.error(errors[2], stacks[2]);
    window.frame = (_) => Error.throwWithStackTrace(errors[3], stacks[3]);
    await expectLater(
      reader.dispose(),
      throwsA(
        isA<ReaderWindowFailure>()
            .having(
              (f) => f.failures.map((f) => f.error).toList(),
              'errors',
              errors,
            )
            .having(
              (f) => f.failures.map((f) => f.stackTrace).toList(),
              'stacks',
              stacks,
            ),
      ),
    );
    window.hiding = null;
    window.fullscreen = null;
    window.showing = null;
    window.frame = null;
    window.events.clear();
    await reader.dispose();
    expect(window.events, ['fullscreen:false', 'show', 'frame:true']);
  });

  for (final failedStep in ['show', 'frame', 'remove']) {
    test(
      'release retries only unresolved $failedStep after other effects succeeded',
      () async {
        final window = _Window();
        final error = StateError(failedStep);
        final stack = StackTrace.current;
        final reader = window.reader();
        await reader.attach();
        await reader.toggle();
        if (failedStep == 'show') {
          window.showing = () => Future.error(error, stack);
        }
        if (failedStep == 'frame') {
          window.frame = (_) => Error.throwWithStackTrace(error, stack);
        }
        if (failedStep == 'remove') {
          window.removing = (_) => Error.throwWithStackTrace(error, stack);
        }
        try {
          await reader.dispose();
          fail('expected native release failure');
        } catch (caught, caughtStack) {
          expect(caught, same(error));
          expect(caughtStack.toString(), stack.toString());
        }
        window.hiding = null;
        window.showing = null;
        window.frame = null;
        window.removing = null;
        window.events.clear();
        await reader.dispose();
        await reader.dispose();
        expect(window.events, switch (failedStep) {
          'show' => ['show'],
          'frame' => ['frame:true'],
          _ => <String>[],
        });
        expect(window.listeners, isEmpty);
      },
    );
  }

  test(
    'hide failure is reported but cannot prevent native restore and visibility recovery',
    () async {
      final window = _Window();
      final reader = window.reader();
      await reader.attach();
      await reader.toggle();
      final error = StateError('hide');
      window.hiding = () async => throw error;
      window.events.clear();
      await expectLater(reader.dispose(), throwsA(same(error)));
      expect(window.events, ['hide', 'fullscreen:false', 'show', 'frame:true']);
      window.events.clear();
      await reader.dispose();
      expect(window.events, isEmpty);
    },
  );

  test(
    'listener registration reentry closes after actual registration completes',
    () async {
      final window = _Window();
      late ReaderWindowController reader;
      Future<void>? closing;
      window.adding = (listener) {
        closing = reader.dispose();
        window.listeners.add(listener);
      };
      reader = window.reader();
      await reader.attach();
      await closing;
      expect(window.listeners, isEmpty);
      expect(window.events, isEmpty);
    },
  );

  test(
    'throwing registration and reporter retain errors while cleanup remains possible',
    () async {
      final window = _Window();
      final registrationError = StateError('registration');
      final reportError = StateError('report');
      window.adding = (listener) {
        window.listeners.add(listener);
        throw registrationError;
      };
      final reader = window.reader(onError: (_, _) => throw reportError);
      await expectLater(
        reader.attach(),
        throwsA(
          isA<ReaderWindowFailure>().having(
            (f) => f.failures.map((f) => f.error).toList(),
            'errors',
            [registrationError, reportError],
          ),
        ),
      );
      await reader.dispose();
      expect(window.listeners, isEmpty);
    },
  );

  test(
    'retired failed release follows new owner rather than stale windowed target',
    () async {
      final window = _Window();
      final old = window.reader();
      await old.attach();
      await old.toggle();
      var failRestore = true;
      window.fullscreen = (value) async {
        if (!value && failRestore) throw StateError('restore');
      };
      await expectLater(old.dispose(), throwsStateError);
      final current = window.reader();
      failRestore = false;
      await current.attach();
      await current.toggle();
      window.events.clear();
      await old.dispose();
      expect(window.events, isEmpty);
      await current.dispose();
    },
  );

  test(
    'replaced frames restore independently without retaining stale fullscreen policy',
    () async {
      final window = _Window();
      final old = window.reader();
      await old.attach();
      await old.toggle();
      final current = window.reader(
        identity: Object(),
        setFrame: (value) => window.events.add('new frame:$value'),
      );
      await current.attach();
      expect(window.events, contains('frame:true'));
      expect(window.events.last, 'new frame:false');
      window.events.clear();
      await old.dispose();
      expect(window.events, isEmpty);
      await current.dispose();
      expect(window.events.last, 'new frame:true');
    },
  );
}
