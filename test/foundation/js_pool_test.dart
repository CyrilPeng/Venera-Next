import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/js_pool.dart';

void main() {
  test(
    'init shares concurrent initialization and does not duplicate engines',
    () async {
      var loadCount = 0;
      var createCount = 0;
      var closeCount = 0;
      final loadStarted = Completer<void>();
      final allowLoad = Completer<void>();

      final pool = JSPool.create(
        loadJsInit: () async {
          loadCount++;
          if (!loadStarted.isCompleted) {
            loadStarted.complete();
          }
          await allowLoad.future;
          return Uint8List(0);
        },
        createEngine: (_) {
          createCount++;
          return _FakeJsPoolEngine(onClose: () => closeCount++);
        },
      );
      addTearDown(pool.close);
      final firstInit = pool.init();
      await loadStarted.future;
      final secondInit = pool.init();
      final thirdInit = pool.init();

      await pumpEventQueue();
      expect(loadCount, 1);

      allowLoad.complete();
      await Future.wait([firstInit, secondInit, thirdInit]);

      expect(createCount, 4);

      await pool.init();
      expect(loadCount, 1);
      expect(createCount, 4);

      await pool.close();
      expect(closeCount, 4);
    },
  );

  test('execute selects the engine with the fewest pending tasks', () async {
    final engines = [
      _FakeJsPoolEngine(name: 'busy', pendingTasks: 3),
      _FakeJsPoolEngine(name: 'idle', pendingTasks: 0),
      _FakeJsPoolEngine(name: 'middle', pendingTasks: 2),
      _FakeJsPoolEngine(name: 'light', pendingTasks: 1),
    ];
    var createIndex = 0;

    final pool = JSPool.create(
      loadJsInit: () async => Uint8List(0),
      createEngine: (_) => engines[createIndex++],
    );
    addTearDown(pool.close);

    final result = await pool.execute('() => null', const []);

    expect(result, 'idle');
    expect(engines[1].executeCount, 1);
    expect(engines.where((engine) => engine.executeCount == 0), hasLength(3));
  });

  test(
    'close joins initialization and rejects waiting and new tasks',
    () async {
      final loaded = Completer<Uint8List>();
      final engines = <_FakeJsPoolEngine>[];
      final pool = JSPool.create(
        loadJsInit: () => loaded.future,
        createEngine: (_) {
          final engine = _FakeJsPoolEngine();
          engines.add(engine);
          return engine;
        },
      );
      addTearDown(pool.close);
      final task = pool.execute('() => null', []);
      final rejected = expectLater(task, throwsStateError);
      final closing = pool.close();
      expect(pool.close(), same(closing));
      await expectLater(pool.init(), throwsStateError);
      await expectLater(pool.execute('() => null', []), throwsStateError);
      loaded.complete(Uint8List(0));
      await closing;
      await rejected;
      expect(engines, hasLength(4));
      expect(
        engines.every((e) => e.closeCount == 1 && e.executeCount == 0),
        isTrue,
      );
      expect(await pool.execute('() => null', []), 'engine');
      expect(engines, hasLength(8));
    },
  );

  test(
    'close waits for all engines despite synchronous close failure',
    () async {
      final gate = Completer<void>();
      var index = 0;
      final engines = <_FakeJsPoolEngine>[];
      final failure = StateError('close failed');
      var failClose = true;
      final pool = JSPool.create(
        loadJsInit: () async => Uint8List(0),
        createEngine: (_) {
          final i = index++;
          final engine = _FakeJsPoolEngine(
            onClose: () {
              if (i == 0 && failClose) throw failure;
              if (i == 1) return gate.future;
            },
          );
          engines.add(engine);
          return engine;
        },
      );
      addTearDown(pool.close);
      await pool.init();
      var done = false;
      final close = pool.close();
      final checked = expectLater(
        close,
        throwsA(same(failure)),
      ).then((_) => done = true);
      await pumpEventQueue();
      expect(done, isFalse);
      expect(engines.every((e) => e.closeCount == 1), isTrue);
      expect(pool.close(), same(close));
      await expectLater(pool.execute('() => null', []), throwsStateError);
      gate.complete();
      await checked;
      await expectLater(pool.execute('() => null', []), throwsStateError);
      failClose = false;
      await pool.close();
      expect(engines.first.closeCount, 2);
      expect(engines.skip(1).every((e) => e.closeCount == 1), isTrue);
      expect(await pool.execute('() => null', []), 'engine');
    },
  );

  test(
    'partial creation rolls back before retry and preserves cleanup errors',
    () async {
      final gate = Completer<void>();
      final startupError = StateError('factory failed');
      final closeError = StateError('cleanup failed');
      var failClose = true;
      final engines = <_FakeJsPoolEngine>[];
      var attempts = 0;
      final pool = JSPool.create(
        loadJsInit: () async => Uint8List(0),
        createEngine: (_) {
          final index = attempts++;
          if (index == 2) throw startupError;
          final engine = _FakeJsPoolEngine(
            onClose: () {
              if (index == 0 && failClose) throw closeError;
              if (index == 1) return gate.future;
            },
          );
          engines.add(engine);
          return engine;
        },
      );
      addTearDown(pool.close);
      final starting = pool.init();
      final checked = expectLater(
        starting,
        throwsA(
          isA<JsPoolInitializationFailure>()
              .having((e) => e.cause, 'cause', same(startupError))
              .having((e) => e.cleanupErrors, 'cleanup', [closeError]),
        ),
      );
      await pumpEventQueue();
      expect(pool.init(), same(starting));
      expect(engines.every((e) => e.closeCount == 1), isTrue);
      gate.complete();
      await checked;
      await expectLater(pool.init(), throwsStateError);
      failClose = false;
      await pool.close();
      expect(engines.first.closeCount, 2);
      expect(engines[1].closeCount, 1);
      expect(await pool.execute('() => null', []), 'engine');
      expect(engines, hasLength(6));
    },
  );
}

class _FakeJsPoolEngine implements JsPoolEngine {
  _FakeJsPoolEngine({
    this.name = 'engine',
    this.pendingTasks = 0,
    this.onClose,
  });

  final String name;

  @override
  int pendingTasks;

  final FutureOr<void> Function()? onClose;

  int executeCount = 0;
  int closeCount = 0;

  @override
  Future<dynamic> execute(String jsFunction, List<dynamic> args) async {
    executeCount++;
    return name;
  }

  @override
  Future<void> close() {
    closeCount++;
    final result = onClose?.call();
    return result is Future<void> ? result : Future.value();
  }
}
