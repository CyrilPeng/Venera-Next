import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/android_downloads.dart';
import 'package:venera_next/features/local_comics/download_task.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('venera/downloads');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final owners = <AndroidDownloads>[];
  late Directory root;
  late LocalManager manager;
  late _Task first;

  AndroidDownloads attach() {
    final owner = AndroidDownloads(manager: manager, channel: channel);
    owners.add(owner);
    owner.start();
    return owner;
  }

  Iterable<MethodCall> methods(String name) =>
      calls.where((call) => call.method == name);
  Map<dynamic, dynamic> args(MethodCall call) => call.arguments as Map;

  Future<void> event(String method, Map<dynamic, dynamic> arguments) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) => done.complete(),
    );
    await done.future;
    await pumpEventQueue();
  }

  setUp(() {
    LocalManager.current?.dispose();
    root = Directory.systemTemp.createTempSync('android-downloads-');
    App.dataPath = root.path;
    manager = LocalManager();
    first = _Task('first');
    manager.restorePausedDownloads([first]);
    calls.clear();
    owners.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'start' ? true : null;
    });
  });

  tearDown(() async {
    for (final owner in owners) {
      await owner.close();
    }
    await manager.pendingDownloadTaskWrites;
    manager.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    root.deleteSync(recursive: true);
  });

  test(
    'missing-page tasks do not own foreground execution or block the next task',
    () async {
      final missing = _Task('missing')..awaitingMissing = true;
      manager.restorePausedDownloads([missing, first]);
      attach();
      await pumpEventQueue();
      expect(methods('start'), isEmpty);
      expect(missing.listeners, 0);
      expect(first.listeners, 1);
      manager.resumeDownload(first);
      await pumpEventQueue();
      expect(methods('start'), hasLength(1));
      expect(missing.resumes, 0);
      await manager.pauseDownload(first);
      await pumpEventQueue();
      expect(methods('stop'), hasLength(1));
    },
  );

  test(
    'restored tasks stay paused; active queue owns one foreground session',
    () async {
      final owner = attach();
      await pumpEventQueue();
      expect(calls.map((call) => call.method), ['bind']);
      manager.resumeDownload(first);
      await pumpEventQueue();
      expect(methods('start'), hasLength(1));
      first.amount = 0.45;
      first.waiting = true;
      first.emit();
      await pumpEventQueue();
      expect(args(methods('update').last)['progress'], 450);
      expect(args(methods('update').last)['waiting'], isTrue);
      expect(args(methods('update').last).containsKey('title'), isFalse);
      owner.didChangeAppLifecycleState(AppLifecycleState.paused);
      await pumpEventQueue();
      expect(methods('stop'), isEmpty);
      final start = args(methods('start').single);
      await event('networkAvailable', {'owner': start['owner']});
      expect(first.wakes, 1);
      await manager.pauseDownload(first);
      await pumpEventQueue();
      expect(methods('stop'), hasLength(1));
      owner.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await event('networkAvailable', {'owner': start['owner']});
      expect(first.resumes, 1);
      expect(first.wakes, 1);
      expect(methods('start'), hasLength(1));
    },
  );

  test(
    'advancing the queue in the background does not restart the service',
    () async {
      final second = _Task('second');
      manager.restorePausedDownloads([first, second]);
      final owner = attach();
      manager.resumeDownload(first);
      await pumpEventQueue();
      final token = args(methods('start').single)['session'];
      owner.didChangeAppLifecycleState(AppLifecycleState.paused);
      manager.removeTask(first);
      manager.resumeDownload(second);
      await pumpEventQueue();
      expect(methods('start'), hasLength(1));
      expect(methods('stop'), isEmpty);
      expect(args(methods('update').last)['session'], token);
      expect(first.listeners, 0);
      expect(second.listeners, 1);
      manager.removeTask(second);
      await pumpEventQueue();
      expect(methods('stop'), hasLength(1));
      expect(second.listeners, 0);
    },
  );

  for (final reason in [
    'notification_pause',
    'system_timeout',
    'task_removed',
    'heartbeat_timeout',
  ]) {
    test(
      '$reason pauses and persists without reviving on foreground/network',
      () async {
        final owner = attach();
        manager.resumeDownload(first);
        await pumpEventQueue();
        final start = args(methods('start').single);
        await event('stopped', {...start, 'session': 0, 'reason': reason});
        expect(first.isPaused, isFalse);
        await event('stopped', {...start, 'reason': reason});
        expect(first.isPaused, isTrue);
        expect(
          File('${root.path}/downloading_tasks.json').existsSync(),
          isTrue,
        );
        owner.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await event('networkAvailable', start);
        expect(first.resumes, 1);
        expect(first.wakes, 0);
        expect(methods('start'), hasLength(1));
      },
    );
  }

  test(
    'early native stop cannot turn a late start ack into a live replacement lease',
    () async {
      final gate = Completer<bool>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'start' && methods('start').length == 1) {
          return gate.future;
        }
        return call.method == 'start' ? true : null;
      });
      attach();
      manager.resumeDownload(first);
      await pumpEventQueue();
      final oldStart = args(methods('start').single);
      await event('stopped', {...oldStart, 'reason': 'foreground_error'});
      expect(first.isPaused, isTrue);
      manager.resumeDownload(first);
      gate.complete(true);
      await pumpEventQueue();
      expect(methods('start'), hasLength(2));
      expect(
        args(methods('start').last)['session'],
        isNot(oldStart['session']),
      );
      expect(args(methods('stop').single)['session'], oldStart['session']);
      expect(first.isPaused, isFalse);
    },
  );

  test(
    'refused start is not retried every progress tick or in background',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'start' ? false : null;
      });
      final owner = attach();
      manager.resumeDownload(first);
      await pumpEventQueue();
      for (var i = 0; i < 3; i++) {
        first.emit();
        await pumpEventQueue();
      }
      owner.didChangeAppLifecycleState(AppLifecycleState.paused);
      await pumpEventQueue();
      expect(methods('start'), hasLength(1));
      final old = args(methods('start').single)['session'];
      owner.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(methods('start'), hasLength(2));
      expect(args(methods('start').last)['session'], isNot(old));
    },
  );

  test(
    'close drains a pending start and late old close leaves new handler intact',
    () async {
      final gate = Completer<bool>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'start' && methods('start').length == 1) {
          return gate.future;
        }
        return call.method == 'start' ? true : null;
      });
      final old = attach();
      manager.resumeDownload(first);
      await pumpEventQueue();
      final oldStart = args(methods('start').single);
      final closing = old.close();
      expect(identical(closing, old.close()), isTrue);
      var closed = false;
      unawaited(closing.then((_) => closed = true));
      attach();
      await pumpEventQueue();
      final currentStart = args(methods('start').last);
      expect(currentStart['owner'], isNot(oldStart['owner']));
      expect(closed, isFalse);
      gate.complete(true);
      await closing;
      expect(args(methods('dispose').single)['owner'], oldStart['owner']);
      await event('stopped', {...oldStart, 'reason': 'system_timeout'});
      expect(first.isPaused, isFalse);
      await event('stopped', {...currentStart, 'reason': 'notification_pause'});
      expect(first.isPaused, isTrue);
      expect(first.listeners, 1);
    },
  );
}

