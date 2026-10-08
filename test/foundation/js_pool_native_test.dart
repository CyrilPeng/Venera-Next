import 'dart:ffi';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/js_pool.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    if (!Platform.isWindows) return;
    final native = Directory('build/windows/x64/runner/Release').absolute.path;
    DynamicLibrary.open('$native/flutter_windows.dll');
    DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
  });
  test(
    'failed native worker initialization finishes cleanup before exit',
    () async {
      final engine = IsolateJsEngine(
        Uint8List.fromList(
          utf8.encode('throw new Error("worker startup failed");'),
        ),
        entryPoint: runJsComputeWorker,
      );
      await expectLater(
        engine.execute('() => 1', []),
        throwsA(
          predicate(
            (error) => error.toString().contains('worker startup failed'),
          ),
        ),
      );
      await engine.close().timeout(const Duration(seconds: 5));
      expect(engine.pendingTasks, 0);
    },
    skip: !Platform.isWindows,
  );
  test('native pool executes across close and reopen', () async {
    final native = Directory('build/windows/x64/runner/Release').absolute.path;
    DynamicLibrary.open('$native/flutter_windows.dll');
    DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
    final pool = JSPool.create(
      loadJsInit: () async => Uint8List(0),
      createEngine: (script) =>
          IsolateJsEngine(script, entryPoint: runJsComputeWorker),
    );
    addTearDown(pool.close);
    expect(await pool.execute('(a, b) => a + b', [20, 22]), 42);
    final closing = pool.close();
    expect(pool.close(), same(closing));
    await closing;
    expect(await pool.execute('(a) => a * 2', [21]), 42);
    await pool.close();
  }, skip: !Platform.isWindows);

  test(
    'async compute resolves and close joins accepted work',
    () async {
      final engine = IsolateJsEngine(
        Uint8List(0),
        entryPoint: runJsComputeWorker,
      );
      addTearDown(engine.close);
      expect(await engine.execute('() => 1', []), 1);
      final result = engine.execute('''async () => {
      await sendMessage({method: 'delay', time: 200});
      return {answer: 42};
    }''', []);
      await Future<void>.delayed(Duration.zero);
      expect(engine.pendingTasks, 1);
      final closing = engine.close();
      expect(engine.close(), same(closing));
      await expectLater(engine.execute('() => 2', []), throwsException);
      expect(await result, {'answer': 42});
      await closing;
      expect(engine.pendingTasks, 0);
    },
    skip: !Platform.isWindows,
  );

  test('sync and async failures leave the worker usable', () async {
    final engine = IsolateJsEngine(
      Uint8List(0),
      entryPoint: runJsComputeWorker,
    );
    addTearDown(engine.close);
    for (final (code, message) in [
      ('() => { throw new Error("sync failure"); }', 'sync failure'),
      (
        'async () => { await Promise.resolve(); throw new Error("async failure"); }',
        'async failure',
      ),
      ('() => () => 42', 'cannot transfer native'),
      ('async () => ({nested: [() => 42]})', 'cannot transfer native'),
      ('({nested: () => 42})', 'does not evaluate to a function'),
    ]) {
      await expectLater(engine.execute(code, []), throwsA(contains(message)));
      expect(engine.pendingTasks, 0);
      expect(await engine.execute('async () => 73', []), 73);
    }
    expect(
      await engine.execute('async () => new Uint8Array([1, 2, 3]).buffer', []),
      [1, 2, 3],
    );
  }, skip: !Platform.isWindows);

  test(
    'native callback arguments stay in their owning isolate',
    () async {
      App.version = 'test';
      App.isInitialized = false;
      final owner = JsEngine.create(loadInitScript: () async => Uint8List(0));
      await owner.init();
      final engine = IsolateJsEngine(
        Uint8List(0),
        entryPoint: runJsComputeWorker,
      );
      final function = owner.runCode('() => 42') as JSInvokable;
      try {
        await expectLater(
          engine.execute('(x) => x', [
            {
              'nested': [function],
            },
          ]),
          throwsStateError,
        );
        expect(engine.pendingTasks, 0);
        expect(function.invoke([]), 42);
        expect(await engine.execute('() => 73', []), 73);
      } finally {
        await engine.close();
        function.free();
        owner.dispose();
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'unsendable arguments release task admission before close',
    () async {
      final engine = IsolateJsEngine(
        Uint8List(0),
        entryPoint: runJsComputeWorker,
      );
      final port = ReceivePort();
      addTearDown(port.close);
      addTearDown(engine.close);
      await expectLater(
        engine.execute('(a) => a', [port]),
        throwsArgumentError,
      );
      expect(engine.pendingTasks, 0);
      expect(await engine.execute('() => 42', []), 42);
      await engine.close().timeout(const Duration(seconds: 3));
    },
    skip: !Platform.isWindows,
  );

  test(
    'close before spawn completion joins its late handle',
    () async {
      final engine = IsolateJsEngine(
        Uint8List(0),
        entryPoint: runJsComputeWorker,
      );
      final closing = engine.close();
      expect(engine.close(), same(closing));
      await closing.timeout(const Duration(seconds: 3));
      await expectLater(engine.execute('() => 1', []), throwsException);
    },
    skip: !Platform.isWindows,
  );
}
