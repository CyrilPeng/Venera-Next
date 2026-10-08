import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_details/thumbnails.dart';
import 'package:venera_next/features/comic_details/comments_preview.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/comic_source/types.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/image_provider/cached_image.dart';

void main() {
  late Directory root;
  late String image;
  setUp(() {
    root = Directory.systemTemp.createTempSync('preview-lifecycle-');
    final file = File('${root.path}/image.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
    image = 'file://${file.path}';
    final language = appdata.settings['language'];
    final blocked = appdata.settings['blockedCommentWords'];
    appdata.settings['language'] = 'en-US';
    appdata.settings['blockedCommentWords'] = <String>[];
    addTearDown(() {
      appdata.settings['language'] = language;
      appdata.settings['blockedCommentWords'] = blocked;
      root.deleteSync(recursive: true);
    });
  });
  Widget thumbnails(
    ComicThumbnailLoader load, {
    String id = 'book',
    List<String> initial = const [],
  }) => MaterialApp(
    home: Scaffold(
      body: CustomScrollView(
        slivers: [
          ComicThumbnails(
            comicId: id,
            sourceKey: 'preview-test',
            initialThumbnails: initial,
            loadComicThumbnail: load,
            readPage: (_) {},
          ),
        ],
      ),
    ),
  );
  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    tester.binding.imageCache.clear();
    tester.binding.imageCache.clearLiveImages();
    for (var i = 0; i < 200 && CachedImageProvider.loadingCount > 0; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(CachedImageProvider.loadingCount, 0);
    await tester.pump();
  }

  testWidgets('initial thumbnails admit one first-page request', (
    tester,
  ) async {
    final pending = Completer<Res<List<String>>>();
    var calls = 0;
    await tester.pumpWidget(
      thumbnails((id, next) {
        calls++;
        return pending.future;
      }, initial: [image]),
    );
    expect(calls, 1);
    pending.complete(const Res([]));
    await tester.pump();
    await dispose(tester);
  });
  testWidgets('successful thumbnail retry clears the old error', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      thumbnails(
        (id, next) async =>
            ++calls == 1 ? const Res.error('preview offline') : const Res([]),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('preview offline'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(calls, 2);
    expect(find.text('preview offline'), findsNothing);
    expect(find.text('Retry'), findsNothing);
    await dispose(tester);
  });
  testWidgets(
    'replacement starts its own thumbnails and rejects an old result',
    (tester) async {
      final old = Completer<Res<List<String>>>();
      final next = Completer<Res<List<String>>>();
      final ids = <String>[];
      Future<Res<List<String>>> load(String id, String? cursor) {
        ids.add(id);
        return id == 'old' ? old.future : next.future;
      }

      await tester.pumpWidget(thumbnails(load, id: 'old'));
      await tester.pumpWidget(thumbnails(load, id: 'new'));
      expect(ids, ['old', 'new']);
      next.complete(const Res([]));
      old.complete(Res([image]));
      await tester.pump();
      await tester.pump();
      expect(find.text('1'), findsNothing);
      await dispose(tester);
    },
  );
  Comment comment(String name) =>
      Comment.fromJson({'userName': name, 'content': 'Text $name'});
  Widget comments(List<Comment> values) => MaterialApp(
    home: Scaffold(
      body: CustomScrollView(
        slivers: [ComicCommentsPreview(comments: values, showMore: () {})],
      ),
    ),
  );
  testWidgets('comment preview follows replacement input', (tester) async {
    await tester.pumpWidget(comments([comment('Old reader')]));
    expect(find.text('Old reader'), findsOneWidget);
    await tester.pumpWidget(comments([comment('New reader')]));
    expect(find.text('New reader'), findsOneWidget);
    expect(find.text('Old reader'), findsNothing);
    await dispose(tester);
  });
  testWidgets('comment preview releases its scroll controller', (tester) async {
    await tester.pumpWidget(comments([comment('Reader')]));
    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    await dispose(tester);
    expect(() => controller.addListener(() {}), throwsFlutterError);
  });
  for (final size in [const Size(375, 740), const Size(812, 375)]) {
    testWidgets('long comment authors stay within the preview at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final name = List.filled(12, 'Reader').join(' ');
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: size.width == 375 ? Brightness.dark : Brightness.light,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                ComicCommentsPreview(
                  comments: [comment(name)],
                  showMore: () {},
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.text(name));
      expect(rect.width, lessThan(324));
      final semantics = tester.ensureSemantics();
      expect(
        tester.getSemantics(find.text(name)).getSemanticsData().label,
        contains(name),
      );
      semantics.dispose();
      await dispose(tester);
    });
  }
}
