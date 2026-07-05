import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/js_pool.dart';

void main() {
  setUp(() async {
    await JSPool.resetForTesting();
  });

  tearDown(() async {
    await JSPool.resetForTesting();
  });

  test(
    'init shares concurrent initialization and does not duplicate engines',
    () async {
      var loadCount = 0;
      var createCount = 0;
      var closeCount = 0;
      final loadStarted = Completer<void>();
      final allowLoad = Completer<void>();

      JSPool.debugLoadJsInit = () async {
        loadCount++;
        if (!loadStarted.isCompleted) {
          loadStarted.complete();
        }
        await allowLoad.future;
        return Uint8List(0);
      };
      JSPool.debugCreateEngine = (_) {
        createCount++;
        return _FakeJsPoolEngine(onClose: () => closeCount++);
      };

      final pool = JSPool();
      final firstInit = pool.init();
      await loadStarted.future;
      final secondInit = pool.init();
      final thirdInit = pool.init();

      await pumpEventQueue();
      expect(loadCount, 1);

      allowLoad.complete();
      await Future.wait([firstInit, secondInit, thirdInit]);

      expect(createCount, 4);
      expect(pool.debugInstanceCount, 4);

      await pool.init();
      expect(loadCount, 1);
      expect(createCount, 4);

      await JSPool.resetForTesting();
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

    JSPool.debugLoadJsInit = () async => Uint8List(0);
    JSPool.debugCreateEngine = (_) => engines[createIndex++];

    final result = await JSPool().execute('() => null', const []);

    expect(result, 'idle');
    expect(engines[1].executeCount, 1);
    expect(engines.where((engine) => engine.executeCount == 0), hasLength(3));
  });
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

  final void Function()? onClose;

  int executeCount = 0;

  @override
  Future<dynamic> execute(String jsFunction, List<dynamic> args) async {
    executeCount++;
    return name;
  }

  @override
  Future<void> close() async {
    onClose?.call();
  }
}
