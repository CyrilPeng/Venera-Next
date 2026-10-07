import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/reader/comments_controller.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/res.dart';

Comment comment(String text) =>
    Comment.fromJson({'id': text, 'userName': 'Reader', 'content': text});

void main() {
  late ImageWork work;
  late ReaderChapterCommentsController controller;
  late Future<Res<List<Comment>>> Function(int) load;
  late Future<Res<bool>> Function(String) send;
  late bool current;
  late List<Object> reports, retained;
  void Function()? changed;
  void Function(Object, StackTrace)? report;
  setUp(() {
    work = ImageWork();
    current = true;
    reports = [];
    retained = [];
    changed = null;
    report = null;
    load = (_) async => Res([], subData: 1);
    send = (_) async => const Res(true);
    controller = ReaderChapterCommentsController(
      request: ReaderChapterCommentsRequest(
        identity: Object(),
        sourceKey: 'source',
        comicTitle: 'Book',
        chapterTitle: 'Chapter',
        isCurrent: () => current,
        load: (page, _) => load(page),
        send: (text, _) => send(text),
      ),
      work: work,
      includeComment: (_) => true,
      onChanged: () => changed?.call(),
      onError: (error, stack) {
        reports.add(error);
        report?.call(error, stack);
      },
    );
  });
  tearDown(() async {
    await controller.dispose();
    if (retained.isEmpty) {
      await work.dispose();
    } else {
      await expectLater(
        work.dispose(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (failure) => failure.failures.map((item) => item.error).toList(),
            'original errors',
            retained,
          ),
        ),
      );
    }
  });

  test(
    'cancelled read drains actual completion and resume starts a new generation',
    () async {
      final pending = Completer<Res<List<Comment>>>();
      var calls = 0;
      load = (_) {
        calls++;
        return calls == 1
            ? pending.future
            : Future.value(Res([comment('New')], subData: 1));
      };
      var firstDone = false;
      final first = controller.refresh().then((_) => firstDone = true);
      await pumpEventQueue();
      final release = work.holdForExit();
      await pumpEventQueue();
      expect(firstDone, isFalse);
      release();
      await pumpEventQueue();
      expect(calls, 2);
      expect(controller.comments.single.content, 'New');
      pending.complete(Res([comment('Old')], subData: 1));
      await first;
      expect(controller.comments.single.content, 'New');
    },
  );

  test(
    'read failure is recoverable state without a pending write failure',
    () async {
      final error = StateError('read');
      load = (_) async => Res.fromException(error, StackTrace.current);
      await controller.refresh();
      expect(controller.error, same(error));
      load = (_) async => Res([comment('Restored')], subData: 1);
      await controller.refresh();
      expect(controller.error, isNull);
      expect(controller.comments.single.content, 'Restored');
      expect(reports, isEmpty);
    },
  );

  test('pagination deduplicates and refresh ignores old pages', () async {
    final pending = Completer<Res<List<Comment>>>();
    var calls = 0;
    load = (page) {
      calls++;
      return page == 1
          ? Future.value(Res([comment('First')], subData: 2))
          : pending.future;
    };
    await controller.refresh();
    final page = controller.loadMore();
    await controller.loadMore();
    expect(calls, 2);
    load = (_) async => Res([comment('New first')], subData: 1);
    await controller.refresh();
    pending.complete(Res([comment('Stale page')], subData: 2));
    await page;
    expect(controller.comments.single.content, 'New first');
    expect(controller.hasMore, isFalse);
  });

  test('successful sends run once and refresh only reads', () async {
    final pending = Completer<Res<bool>>();
    var calls = 0, reads = 0;
    send = (text) {
      expect(text, 'Draft');
      calls++;
      return pending.future;
    };
    load = (_) async {
      reads++;
      return Res([], subData: 1);
    };
    final job = controller.send('Draft');
    expect(controller.sending, isTrue);
    expect(await controller.send('Draft'), isFalse);
    pending.complete(const Res(true));
    expect(await job, isTrue);
    await pumpEventQueue();
    expect(calls, 1);
    expect(reads, 1);
    expect(controller.sending, isFalse);
  });

  for (final failed in [false, true]) {
    test('dispose retains an accepted mutation; failure=$failed', () async {
      final pending = Completer<Res<bool>>();
      send = (_) => pending.future;
      final job = controller.send('Draft');
      var closed = false;
      final closing = controller.dispose().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      final error = StateError('Original write failed');
      if (failed) {
        retained.add(error);
        pending.complete(Res.fromException(error, StackTrace.current));
      } else {
        pending.complete(const Res(true));
      }
      expect(await job, isFalse);
      await closing;
      expect(reports, isEmpty);
    });
  }

  test('retired row mutation failure belongs to original work', () async {
    final pending = Completer<Res<int?>>();
    var rowCurrent = true;
    final result = controller.mutate(
      () => pending.future,
      canPresent: () => rowCurrent,
    );
    rowCurrent = false;
    final error = StateError('row');
    retained.add(error);
    pending.completeError(error);
    expect(await result, isNull);
    expect(reports, isEmpty);
  });

  test(
    'failed reporter preserves original write error and reporting error',
    () async {
      final original = StateError('write'), reporting = StateError('report');
      retained.addAll([original, reporting]);
      send = (_) async => throw original;
      report = (_, _) => throw reporting;
      expect(await controller.send('Draft'), isFalse);
      expect(reports, [original]);
    },
  );

  test(
    'registration reentering shutdown rejects mutation before source dispatch',
    () async {
      var calls = 0;
      send = (_) async {
        calls++;
        return const Res(true);
      };
      void Function()? release;
      final detach = work.retainTasks((_) {
        release = work.holdForExit();
        return () {};
      });
      expect(await controller.send('Draft'), isFalse);
      expect(calls, 0);
      expect(controller.sending, isFalse);
      detach();
      release!();
    },
  );

  test('presentation reentry retires request before source dispatch', () async {
    var calls = 0;
    send = (_) async {
      calls++;
      return const Res(true);
    };
    changed = () => current = false;
    expect(await controller.send('Draft'), isFalse);
    expect(calls, 0);
  });
}
