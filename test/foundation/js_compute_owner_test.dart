import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/js_pool.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/app_dio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    if (!Platform.isWindows) return;
    final native = Directory('build/windows/x64/runner/Release').absolute.path;
    DynamicLibrary.open('$native/flutter_windows.dll');
    DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
  });
  setUp(() {
    final initialized = App.isInitialized;
    final muted = Log.isMuted;
    App.isInitialized = false;
    Log.isMuted = true;
    addTearDown(() {
      App.isInitialized = initialized;
      Log.isMuted = muted;
    });
  });

  Future<dynamic> compute(JsEngine owner, [String code = '() => 42']) =>
      owner.runCode(
            'sendMessage({method:"compute", function:${jsonEncode(code)}, args:[]})',
          )
          as Future<dynamic>;

  group('engine-owned compute', () {
    test(
      'independent runtimes preserve their own initialization images',
      () async {
        final first = JsEngine.create(
          loadInitScript: () async =>
              Uint8List.fromList(utf8.encode('globalThis.ownerMarker = 41;')),
        );
        final second = JsEngine.create(
          loadInitScript: () async =>
              Uint8List.fromList(utf8.encode('globalThis.ownerMarker = 73;')),
        );
        addTearDown(first.closeAndWait);
        addTearDown(second.closeAndWait);
        await Future.wait([first.init(), second.init()]);
        expect(
          await Future.wait([
            compute(first, '() => globalThis.ownerMarker'),
            compute(second, '() => globalThis.ownerMarker'),
          ]),
          [41, 73],
        );
        await first.closeAndWait();
        expect(await compute(second, '() => globalThis.ownerMarker'), 73);
      },
    );

    test(
      'worker image is captured once and cannot be changed by the loader caller',
      () async {
        final script = Uint8List.fromList(
          utf8.encode('globalThis.ownerMarker = 42;'),
        );
        var loads = 0;
        final owner = JsEngine.create(
          loadInitScript: () async {
            loads++;
            return script;
          },
        );
        addTearDown(owner.closeAndWait);
        await owner.init();
        script.fillRange(0, script.length, 32);
        expect(await compute(owner, '() => globalThis.ownerMarker'), 42);
        expect(loads, 1);
      },
    );

    test(
      'nested compute uses the same initialization image and drains every level',
      () async {
        final owner = JsEngine.create(
          loadInitScript: () async =>
              Uint8List.fromList(utf8.encode('globalThis.ownerMarker = 91;')),
        );
        addTearDown(owner.closeAndWait);
        await owner.init();
        expect(
          await compute(
            owner,
            '''async () => await sendMessage({method:'compute',
        function: "async () => { await sendMessage({method:'delay',time:20}); return globalThis.ownerMarker; }",
        args:[]})''',
          ),
          91,
        );
        await owner.closeAndWait().timeout(const Duration(seconds: 5));
      },
    );

    test('closing an unused runtime does not create a compute pool', () async {
      var created = 0;
      final owner = JsEngine.create(
        loadInitScript: () async => Uint8List(0),
        createComputeWorker: (_) {
          created++;
          return _Worker();
        },
      );
      await owner.init();
      await owner.closeAndWait();
      expect(created, 0);
      expect(() => compute(owner), throwsStateError);
    });

    test(
      'close rejects delivery but waits for actual compute and worker cleanup',
      () async {
        final entered = Completer<void>();
        final work = Completer<dynamic>();
        final cleanup = Completer<void>();
        final workers = <_Worker>[];
        final owner = JsEngine.create(
          loadInitScript: () async => Uint8List(0),
          createComputeWorker: (_) {
            final worker = _Worker(
              execute: () {
                entered.complete();
                return work.future;
              },
              close: () => cleanup.future,
            );
            workers.add(worker);
            return worker;
          },
        );
        await owner.init();
        final delivery = expectLater(compute(owner), throwsA(anything));
        await entered.future;
        var closed = false;
        final closing = owner.closeAndWait();
        expect(owner.closeAndWait(), same(closing));
        final done = closing.then((_) => closed = true);
        await delivery;
        await pumpEventQueue();
        expect(closed, isFalse);
        work.complete(42);
        await pumpEventQueue();
        expect(closed, isFalse);
        cleanup.complete();
        await done;
        expect(workers, hasLength(4));
        expect(workers.every((worker) => worker.closes == 1), isTrue);
      },
    );

    test(
      'disposing one engine does not close another engine compute workers',
      () async {
        final firstWorkers = <_Worker>[];
        final secondWorkers = <_Worker>[];
        JsEngine make(List<_Worker> workers) => JsEngine.create(
          loadInitScript: () async => Uint8List(0),
          createComputeWorker: (_) {
            final worker = _Worker();
            workers.add(worker);
            return worker;
          },
        );
        final first = make(firstWorkers);
        final second = make(secondWorkers);
        addTearDown(first.closeAndWait);
        addTearDown(second.closeAndWait);
        await Future.wait([first.init(), second.init()]);
        expect(await compute(first), 42);
        expect(await compute(second), 42);
        first.dispose();
        await first.closeAndWait();
        expect(firstWorkers.every((worker) => worker.closes == 1), isTrue);
        expect(secondWorkers.every((worker) => worker.closes == 0), isTrue);
        expect(await compute(second), 42);
      },
    );

    test(
      'partial pool startup finishes cleanup before allowing a retry',
      () async {
        var calls = 0;
        final workers = <_Worker>[];
        final cleanup = Completer<void>();
        final owner = JsEngine.create(
          loadInitScript: () async => Uint8List(0),
          createComputeWorker: (_) {
            if (++calls == 3) throw StateError('worker creation');
            final worker = _Worker(
              close: calls < 3 ? () => cleanup.future : null,
            );
            workers.add(worker);
            return worker;
          },
        );
        addTearDown(owner.closeAndWait);
        await owner.init();
        var failed = false;
        final rejected = expectLater(
          compute(owner),
          throwsA(anything),
        ).then((_) => failed = true);
        await pumpEventQueue();
        expect(workers, hasLength(2));
        expect(failed, isFalse);
        cleanup.complete();
        await rejected;
        expect(workers.every((worker) => worker.closes == 1), isTrue);
        expect(await compute(owner), 42);
        expect(workers, hasLength(6));
      },
    );

    test(
      'close during pool startup blocks admission and releases created workers',
      () async {
        final workers = <_Worker>[];
        var executions = 0;
        final owner = JsEngine.create(
          loadInitScript: () async => Uint8List(0),
          createComputeWorker: (_) {
            final worker = _Worker(
              execute: () {
                executions++;
                return 42;
              },
            );
            workers.add(worker);
            return worker;
          },
        );
        await owner.init();
        final result = expectLater(compute(owner), throwsA(anything));
        await owner.closeAndWait();
        await result;
        expect(executions, 0);
        expect(workers, hasLength(4));
        expect(workers.every((worker) => worker.closes == 1), isTrue);
      },
    );

    test(
      'synchronous HTTP close failure cannot hide asynchronous compute cleanup failure',
      () async {
        final http = StateError('HTTP close');
        final compute = StateError('compute close');
        final adapter = _FailingAdapter(http);
        final owner = JsEngine.create(
          loadInitScript: () async => Uint8List(0),
          createHttpClient: () => Dio()..httpClientAdapter = adapter,
          createComputeWorker: (_) => _Worker(close: () => throw compute),
        );
        await owner.init();
        expect(
          await owner.runCode(
            'sendMessage({method:"compute",function:"() => 42",args:[]})',
          ),
          42,
        );
        await expectLater(
          owner.closeAndWait(),
          throwsA(
            isA<JsResourceReleaseFailure>().having(
              (e) => e.failures.map((failure) => failure.error).toList(),
              'both causes',
              containsAll([same(http), same(compute)]),
            ),
          ),
        );
      },
    );

    test(
      'initialization failure waits for compute cleanup despite HTTP close failure',
      () async {
        final http = StateError('HTTP close');
        final workerFailure = StateError('compute close');
        final cleanup = Completer<void>();
        final workers = <_Worker>[];
        final owner = JsEngine.create(
          loadInitScript: () async => Uint8List.fromList(
            utf8.encode('''
sendMessage({method:'compute',function:'() => 42',args:[]}).catch(() => {});
throw new Error('initialization failed');
'''),
          ),
          createHttpClient: () =>
              Dio()..httpClientAdapter = _FailingAdapter(http),
          createComputeWorker: (_) {
            final worker = _Worker(
              close: () async {
                await cleanup.future;
                throw workerFailure;
              },
            );
            workers.add(worker);
            return worker;
          },
        );
        var settled = false;
        Object? failure;
        final initializing = owner.init().then<void>(
          (_) => settled = true,
          onError: (Object error) {
            settled = true;
            failure = error;
          },
        );
        try {
          await pumpEventQueue();
          expect(workers, hasLength(4));
          expect(settled, isFalse);
        } finally {
          cleanup.complete();
          await initializing;
          await expectLater(
            owner.closeAndWait(),
            throwsA(isA<JsResourceReleaseFailure>()),
          );
        }
        expect(
          failure,
          isA<JsEngineInitializationFailure>()
              .having(
                (e) => e.cause.toString(),
                'initialization cause',
                contains('initialization failed'),
              )
              .having(
                (e) => (e.cleanupError as JsResourceReleaseFailure).failures
                    .map((f) => f.error),
                'cleanup causes',
                containsAll([same(http), same(workerFailure)]),
              ),
        );
      },
    );

    test(
      'worker close failure is retained after all sibling cleanup finishes',
      () async {
        final failure = StateError('worker close');
        final cleanup = Completer<void>();
        var index = 0;
        final owner = JsEngine.create(
          loadInitScript: () async => Uint8List(0),
          createComputeWorker: (_) {
            final number = index++;
            return _Worker(
              close: () {
                if (number == 0) throw failure;
                return cleanup.future;
              },
            );
          },
        );
        await owner.init();
        expect(await compute(owner), 42);
        var settled = false;
        final close = owner.closeAndWait();
        final failed = expectLater(
          close,
          throwsA(
            isA<JsResourceReleaseFailure>().having(
              (e) => e.failures
                  .where((f) => f.resource == 'JS compute pool')
                  .single
                  .error,
              'original compute failure',
              same(failure),
            ),
          ),
        ).then((_) => settled = true);
        await pumpEventQueue();
        expect(settled, isFalse);
        cleanup.complete();
        await failed;
        expect(owner.closeAndWait(), same(close));
      },
    );
  }, skip: !Platform.isWindows);
}

class _Worker implements JsPoolEngine {
  _Worker({
    FutureOr<dynamic> Function()? execute,
    FutureOr<void> Function()? close,
  }) : _execute = execute,
       _close = close;
  final FutureOr<dynamic> Function()? _execute;
  final FutureOr<void> Function()? _close;
  final _pending = <Future<dynamic>>{};
  int closes = 0;
  @override
  int get pendingTasks => _pending.length;
  @override
  Future<dynamic> execute(String function, List<dynamic> args) {
    final result = Future<dynamic>.sync(() => _execute?.call() ?? 42);
    _pending.add(result);
    return result.whenComplete(() => _pending.remove(result));
  }

  @override
  Future<void> close() async {
    closes++;
    await Future.wait(
      _pending.map(
        (pending) => pending.then<void>((_) {}, onError: (Object _) {}),
      ),
    );
    await _close?.call();
  }
}

class _FailingAdapter extends Fake implements HttpClientAdapter {
  _FailingAdapter(this.failure);
  final Object failure;
  @override
  void close({bool force = false}) => throw failure;
}
