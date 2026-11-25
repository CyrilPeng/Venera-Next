import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/diagnostics_dialog.dart';
import 'package:venera_next/foundation/reader_diagnostics.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/components/window_selection_task.dart';

void main() {
  setUpAll(() => App.cachePath = Directory.systemTemp.path);
  late ReaderDiagnostics diagnostics;
  setUp(
    () => diagnostics = ReaderDiagnostics(
      attachTimings: (_) {},
      detachTimings: (_) {},
    ),
  );
  tearDown(() => diagnostics.dispose());

  void capture() {
    diagnostics.start(
      mode: ReaderDiagnosticMode.paged,
      processingEnabled: false,
      appVersion: '1.18.2-rc.4+240',
      refreshRate: 120,
    );
    diagnostics
        .beginImageSpan(42, ReaderDiagnosticStage.localRead)!
        .finish(bytes: 100);
    diagnostics.stop(ReaderDiagnosticStop.review);
  }

  Widget host({
    Brightness brightness = Brightness.light,
    double textScale = 1,
    void Function(bool?)? result,
    SelectionTaskRegistry? registry,
  }) => MaterialApp(
    theme: ThemeData(brightness: brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: registry == null
          ? child!
          : SelectionTasksScope(registry: registry, child: child!),
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () async {
            final start = await showDialog<bool>(
              context: context,
              builder: (_) => ReaderDiagnosticsDialog(diagnostics: diagnostics),
            );
            result?.call(start);
          },
          child: const Text('Open diagnostics'),
        ),
      ),
    ),
  );

  testWidgets('opening and dismissing diagnostics does not start collection', (
    tester,
  ) async {
    bool? requested;
    await tester.pumpWidget(host(result: (value) => requested = value));
    await tester.tap(find.text('Open diagnostics'));
    await tester.pumpAndSettle();
    expect(diagnostics.isRecording, isFalse);
    expect(diagnostics.hasCapture, isFalse);
    expect(find.text('Copy report'), findsNothing);
    await tester.tap(find.text('Start new 45-second capture'));
    await tester.pumpAndSettle();
    expect(requested, isTrue);
    expect(
      diagnostics.isRecording,
      isFalse,
      reason: 'the reader starts only after its route/target checks',
    );
  });

  for (final brightness in Brightness.values) {
    for (final size in [const Size(375, 667), const Size(900, 375)]) {
      testWidgets(
        'preview and explicit copy fit $size with large text and $brightness reduced motion',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          String? copied;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'] as String;
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          capture();
          await tester.pumpWidget(host(brightness: brightness, textScale: 2));
          await tester.tap(find.text('Open diagnostics'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(copied, isNull, reason: 'opening a preview must not export');
          expect(
            find.byKey(const ValueKey('reader-diagnostic-preview')),
            findsOneWidget,
          );
          await tester.tap(find.text('Copy report'));
          await tester.pumpAndSettle();
          expect(jsonDecode(copied!), jsonDecode(diagnostics.exportJson()));
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('Clear report'));
          await tester.pumpAndSettle();
          expect(diagnostics.hasCapture, isFalse);
          expect(find.text('Copy report'), findsNothing);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'explicit file save preserves normal frames omitted from the copy preview',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('reader-full-report-');
      final previousCache = App.cachePath;
      App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
      final registry = SelectionTaskRegistry();
      final destination = File('${root.path}/reader-diagnostics.json');
      late Completer<void> entered;
      late Completer<String?> reply;
      await tester.runAsync(() async {
        entered = Completer<void>();
        reply = Completer<String?>();
      });
      const selector = MethodChannel('plugins.flutter.io/file_selector');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(selector, (_) {
        if (!entered.isCompleted) entered.complete();
        return reply.future;
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(selector, null);
        if (!reply.isCompleted) reply.complete(null);
        await tester.runAsync(
          () => registry.closeAndWait().timeout(const Duration(seconds: 10)),
        );
        App.cachePath = previousCache;
        root.deleteSync(recursive: true);
      });
      TimingsCallback? frames;
      diagnostics.dispose();
      diagnostics = ReaderDiagnostics(
        nowMicros: () => 1000,
        attachTimings: (callback) => frames = callback,
        detachTimings: (_) {},
      );
      diagnostics.start(
        mode: ReaderDiagnosticMode.paged,
        processingEnabled: false,
        appVersion: '1.18.4-rc.3+252',
        refreshRate: 120,
      );
      frames!(
        List.generate(
          1500,
          (i) => FrameTiming(
            vsyncStart: 1000 + i * 8333,
            buildStart: 1100 + i * 8333,
            buildFinish: 2100 + i * 8333,
            rasterStart: 2100 + i * 8333,
            rasterFinish: 3100 + i * 8333,
            rasterFinishWallTime: 3100 + i * 8333,
          ),
        ),
      );
      diagnostics.stop(ReaderDiagnosticStop.review);
      expect(
        jsonDecode(diagnostics.exportJson())['omittedFrameSamplesForCopy'],
        greaterThan(0),
      );
      await tester.pumpWidget(host(registry: registry));
      await tester.tap(find.text('Open diagnostics'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Save full report'));
        await entered.future.timeout(const Duration(seconds: 10));
      });
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Clear report'))
            .onPressed,
        isNull,
      );
      reply.complete(destination.path);
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !destination.existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(destination.existsSync(), isTrue);
        final saved = jsonDecode(destination.readAsStringSync());
        expect(saved['frameSamples'], hasLength(1500));
        expect(saved['omittedFrameSamplesForCopy'], 0);
        expect(saved['retainedFrameSamples']['slowest'], isEmpty);
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'copy failure remains actionable without exposing platform error text',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(
              code: 'failed',
              message: 'private-path-do-not-show',
            );
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      capture();
      await tester.pumpWidget(host());
      await tester.tap(find.text('Open diagnostics'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy report'));
      await tester.pumpAndSettle();
      expect(find.text('Unable to copy report.'), findsOneWidget);
      expect(find.textContaining('private-path-do-not-show'), findsNothing);
      expect(diagnostics.hasCapture, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
