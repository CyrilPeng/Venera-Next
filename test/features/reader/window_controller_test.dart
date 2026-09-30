import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/window_controller.dart';

void main() {
  late ReaderWindowController reader;
  late List<String> events;
  late List<bool Function()> listeners;
  late List<Object> errors;
  late bool canPop;
  setUp(() {
    events = [];
    listeners = [];
    errors = [];
    canPop = true;
    reader = ReaderWindowController(
      hide: () async => events.add('hide'),
      show: () async => events.add('show'),
      setFullscreen: (value) async => events.add('fullscreen:$value'),
      setFrameVisible: (value) => events.add('frame:$value'),
      addCloseListener: listeners.add,
      removeCloseListener: listeners.remove,
      canPop: () => canPop,
      pop: () => events.add('pop'),
      onError: (error, stack) => errors.add(error),
    );
  });

  test(
    'close listener is attached once and released immediately on exit',
    () async {
      reader.attach();
      reader.attach();
      expect(listeners, hasLength(1));
      final captured = listeners.single;
      expect(captured(), isFalse);
      expect(events, ['pop']);
      canPop = false;
      expect(captured(), isTrue);
      final closing = reader.dispose();
      expect(listeners, isEmpty);
      canPop = true;
      expect(captured(), isTrue);
      reader.attach();
      await closing;
      expect(listeners, isEmpty);
      expect(events, ['pop']);
    },
  );

  test(
    'fullscreen order and exit restoration preserve frame visibility',
    () async {
      await reader.toggle();
      expect(events, ['hide', 'fullscreen:true', 'show', 'frame:false']);
      final closing = reader.dispose();
      expect(identical(closing, reader.dispose()), isTrue);
      await closing;
      await reader.toggle();
      expect(events, [
        'hide',
        'fullscreen:true',
        'show',
        'frame:false',
        'hide',
        'fullscreen:false',
        'show',
        'frame:true',
      ]);
      expect(errors, isEmpty);
    },
  );

  test(
    'exit waits for an in-flight native transition before restoring',
    () async {
      final entering = Completer<void>();
      reader = ReaderWindowController(
        hide: () async => events.add('hide'),
        show: () async => events.add('show'),
        setFullscreen: (value) {
          events.add('fullscreen:$value');
          return value ? entering.future : Future.value();
        },
        setFrameVisible: (value) => events.add('frame:$value'),
        addCloseListener: listeners.add,
        removeCloseListener: listeners.remove,
        canPop: () => false,
        pop: () {},
        onError: (error, stack) => errors.add(error),
      );
      final toggle = reader.toggle();
      await Future<void>.delayed(Duration.zero);
      final closing = reader.dispose();
      expect(events, ['hide', 'fullscreen:true']);
      entering.complete();
      await Future.wait([toggle, closing]);
      expect(events, [
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

  test('rapid toggles coalesce to their final requested state', () async {
    await Future.wait([reader.toggle(), reader.toggle()]);
    expect(events, isEmpty);
    await Future.wait([reader.toggle(), reader.toggle(), reader.toggle()]);
    expect(events, ['hide', 'fullscreen:true', 'show', 'frame:false']);
    await reader.dispose();
  });

  test(
    'failed fullscreen entry shows the window and exit attempts restoration',
    () async {
      reader = ReaderWindowController(
        hide: () async => events.add('hide'),
        show: () async => events.add('show'),
        setFullscreen: (value) async {
          events.add('fullscreen:$value');
          if (value) throw StateError('native failure');
        },
        setFrameVisible: (value) => events.add('frame:$value'),
        addCloseListener: listeners.add,
        removeCloseListener: listeners.remove,
        canPop: () => false,
        pop: () {},
        onError: (error, stack) => errors.add(error),
      );
      await reader.toggle();
      expect(errors, hasLength(1));
      expect(events, ['hide', 'fullscreen:true', 'show', 'frame:true']);
      await reader.dispose();
      expect(events.last, 'frame:true');
      expect(events.where((e) => e == 'fullscreen:false'), hasLength(1));
    },
  );
}
