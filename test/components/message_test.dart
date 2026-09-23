import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/message.dart';

void main() {
  for (final dismissal in ['button', 'back', 'barrier', 'finished']) {
    testWidgets('loading dialog cancels once on $dismissal', (tester) async {
      late BuildContext dialogContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              dialogContext = context;
              return const Scaffold();
            },
          ),
        ),
      );
      var cancellations = 0;
      final controller = showLoadingDialog(
        dialogContext,
        onCancel: () => cancellations++,
        cancelButtonText: 'Stop',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      switch (dismissal) {
        case 'button':
          await tester.tap(find.text('Stop'));
        case 'back':
          await Navigator.of(dialogContext).maybePop();
        case 'barrier':
          await tester.tapAt(const Offset(10, 10));
        case 'finished':
          controller.close();
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      controller.close();
      expect(controller.closed, isTrue);
      expect(cancellations, dismissal == 'finished' ? 0 : 1);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });
  }

  testWidgets('showToast stacks multiple messages without overlap', (
    tester,
  ) async {
    late BuildContext toastContext;

    await tester.pumpWidget(
      MaterialApp(
        home: OverlayWidget(
          Builder(
            builder: (context) {
              toastContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    showToast(message: 'First toast', context: toastContext, seconds: 1);
    showToast(message: 'Second toast', context: toastContext, seconds: 1);
    await tester.pump();

    final firstRect = tester.getRect(find.text('First toast'));
    final secondRect = tester.getRect(find.text('Second toast'));

    expect(firstRect.overlaps(secondRect), isFalse);
    expect(firstRect.top, lessThan(secondRect.top));

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('First toast'), findsNothing);
    expect(find.text('Second toast'), findsNothing);
  });
}
