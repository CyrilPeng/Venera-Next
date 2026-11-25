import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/display_image_provider.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/reader_diagnostics.dart';

FrameTiming _frame(int ui, int raster, {int start = 0}) => FrameTiming(
  vsyncStart: start,
  buildStart: start + 100,
  buildFinish: start + 100 + ui,
  rasterStart: start + 100 + ui,
  rasterFinish: start + 100 + ui + raster,
  rasterFinishWallTime: start + 100 + ui + raster,
);

Future<void> _drawFrame() async {
  SchedulerBinding.instance.handleBeginFrame(Duration.zero);
  SchedulerBinding.instance.handleDrawFrame();
  await pumpEventQueue();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ReaderDiagnostics diagnostics;
  late int now, attaches, detaches, clockReads;
  TimingsCallback? frames;
  void start({String version = '1.18.2-rc.4+240'}) => diagnostics.start(
    mode: ReaderDiagnosticMode.continuous,
    processingEnabled: false,
    appVersion: version,
    refreshRate: 120,
  );
  Map<String, dynamic> report() =>
      jsonDecode(diagnostics.exportJson()) as Map<String, dynamic>;
  setUp(() {
    now = attaches = detaches = clockReads = 0;
    frames = null;
    diagnostics = ReaderDiagnostics(
      nowMicros: () {
        clockReads++;
        return now;
      },
      attachTimings: (callback) {
        attaches++;
        frames = callback;
      },
      detachTimings: (callback) {
        expectSync(callback, frames);
        detaches++;
      },
    );
  });
  tearDown(() => diagnostics.dispose());

  test('batched frame receipt retains distinct engine timestamps', () {
    now = 100000;
    start();
    now = 1100000;
    frames!([
      _frame(1000, 1000, start: 100500),
      _frame(10000, 1000, start: 200500),
    ]);
    diagnostics.stop(ReaderDiagnosticStop.review);
    final data = report();
    final summary = data['retainedFrameSamples'] as Map;
    expect(data['schema'], 3);
    expect(summary['ui']['count'], 2);
    expect(summary['slowest'], [
      [1000000, 10000, 1000, 11100, 100500, 100600],
    ]);
    expect(data['frameSamples'], [
      [1000000, 1000, 1000, 2100, 500, 600],
      [1000000, 10000, 1000, 11100, 100500, 100600],
    ]);
    expect(data['retainedFrameCount'], 2);
    expect(data['omittedFrameSamplesForCopy'], 0);
    expect(summary['slowestColumns'], [
      'receivedAtUs',
      'uiUs',
      'rasterUs',
      'totalSpanUs',
      'vsyncStartUs',
      'buildStartUs',
    ]);
    expect(data['frameSampleColumns'], summary['slowestColumns']);
  });

  test('disabled capture registers no callbacks and reads no clock', () {
    expect(
      diagnostics.beginImageSpan(42, ReaderDiagnosticStage.localRead),
      isNull,
    );
    diagnostics.recordCache(42, pending: false, keepAlive: false, live: false);
    diagnostics.recordNavigation(
      ReaderDiagnosticNavigation.volumeNext,
      page: 1,
    );
    expect(
      diagnostics.beginPageTurn(page: 1, targetPage: 2, chapter: 1),
      isNull,
    );
    expect(diagnostics.hasCapture, isFalse);
    expect(attaches, 0);
    expect(detaches, 0);
    expect(clockReads, 0);
  });

  test(
    'spans use session-local image numbers and elapsed waits, not private keys',
    () {
      start();
      final span = diagnostics.beginImageSpan(
        987654321,
        ReaderDiagnosticStage.localRead,
      )!;
      now = 2300;
      span.finish(bytes: 512);
      span.finish(bytes: 999);
      diagnostics.recordCache(
        987654321,
        pending: false,
        keepAlive: true,
        live: true,
      );
      frames!([_frame(6000, 6000), _frame(9000, 1000)]);
      diagnostics.stop(ReaderDiagnosticStop.review);
      final data = report();
      final events = data['imageEvents'] as List;
      expect(events, hasLength(2));
      expect(events[0]['image'], 1);
      expect(events[0]['waitUs'], 2300);
      expect(events[0]['bytes'], 512);
      expect(events[1]['image'], 1);
      expect(data['retainedFrameSamples']['overBudget'], 1);
      expect(data['retainedFrameSamples']['frameBudgetUs'], 8333);
      expect(data['configuration']['appVersion'], '1.18.2-rc.4+240');
      expect(diagnostics.exportJson(), isNot(contains('987654321')));
      expect(detaches, 1);
      expect(data['inFlightStagesAtStop'], 0);
    },
  );

  testWidgets('capture times out once and unregisters the frame callback', (
    tester,
  ) async {
    start();
    await tester.pump(const Duration(seconds: 44));
    expect(diagnostics.isRecording, isTrue);
    now = const Duration(seconds: 45).inMicroseconds;
    await tester.pump(const Duration(seconds: 1));
    expect(diagnostics.isRecording, isFalse);
    expect(report()['stopReason'], 'timeout');
    expect(report()['durationUs'], 45000000);
    expect(detaches, 1);
    frames!([_frame(99999, 99999)]);
    expect(report()['retainedFrameSamples']['ui']['count'], 0);
    await tester.pump(const Duration(seconds: 60));
    expect(detaches, 1);
  });

  test(
    'late work cannot append to a stopped, cleared or replacement capture',
    () {
      start();
      final old = diagnostics.beginImageSpan(
        1,
        ReaderDiagnosticStage.codecInitWait,
      )!;
      final oldTurn = diagnostics.beginPageTurn(
        page: 1,
        targetPage: 2,
        chapter: 1,
      )!;
      diagnostics.stop(ReaderDiagnosticStop.background);
      expect(report()['inFlightStagesAtStop'], 1);
      old.finish();
      expect(report()['imageEvents'], isEmpty);
      start();
      old.finish();
      oldTurn.finish(page: 2, viewportPage: 2);
      expect(report()['imageEvents'], isEmpty);
      expect(report()['navigationEvents'], isEmpty);
      final pending = diagnostics.beginImageSpan(
        2,
        ReaderDiagnosticStage.firstDecodeWait,
      )!;
      diagnostics.clear();
      pending.finish();
      expect(diagnostics.hasCapture, isFalse);
      expect(report()['imageEvents'], isEmpty);
      expect(detaches, 2);
    },
  );

  test(
    'deadline rejects late samples even before a delayed timer callback',
    () {
      start();
      now = const Duration(seconds: 46).inMicroseconds;
      expect(
        diagnostics.beginImageSpan(1, ReaderDiagnosticStage.localRead),
        isNull,
      );
      expect(diagnostics.isRecording, isFalse);
      expect(report()['durationUs'], 45000000);
      expect(report()['stopReason'], 'timeout');
    },
  );

  test(
    'event, frame and identity buffers are bounded and truncation is explicit',
    () {
      diagnostics.dispose();
      diagnostics = ReaderDiagnostics(
        maxEvents: 3,
        maxFrames: 2,
        maxImages: 2,
        maxNavigationEvents: 2,
        nowMicros: () => now,
        attachTimings: (callback) => frames = callback,
        detachTimings: (_) {},
      );
      start(version: 'https://private.example/account');
      for (var i = 0; i < 5; i++) {
        diagnostics.recordCache(
          i % 2,
          pending: false,
          keepAlive: false,
          live: false,
        );
      }
      diagnostics.recordCache(3, pending: false, keepAlive: false, live: false);
      frames!([_frame(1, 1), _frame(2, 2), _frame(3, 3)]);
      for (var page = 1; page <= 3; page++) {
        diagnostics.recordNavigation(
          ReaderDiagnosticNavigation.volumeNext,
          page: page,
          targetPage: page + 1,
        );
      }
      diagnostics.stop(ReaderDiagnosticStop.review);
      final data = report();
      expect(data['imageEvents'], hasLength(3));
      expect(data['droppedEvents'], 2);
      expect(data['droppedFrames'], 1);
      expect(data['frameSamples'], hasLength(2));
      expect(data['navigationEvents'].map((event) => event['page']), [2, 3]);
      expect(data['droppedNavigationEvents'], 1);
      expect(data['ignoredImageLookups'], 1);
      expect(data['retainedFrameSamples']['ui']['count'], 2);
      expect(data['configuration']['appVersion'], 'unknown');
      expect(diagnostics.exportJson(), isNot(contains('private.example')));
    },
  );

  testWidgets('a deadline detected during image build defers UI notification', (
    tester,
  ) async {
    start();
    now = const Duration(seconds: 46).inMicroseconds;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            ListenableBuilder(
              listenable: diagnostics,
              builder: (_, _) => Text('${diagnostics.isRecording}'),
            ),
            Builder(
              builder: (_) {
                diagnostics.recordCache(
                  1,
                  pending: false,
                  keepAlive: false,
                  live: false,
                );
                return const SizedBox();
              },
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(diagnostics.isRecording, isFalse);
    expect(find.text('false'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(detaches, 1);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'a full capture stays copyable and explicitly counts omitted details',
    () {
      start();
      for (var i = 0; i < diagnostics.maxEvents; i++) {
        diagnostics
            .beginImageSpan(1, ReaderDiagnosticStage.firstDecodeWait)!
            .finish(
              bytes: 0x7fffffffffffffff,
              width: 0x7fffffffffffffff,
              height: 0x7fffffffffffffff,
            );
        now += 100;
        diagnostics.recordNavigation(
          ReaderDiagnosticNavigation.viewport,
          page: i + 1,
          viewportPage: i + 1.25,
          scrolling: true,
        );
      }
      frames!(
        List.generate(
          diagnostics.maxFrames,
          (i) => _frame(50000, 50000, start: i * 8333),
        ),
      );
      diagnostics.stop(ReaderDiagnosticStop.review);
      final encoded = diagnostics.exportJson();
      final data = jsonDecode(encoded) as Map<String, dynamic>;
      expect(
        encoded.length,
        lessThanOrEqualTo(ReaderDiagnostics.maxReportCharacters),
      );
      expect(data['retainedEventCount'], diagnostics.maxEvents);
      expect(data['omittedEventsForCopy'], greaterThan(0));
      expect(
        (data['imageEvents'] as List).length +
            (data['omittedEventsForCopy'] as int),
        diagnostics.maxEvents,
      );
      expect(
        data['retainedStageSamples']['firstDecodeWait']['count'],
        diagnostics.maxEvents,
      );
      expect(data['droppedEvents'], 0);
      expect(
        data['retainedFrameSamples']['ui']['count'],
        diagnostics.maxFrames,
      );
      expect(data['retainedFrameSamples']['slowest'], hasLength(40));
      expect(data['omittedFrameSamplesForCopy'], greaterThan(0));
      expect(
        (data['frameSamples'] as List).length +
            (data['omittedFrameSamplesForCopy'] as int),
        diagnostics.maxFrames,
      );
      expect(
        (data['navigationEvents'] as List).length +
            (data['omittedNavigationEventsForCopy'] as int),
        diagnostics.maxNavigationEvents,
      );
      final complete =
          jsonDecode(diagnostics.exportJson(complete: true)) as Map;
      expect(complete['frameSamples'], hasLength(diagnostics.maxFrames));
      expect(complete['imageEvents'], hasLength(diagnostics.maxEvents));
      expect(
        complete['navigationEvents'],
        hasLength(diagnostics.maxNavigationEvents),
      );
      expect(complete['omittedEventsForCopy'], 0);
      expect(complete['omittedFrameSamplesForCopy'], 0);
      expect(complete['omittedNavigationEventsForCopy'], 0);
      expect(complete['frameSamples'].first[4], 0);
      expect(
        complete['frameSamples'].last[4],
        (diagnostics.maxFrames - 1) * 8333,
      );
      expect(
        diagnostics.exportJson(),
        encoded,
        reason: 'preview must not prune retained samples',
      );
      start(version: '1.2.3-${'private' * 100}');
      expect(report()['configuration']['appVersion'], 'unknown');
    },
  );

  test(
    'reader work hold stops sampling without changing work admission rules',
    () async {
      final work = ImageWork(diagnostics: diagnostics);
      start();
      final release = work.holdForExit();
      expect(diagnostics.isRecording, isFalse);
      expect(report()['stopReason'], 'interrupted');
      expect(work.start(), isNull);
      release();
      final task = work.start()!;
      task.finish();
      await work.dispose();
      expect(detaches, 1);
    },
  );

  test(
    'local reader pipeline records read, codec, first decode and cache/display without private data',
    () async {
      final root = Directory.systemTemp.createTempSync('reader-diagnostics-');
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
      );
      final file = File('${root.path}/private-comic.png')
        ..writeAsBytesSync(bytes);
      final previous = appdata.settings['enableCustomImageProcessing'];
      appdata.settings['enableCustomImageProcessing'] = false;
      final work = ImageWork(diagnostics: diagnostics);
      final provider = ReaderImageProvider(
        'file://${file.path}',
        'private-source',
        'private-title',
        'private-chapter',
        1,
        diagnostics: diagnostics,
      );
      final plain = ReaderImageProvider(
        'file://${file.path}',
        'private-source',
        'private-title',
        'private-chapter',
        1,
      );
      expect(provider, plain);
      expect(provider.hashCode, plain.hashCode);
      start();
      final stream = ReaderDisplayImageProvider(
        provider,
        work,
      ).resolve(ImageConfiguration.empty);
      final ready = Completer<void>();
      final listener = ImageStreamListener(
        (info, _) {
          info.dispose();
          if (!ready.isCompleted) ready.complete();
        },
        onError: (error, stack) {
          if (!ready.isCompleted) ready.completeError(error, stack);
        },
      );
      stream.addListener(listener);
      ImageStream? cachedStream;
      ImageStreamListener? cachedListener;
      try {
        for (var i = 0; i < 80 && !ready.isCompleted; i++) {
          await pumpEventQueue();
          await _drawFrame();
        }
        await ready.future.timeout(const Duration(seconds: 5));
        diagnostics.stop(ReaderDiagnosticStop.review);
        final events = report()['imageEvents'] as List;
        expect(
          events.map((event) => event['stage']),
          containsAll([
            'cacheLookup',
            'localRead',
            'codecInitWait',
            'firstDecodeWait',
            'displayWait',
          ]),
        );
        expect(
          events
              .where((event) => event['stage'] == 'localRead')
              .single['bytes'],
          bytes.length,
        );
        final encoded = diagnostics.exportJson();
        for (final private in [
          root.path,
          'private-comic',
          'private-source',
          'private-title',
          'private-chapter',
          base64Encode(bytes),
        ]) {
          expect(encoded, isNot(contains(private)));
        }

        expect(
          PaintingBinding.instance.imageCache.statusForKey(provider).keepAlive,
          isTrue,
        );
        start();
        cachedStream = ReaderDisplayImageProvider(
          plain,
          work,
        ).resolve(ImageConfiguration.empty);
        final cachedReady = Completer<void>();
        cachedListener = ImageStreamListener((info, _) {
          info.dispose();
          if (!cachedReady.isCompleted) cachedReady.complete();
        });
        cachedStream.addListener(cachedListener);
        for (var i = 0; i < 80 && !cachedReady.isCompleted; i++) {
          await pumpEventQueue();
          await _drawFrame();
        }
        await cachedReady.future.timeout(const Duration(seconds: 5));
        diagnostics.stop(ReaderDiagnosticStop.review);
        final cachedEvents = report()['imageEvents'] as List;
        expect(
          cachedEvents.map((event) => event['stage']),
          containsAll(['cacheLookup', 'displayWait']),
        );
        expect(
          cachedEvents.map((event) => event['stage']),
          isNot(contains('localRead')),
        );
        expect(
          cachedEvents.map((event) => event['stage']),
          isNot(contains('codecInitWait')),
        );
        final cacheLookup = cachedEvents.singleWhere(
          (event) => event['stage'] == 'cacheLookup',
        );
        expect(cacheLookup['keepAlive'], isTrue);
      } finally {
        stream.removeListener(listener);
        if (cachedListener != null) {
          cachedStream!.removeListener(cachedListener);
        }
        PaintingBinding.instance.imageCache.evict(provider);
        final released = BaseImageProvider.waitForReleasedStream(
          stream,
          waitForCurrentFrame: true,
        );
        final closing = work.dispose();
        await _drawFrame();
        await released;
        await closing;
        PaintingBinding.instance.imageCache.clearLiveImages();
        await _drawFrame();
        appdata.settings['enableCustomImageProcessing'] = previous;
        root.deleteSync(recursive: true);
      }
    },
  );
}
