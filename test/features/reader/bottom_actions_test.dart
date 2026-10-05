import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/bottom_actions.dart';
import 'package:venera_next/features/reader/orientation_controller.dart';
import 'package:venera_next/features/reader/progress_bar.dart';

void main() {
  List<Widget> actions(
    BuildContext context,
    List<String> calls, {
    bool desktop = false,
    bool android = false,
    bool chapters = true,
    bool selected = false,
    bool playing = false,
    bool collecting = false,
    ReaderOrientation orientation = ReaderOrientation.system,
  }) => buildReaderBottomActions(
    context,
    imageCollected: selected,
    onCollect: collecting ? null : () => calls.add('collect'),
    imageCollecting: collecting,
    onFullscreen: desktop ? () => calls.add('fullscreen') : null,
    orientation: orientation,
    onRotate: android ? () => calls.add('rotate') : null,
    brightnessEnabled: selected,
    onBrightness: () => calls.add('brightness'),
    automaticReading: ReaderAutomaticReadingAction(
      tooltip: 'Automatic reading action',
      active: selected,
      playing: playing,
      onPressed: () => calls.add('automatic'),
    ),
    onChapters: chapters ? () => calls.add('chapters') : null,
    onSave: () => calls.add('save'),
    onShare: () => calls.add('share'),
  );

  testWidgets(
    'pending image collection disables repeat submission with feedback',
    (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Row(children: actions(context, calls, collecting: true)),
            ),
          ),
        ),
      );
      final progress = find.byType(CircularProgressIndicator);
      expect(progress, findsOneWidget);
      final button = find.ancestor(
        of: progress,
        matching: find.byType(IconButton),
      );
      expect(tester.widget<IconButton>(button).onPressed, isNull);
      await tester.tap(button);
      expect(calls, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in [
    const Size(375, 667),
    const Size(667, 375),
    const Size(1024, 768),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('bottom actions fit $size in $brightness with large text', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final calls = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(3.2),
                  disableAnimations: true,
                  padding: const EdgeInsets.only(bottom: 24),
                ),
                child: Scaffold(
                  bottomNavigationBar: ReaderBottomBar(
                    label: 'E1 : P1',
                    actions: actions(context, calls, android: true),
                    page: 1,
                    maxPage: 10,
                    reversed: false,
                    isOpen: true,
                    onPageChanged: (_) {},
                    onPrevious: () {},
                    onNext: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        for (final button in tester.widgetList<IconButton>(
          find.byType(IconButton),
        )) {
          final box = tester.getSize(find.byWidget(button));
          expect(box.width, greaterThanOrEqualTo(48));
          expect(box.height, greaterThanOrEqualTo(48));
        }
        expect(
          tester.getBottomRight(find.byIcon(Icons.share)).dy,
          lessThanOrEqualTo(size.height - 24),
        );
        await tester.tap(find.byIcon(Icons.share));
        expect(calls, ['share']);
      });
    }
  }

  testWidgets(
    'capabilities control visibility and each action dispatches once',
    (tester) async {
      final calls = <String>[];
      Future<void> mount({
        required bool desktop,
        required bool android,
        required bool chapters,
      }) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Wrap(
                children: actions(
                  context,
                  calls,
                  desktop: desktop,
                  android: android,
                  chapters: chapters,
                ),
              ),
            ),
          ),
        ),
      );
      await mount(desktop: true, android: true, chapters: true);
      for (final icon in [
        Icons.favorite_border,
        Icons.fullscreen,
        Icons.screen_rotation,
        Icons.brightness_6,
        Icons.play_circle_outline,
        Icons.library_books,
        Icons.download,
        Icons.share,
      ]) {
        await tester.tap(find.byIcon(icon));
      }
      expect(calls, [
        'collect',
        'fullscreen',
        'rotate',
        'brightness',
        'automatic',
        'chapters',
        'save',
        'share',
      ]);
      await mount(desktop: false, android: false, chapters: false);
      expect(find.byIcon(Icons.fullscreen), findsNothing);
      expect(find.byIcon(Icons.screen_rotation), findsNothing);
      expect(find.byIcon(Icons.library_books), findsNothing);
      expect(find.byType(IconButton), findsNWidgets(5));
    },
  );

  testWidgets(
    'snapshots drive selected icons and preserve supplied auto action',
    (tester) async {
      for (final orientation in ReaderOrientation.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Wrap(
                  children: actions(
                    context,
                    [],
                    android: true,
                    selected: true,
                    orientation: orientation,
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.byIcon(Icons.favorite), findsOneWidget);
        expect(find.byIcon(Icons.brightness_4), findsOneWidget);
        expect(
          find.byIcon(switch (orientation) {
            ReaderOrientation.system => Icons.screen_rotation,
            ReaderOrientation.portrait => Icons.screen_lock_portrait,
            ReaderOrientation.landscape => Icons.screen_lock_landscape,
          }),
          findsOneWidget,
        );
        final autoButton = tester.widget<IconButton>(
          find.ancestor(
            of: find.byIcon(Icons.play_circle_outline),
            matching: find.byType(IconButton),
          ),
        );
        expect(
          autoButton.color,
          Theme.of(
            tester.element(find.byIcon(Icons.play_circle_outline)),
          ).colorScheme.primary,
        );
        expect(find.byTooltip('Automatic reading action'), findsOneWidget);
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Wrap(
                children: actions(context, [], selected: true, playing: true),
              ),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);
    },
  );

  testWidgets('icon actions keep tooltip semantics and keyboard activation', (
    tester,
  ) async {
    final calls = <String>[];
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Wrap(children: actions(context, calls)),
          ),
        ),
      ),
    );
    final collect = find.ancestor(
      of: find.byIcon(Icons.favorite_border),
      matching: find.byType(IconButton),
    );
    final tooltip = find.ancestor(of: collect, matching: find.byType(Tooltip));
    final labels = <String>[];
    void visit(SemanticsNode node) {
      final label = node.getSemanticsData().tooltip;
      if (label.isNotEmpty) labels.add(label);
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(tester.getSemantics(tooltip));
    expect(labels, contains(tester.widget<Tooltip>(tooltip).message));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(calls, ['collect']);
    semantics.dispose();
  });
}