class _Task extends DownloadTask {
  _Task(this.id);
  @override
  final String id;
  int listeners = 0;
  int resumes = 0;
  int wakes = 0;
  bool paused = true;
  bool awaitingMissing = false;
  @override
  bool get isAwaitingMissingPages => awaitingMissing;
  bool waiting = false;
  double amount = 0;
  void emit() => notifyListeners();
  @override
  void addListener(VoidCallback listener) {
    listeners++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners--;
    super.removeListener(listener);
  }

  @override
  bool get isPaused => paused;
  @override
  bool get isError => false;
  @override
  bool get isWaitingToRetry => !paused && waiting;
  @override
  void retryNow() {
    if (isWaitingToRetry) wakes++;
  }

  @override
  void resume() {
    paused = false;
    resumes++;
    emit();
  }

  @override
  void pause() {
    paused = true;
    emit();
  }

  @override
  void cancel() => pause();
  @override
  Future<void> get pendingCleanup => Future.value();
  @override
  ComicType get comicType => const ComicType(17);
  @override
  String get title => 'Private comic title';
  @override
  String? get cover => null;
  @override
  String get message => 'Downloading';
  @override
  int get speed => 0;
  @override
  double get progress => amount;
  @override
  Map<String, dynamic> toJson() => {'id': id};
  @override
  LocalComic toLocalComic() => throw UnsupportedError('fixture');
}
