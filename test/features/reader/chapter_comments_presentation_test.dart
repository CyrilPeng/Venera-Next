import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/side_bar.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/reader/chapter_comments.dart';
import 'package:venera_next/features/reader/comments_controller.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/res.dart';

void main() {
  setUpAll(() async {
    final path = Platform.environment['CHAPTER_COMMENTS_QA_FONT'];
    if (path == null) return;
    await (FontLoader(
      'CommentsQA',
    )..addFont(File(path).readAsBytes().then(ByteData.sublistView))).load();
    await (FontLoader('MaterialIcons')..addFont(
          File(
            'build/windows/x64/runner/Release/data/flutter_assets/fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });
  setUp(() {
    final words = appdata.settings['blockedCommentWords'];
    appdata.settings['blockedCommentWords'] = [];
    addTearDown(() => appdata.settings['blockedCommentWords'] = words);
  });
  for (final embedded in [false, true]) {
    for (final scenario in [
      (size: Size(375, 667), scale: 1.0, dark: false),
      (size: Size(667, 375), scale: 3.2, dark: true),
      (size: Size(1024, 768), scale: 2.0, dark: false),
    ]) {
      testWidgets('comments layout embedded=$embedded $scenario', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(scenario.size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final work = ImageWork();
        final repaint = GlobalKey();
        final replies = <String?>[];
        final pending = Completer<Res<bool>>();
        var exitCalls = 0, sends = 0;
        const chapterTitle =
            'Chapter 12: A long title for the original chapter';
        final request = ReaderChapterCommentsRequest(
          identity: Object(),
          sourceKey: 'test',
          comicTitle: 'Book',
          chapterTitle: chapterTitle,
          isCurrent: () => true,
          load: (page, reply) async {
            replies.add(reply);
            return Res([
              Comment.fromJson({
                'id': 'first',
                'userName': 'Reader',
                'content': 'A thoughtful comment about this chapter.',
                'score': 12,
                'replyCount': reply == null ? 2 : null,
                'time': '2026-10-07',
              }),
            ], subData: 1);
          },
          send: (text, reply) {
            sends++;
            return pending.future;
          },
          like: (_, _) async => const Res(13),
          vote: (_, _, _) async => const Res(13),
        );
        final page = embedded
            ? EmbeddedChapterCommentsPage(
                request: request,
                work: work,
                onExit: () async {
                  exitCalls++;
                },
              )
            : ChapterCommentsPage(request: request, work: work);
        late BuildContext parent;
        var keyboard = 0.0;
        Widget app() => MaterialApp(
          theme: ThemeData(
            brightness: scenario.dark ? Brightness.dark : Brightness.light,
            fontFamily: Platform.environment['CHAPTER_COMMENTS_QA_FONT'] == null
                ? null
                : 'CommentsQA',
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: scenario.size,
              textScaler: TextScaler.linear(scenario.scale),
              disableAnimations: true,
              padding: const EdgeInsets.only(top: 24, bottom: 20),
              viewInsets: EdgeInsets.only(bottom: keyboard),
            ),
            child: RepaintBoundary(key: repaint, child: child!),
          ),
          home: Scaffold(
            resizeToAvoidBottomInset: false,
            body: Builder(
              builder: (context) {
                parent = context;
                return embedded ? page : const Center(child: Text('Reading'));
              },
            ),
          ),
        );
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(app());
          if (!embedded) unawaited(showSideBar(parent, page));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final back = find.byTooltip(embedded ? 'Exit' : 'Back');
          for (final button in [
            back,
            find.byTooltip('Send'),
            find.byTooltip('Like'),
            find.byTooltip('Upvote'),
            find.byTooltip('Downvote'),
            find.byTooltip('Replies'),
          ]) {
            await tester.ensureVisible(button);
            await tester.pumpAndSettle();
            final size = tester.getSize(button);
            expect(size.width, greaterThanOrEqualTo(48));
            expect(size.height, greaterThanOrEqualTo(48));
            final data = tester.getSemantics(button).getSemanticsData();
            expect(data.label + data.tooltip, isNotEmpty);
          }
          final colors = Theme.of(
            tester.element(find.text(chapterTitle)),
          ).colorScheme;
          double contrast(Color a, Color b) {
            final x = a.computeLuminance(), y = b.computeLuminance();
            return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
          }

          expect(
            contrast(colors.onSurface, colors.surface),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            contrast(colors.secondary, colors.surfaceContainer),
            greaterThanOrEqualTo(3),
          );
          final output = Platform.environment['CHAPTER_COMMENTS_QA_DIR'];
          Future<void> capture(String suffix) async {
            if (output == null) return;
            await tester.runAsync(() async {
              final boundary =
                  repaint.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 1);
              try {
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  '$output/${embedded ? 'embedded' : 'sidebar'}-${scenario.size.width.toInt()}$suffix.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
              } finally {
                image.dispose();
              }
            });
          }

          if (output != null) {
            tester
                .state<ScrollableState>(find.byType(Scrollable).first)
                .position
                .jumpTo(0);
            await tester.pumpAndSettle();
            await capture('');
          }
          await tester.ensureVisible(find.byTooltip('Replies'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Replies'));
          await tester.pumpAndSettle();
          expect(replies, [null, 'first']);
          expect(find.text(chapterTitle).last, findsOneWidget);
          await capture('-replies');
          final replyRoute = ModalRoute.of(
            tester.element(find.text('Replies').last),
          )!;
          replyRoute.navigator!.pop();
          await tester.pumpAndSettle();
          keyboard = scenario.size.height < 400 ? 100 : 250;
          await tester.pumpWidget(app());
          await tester.enterText(find.byType(TextField), 'Draft');
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final fieldRect = tester.getRect(find.byType(TextField));
          expect(
            fieldRect.bottom,
            lessThanOrEqualTo(scenario.size.height - keyboard),
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
          expect(sends, 1);
          expect(
            tester
                .widget<CircularProgressIndicator>(
                  find.byType(CircularProgressIndicator),
                )
                .value,
            .5,
          );
          pending.complete(const Res(true));
          await tester.pumpAndSettle();
          if (embedded) {
            await tester.tap(back);
            expect(exitCalls, 1);
          }
        } finally {
          if (!pending.isCompleted) pending.complete(const Res(true));
          semantics.dispose();
          await tester.pumpWidget(const SizedBox());
          await work.dispose();
        }
      });
    }
  }
}
