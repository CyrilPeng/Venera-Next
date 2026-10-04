import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/image_selection.dart';
import 'package:venera_next/foundation/image_work.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('exit cancels and later reopens selection in $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = brightness == Brightness.dark
          ? const Size(375, 667)
          : const Size(667, 375);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final selection = ReaderImageSelectionOverlay();
      final work = ImageWork();
      late BuildContext host;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Builder(
            builder: (context) {
              host = context;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      final task = work.start(cancelSelection: selection.cancel)!;
      final result = task.select(() => selection.show(host));
      final cancelled = expectLater(
        result,
        throwsA(isA<ImageWorkTaskCancelled>()),
      ).whenComplete(task.finish);
      await tester.pump();
      expect(find.text('Click to select an image'), findsOneWidget);
      final preparing = work.prepareForExit();
      await cancelled;
      final release = await preparing;
      await tester.pump();
      expect(find.text('Click to select an image'), findsNothing);
      expect(work.start(), isNull);
      release();
      final retry = selection.show(host);
      await tester.pump();
      await tester.tapAt(const Offset(230, 300));
      expect(await retry, const Offset(230, 300));
      selection.dispose();
      await work.dispose();
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('replacement and disposal finish pending image selections', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late BuildContext host;
    final selection = ReaderImageSelectionOverlay();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Builder(
          builder: (context) {
            host = context;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    final first = selection.show(host);
    await tester.pump();
    final second = selection.show(host);
    expect(await first, isNull);
    await tester.pump();
    selection.dispose();
    expect(await second, isNull);
    selection.dispose();
    expect(await selection.show(host), isNull);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'selection reports global tap position once and removes overlay',
    (tester) async {
      tester.view.physicalSize = const Size(667, 375);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late BuildContext host;
      final selection = ReaderImageSelectionOverlay();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Builder(
            builder: (context) {
              host = context;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      final result = selection.show(host);
      await tester.pump();
      await tester.tapAt(const Offset(230, 300));
      expect(await result, const Offset(230, 300));
      await tester.pump();
      final pending = selection.show(host);
      await tester.pump();
      selection.dispose();
      expect(await pending, isNull);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
