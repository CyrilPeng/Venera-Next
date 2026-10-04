import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/window_placement.dart';
import 'package:venera_next/foundation/window_placement.dart';
import 'package:venera_next/foundation/window_placement_tracker.dart';

const _first = WindowPlacement(Rect.fromLTWH(20, 30, 901, 602), false);
const _latest = WindowPlacement(Rect.fromLTWH(40, 50, 1100, 750), true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'host shares successful initialization and never samples before ready',
    () {
      return _withTimers((timers) async {
        final initialized = Completer<void>();
        var starts = 0;
        var reads = 0;
        final saved = <WindowPlacement>[];
        final host = WindowPlacementHost(
          initialize: () {
            starts++;
            return initialized.future;
          },
          read: () async {
            reads++;
            return _first;
          },
          save: (value) async => saved.add(value),
        );
        final ready = host.initialize();
        expect(identical(ready, host.initialize()), isTrue);
        final owner = host.attach()..start();
        await pumpEventQueue();
        expect(starts, 1);
        expect(reads, 0);
        expect(saved, isEmpty);
        expect(timers, isEmpty);
        initialized.complete();
        await ready;
        await pumpEventQueue();
        expect(reads, 0);
        expect(timers, hasLength(1));
        timers.single.fire();
        await pumpEventQueue();
        expect(reads, 1);
        expect(saved, [_first]);
        await owner.dispose();
        expect(timers.single.isActive, isFalse);
      });
    },
  );

  test(
    'host caches initialization failure and makes it observable to owner',
    () {
      return _withTimers((timers) async {
        final initialized = Completer<void>();
        final failure = StateError('native initialization failed');
        final errors = <Object>[];
        var starts = 0;
        final host = WindowPlacementHost(
          initialize: () {
            starts++;
            return initialized.future;
          },
          read: () async => throw StateError('must not read before ready'),
          save: (_) async => fail('must not save before ready'),
          onError: (error, stack) => errors.add(error),
        );
        final ready = host.initialize();
        final checked = expectLater(ready, throwsA(same(failure)));
        final owner = host.attach()..start();
        initialized.completeError(failure);
        await checked;
        await pumpEventQueue();
        expect(identical(ready, host.initialize()), isTrue);
        expect(starts, 1);
        expect(timers, isEmpty);
        await expectLater(
          owner.prepareForExit(),
          throwsA(isA<WindowPlacementFailure>()),
        );
        await expectLater(
          owner.dispose(),
          throwsA(isA<WindowPlacementFailure>()),
        );
        expect(errors, contains(same(failure)));
      });
    },
  );

  test('late readiness cannot restart a disposed owner', () {
    return _withTimers((timers) async {
      final initialized = Completer<void>();
      var reads = 0;
      final host = WindowPlacementHost(
        initialize: () => initialized.future,
        read: () async {
          reads++;
          return _first;
        },
        save: (_) async => fail('disposed owner wrote placement'),
      );
      final owner = host.attach()..start();
      await owner.dispose();
      initialized.complete();
      await host.initialize();
      await pumpEventQueue();
      expect(timers, isEmpty);
      expect(reads, 0);
    });
  });

  test(
    'three owners retain the oldest slow write before latest file commit',
    () {
      return _withTimers((timers) async {
        final directory = await Directory.systemTemp.createTemp(
          'placement-owners-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/window_placement');
        final writing = Completer<void>();
        final finishWrite = Completer<void>();
        var current = _first;
        var reads = 0;
        final saves = <WindowPlacement>[];
        final host = WindowPlacementHost(
          initialize: () async {},
          read: () async {
            reads++;
            return current;
          },
          save: (value) async {
            saves.add(value);
            if (saves.length == 1) {
              writing.complete();
              await finishWrite.future;
            }
            await file.writeAsString(jsonEncode(value.toJson()));
          },
        );
        await host.initialize();
        final first = host.attach()..start();
        await pumpEventQueue();
        timers.single.fire();
        await writing.future;
        final second = host.attach()..start();
        final third = host.attach()..start();
        current = _latest;
        await pumpEventQueue();
        expect(timers, hasLength(1));
        expect(reads, 1);
        expect(timers.single.isActive, isFalse);
        finishWrite.complete();
        await first.dispose();
        await second.dispose();
        await pumpEventQueue();
        expect(timers, hasLength(2));
        timers.last.fire();
        await third.prepareForExit();
        await third.dispose();
        expect(saves, [_first, _latest]);
        expect(
          WindowPlacement.fromJson(jsonDecode(await file.readAsString())),
          _latest,
        );
        expect(timers.every((timer) => !timer.isActive), isTrue);
      });
    },
  );

  test(
    'retired owner failure remains observable while replacement recovers',
    () {
      return _withTimers((timers) async {
        final failure = FileSystemException('old write failed');
        final errors = <Object>[];
        final saved = <WindowPlacement>[];
        var current = _first;
        final host = WindowPlacementHost(
          initialize: () async {},
          read: () async => current,
          save: (value) async {
            if (value == _first) throw failure;
            saved.add(value);
          },
          onError: (error, stack) => errors.add(error),
        );
        await host.initialize();
        final first = host.attach()..start();
        await pumpEventQueue();
        timers.single.fire();
        await pumpEventQueue();
        current = _latest;
        final second = host.attach()..start();
        await expectLater(
          first.dispose(),
          throwsA(
            isA<WindowPlacementFailure>().having(
              (error) => error.failures.map((entry) => entry.error),
              'write cause',
              contains(same(failure)),
            ),
          ),
        );
        await pumpEventQueue();
        expect(errors, contains(same(failure)));
        expect(timers, hasLength(2));
        final release = await second.prepareForExit();
        expect(saved, [_latest]);
        release();
        await second.dispose();
      });
    },
  );

  for (final platform in [
    (name: 'Windows', linux: false, macos: false),
    (name: 'Linux', linux: true, macos: false),
    (name: 'macOS', linux: false, macos: true),
  ]) {
    test(
      '${platform.name} restores old JSON before polling and writes real file',
      () {
        return _withTimers((timers) async {
          final directory = await Directory.systemTemp.createTemp(
            'placement-platform-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final file = File('${directory.path}/window_placement');
          await file.writeAsString(
            '{"width":901,"height":602,"x":20,"y":30,"isMaximized":true}',
          );
          final calls = <MethodCall>[];
          _mockWindow((call) async {
            calls.add(call);
            return switch (call.method) {
              'isFullScreen' => false,
              'isMinimized' => false,
              'isMaximized' => false,
              'getBounds' => <String, double>{
                'x': 60,
                'y': 70,
                'width': 920,
                'height': 680,
              },
              _ => null,
            };
          });
          final host = WindowPlacementHost.platform(
            dataPath: directory.path,
            linux: platform.linux,
            macos: platform.macos,
          );
          final owner = host.attach()..start();
          await host.initialize();
          await pumpEventQueue();
          final methods = calls.map((call) => call.method).toList();
          expect(methods.take(3), [
            'ensureInitialized',
            'setPreventClose',
            'waitUntilReadyToShow',
          ]);
          expect(
            methods,
            containsAllInOrder(['setTitleBarStyle', 'setMinimumSize']),
          );
          expect(
            methods,
            containsAllInOrder(
              platform.linux
                  ? ['show', 'setBounds', 'maximize']
                  : ['setBounds', 'maximize', 'show'],
            ),
          );
          expect(methods.contains('setBackgroundColor'), platform.linux);
          expect(
            calls
                .singleWhere((call) => call.method == 'setTitleBarStyle')
                .arguments,
            containsPair('windowButtonVisibility', platform.macos),
          );
          expect(
            calls.singleWhere((call) => call.method == 'setBounds').arguments,
            allOf(containsPair('x', 20.0), containsPair('width', 901.0)),
          );
          expect(methods, isNot(contains('getBounds')));
          final release = await owner.prepareForExit();
          expect(
            WindowPlacement.fromJson(jsonDecode(await file.readAsString())),
            const WindowPlacement(Rect.fromLTWH(60, 70, 920, 680), false),
          );
          expect(
            calls.map((call) => call.method),
            containsAllInOrder([
              'isMinimized',
              'getBounds',
              'isMaximized',
              'isMinimized',
            ]),
          );
          release();
          await owner.dispose();
        });
      },
    );
  }

  for (final midway in [false, true]) {
    test(
      'minimized snapshot preserves saved maximized placement; midway=$midway',
      () {
        return _withTimers((timers) async {
          final directory = await Directory.systemTemp.createTemp(
            'placement-minimized-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final file = File('${directory.path}/window_placement');
          final original = jsonEncode(_latest.toJson());
          await file.writeAsString(original);
          var sampling = false;
          var minimizedChecks = 0;
          var boundsReads = 0;
          _mockWindow((call) async {
            return switch (call.method) {
              'isFullScreen' || 'isMaximized' => false,
              'isMinimized' => sampling && (!midway || ++minimizedChecks == 2),
              'getBounds' => () {
                boundsReads++;
                return <String, double>{
                  'x': 0,
                  'y': 0,
                  'width': 700,
                  'height': 600,
                };
              }(),
              _ => null,
            };
          });
          final host = WindowPlacementHost.platform(
            dataPath: directory.path,
            linux: false,
            macos: false,
          );
          final owner = host.attach()..start();
          await host.initialize();
          await pumpEventQueue();
          sampling = true;
          final release = await owner.prepareForExit();
          expect(await file.readAsString(), original);
          expect(boundsReads, midway ? 1 : 0);
          release();
          await owner.dispose();
        });
      },
    );
  }

  for (final contents in <String?>[null, '{invalid', '{"x":"invalid"}']) {
    test(
      'missing or invalid old placement uses the established default: $contents',
      () {
        return _withTimers((timers) async {
          final directory = await Directory.systemTemp.createTemp(
            'placement-default-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final file = File('${directory.path}/window_placement');
          if (contents != null) await file.writeAsString(contents);
          final calls = <MethodCall>[];
          _mockWindow((call) async {
            calls.add(call);
            return switch (call.method) {
              'isFullScreen' || 'isMaximized' || 'isMinimized' => false,
              _ => null,
            };
          });
          final host = WindowPlacementHost.platform(
            dataPath: directory.path,
            linux: false,
            macos: false,
          );
          final owner = host.attach()..start();
          await host.initialize();
          final bounds = calls
              .singleWhere((call) => call.method == 'setBounds')
              .arguments;
          expect(
            bounds,
            allOf(
              containsPair('x', 10.0),
              containsPair('y', 10.0),
              containsPair('width', 900.0),
              containsPair('height', 600.0),
            ),
          );
          expect(calls.map((call) => call.method), isNot(contains('maximize')));
          await owner.dispose();
        });
      },
    );
  }

  test('platform readiness includes awaited native show completion', () {
    return _withTimers((timers) async {
      final directory = await Directory.systemTemp.createTemp(
        'placement-show-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final showing = Completer<void>();
      final shown = Completer<void>();
      var reads = 0;
      _mockWindow((call) async {
        if (call.method == 'show') {
          showing.complete();
          await shown.future;
        }
        if (call.method == 'getBounds') reads++;
        return switch (call.method) {
          'isFullScreen' || 'isMaximized' || 'isMinimized' => false,
          'getBounds' => <String, double>{
            'x': 10,
            'y': 20,
            'width': 900,
            'height': 600,
          },
          _ => null,
        };
      });
      final host = WindowPlacementHost.platform(
        dataPath: directory.path,
        linux: false,
        macos: false,
      );
      final owner = host.attach()..start();
      final ready = host.initialize();
      await showing.future;
      await pumpEventQueue();
      expect(timers, isEmpty);
      expect(reads, 0);
      shown.complete();
      await ready;
      await pumpEventQueue();
      expect(timers, hasLength(1));
      await owner.prepareForExit();
      expect(reads, 1);
      await owner.dispose();
    });
  });

  test(
    'late valid snapshot survives two handoffs before invalid native bounds',
    () {
      return _withTimers((timers) async {
        final firstRead = Completer<WindowPlacement>();
        final writing = Completer<void>();
        final finishWrite = Completer<void>();
        final saved = <WindowPlacement>[];
        var reads = 0;
        final host = WindowPlacementHost(
          initialize: () async {},
          read: () {
            reads++;
            return reads == 1
                ? firstRead.future
                : Future.value(
                    const WindowPlacement(
                      Rect.fromLTWH(-32000, -32000, 120, 150),
                      true,
                    ),
                  );
          },
          save: (value) async {
            if (saved.isEmpty) {
              writing.complete();
              await finishWrite.future;
            }
            saved.add(value);
          },
        );
        await host.initialize();
        final first = host.attach()..start();
        await pumpEventQueue();
        timers.single.fire();
        final second = host.attach()..start();
        final third = host.attach()..start();
        await pumpEventQueue();
        expect(reads, 1);
        firstRead.complete(_first);
        await writing.future;
        expect(timers, hasLength(1));
        expect(reads, 1);
        finishWrite.complete();
        await first.dispose();
        await second.dispose();
        await pumpEventQueue();
        await third.prepareForExit();
        expect(saved, [_first, WindowPlacement(_first.rect, true)]);
        await third.dispose();
      });
    },
  );

  test('replacement cannot accept a partial old write while minimized', () {
    return _withTimers((timers) async {
      final directory = await Directory.systemTemp.createTemp(
        'placement-partial-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/window_placement');
      await file.writeAsString(jsonEncode(_first.toJson()));
      final failure = FileSystemException('write interrupted', file.path);
      final reported = <Object>[];
      final written = <WindowPlacement>[];
      WindowPlacement? current = _latest;
      var failWrite = true;
      final host = WindowPlacementHost(
        initialize: () async {},
        read: () async => current,
        save: (value) async {
          written.add(value);
          if (failWrite) {
            await file.writeAsString('{"width":');
            throw failure;
          }
          await file.writeAsString(jsonEncode(value.toJson()));
        },
        onError: (error, stack) => reported.add(error),
      );
      await host.initialize();
      final first = host.attach()..start();
      await pumpEventQueue();
      timers.single.fire();
      final failed = isA<WindowPlacementFailure>().having(
        (error) => error.failures.map((item) => item.error),
        'original partial write failure',
        contains(same(failure)),
      );
      await expectLater(first.dispose(), throwsA(failed));
      expect(await file.readAsString(), '{"width":');

      current = null;
      final replacement = host.attach()..start();
      await pumpEventQueue();
      expect(reported, contains(failed));
      // Merely transferring ownership or failing to sample a minimized window
      // cannot establish that the truncated file contains a complete snapshot.
      await expectLater(replacement.prepareForExit(), throwsA(failed));
      await expectLater(replacement.prepareForExit(), throwsA(failed));
      expect(written, [_latest]);
      expect(await file.readAsString(), '{"width":');

      failWrite = false;
      current = _first;
      final release = await replacement.prepareForExit();
      expect(written, [_latest, _first]);
      expect(
        WindowPlacement.fromJson(jsonDecode(await file.readAsString())),
        _first,
      );
      release();
      current = null;
      await replacement.prepareForExit();
      expect(written, [_latest, _first]);
      await replacement.dispose();
    });
  });
}

void _mockWindow(Future<Object?> Function(MethodCall) handler) {
  const channel = MethodChannel('window_manager');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, handler);
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}

Future<void> _withTimers(Future<void> Function(List<_PeriodicTimer>) action) {
  final timers = <_PeriodicTimer>[];
  return runZoned(
    () => action(timers),
    zoneSpecification: ZoneSpecification(
      createPeriodicTimer: (self, parent, zone, duration, callback) {
        expect(duration, const Duration(milliseconds: 100));
        final timer = _PeriodicTimer(callback);
        timers.add(timer);
        return timer;
      },
    ),
  );
}

class _PeriodicTimer implements Timer {
  _PeriodicTimer(this.callback);
  final void Function(Timer) callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  void fire() {
    tick++;
    callback(this);
  }

  @override
  void cancel() => isActive = false;
}
