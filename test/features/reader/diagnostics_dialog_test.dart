import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/diagnostics_dialog.dart';
import 'package:venera_next/foundation/reader_diagnostics.dart';

void main() {
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
  }) => MaterialApp(
    theme: ThemeData(brightness: brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: child!,
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
