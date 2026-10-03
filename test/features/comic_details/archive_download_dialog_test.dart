import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_details/archive_download_dialog.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/res.dart';

ArchiveInfo archive() => ArchiveInfo.fromJson({
  'id': 'a',
  'title': 'Option A',
  'description': 'Archive',
});
void main() {
  testWidgets('normal selection bypasses archive requests', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Scaffold()),
    );
    final result = navigator.currentState!.push<ArchiveDownloadSelection>(
      MaterialPageRoute(
        builder: (_) => ArchiveDownloadDialog(
          comicId: 'book',
          downloader: ArchiveDownloader(
            (_) => throw StateError('not needed'),
            (_, _) => throw StateError('not needed'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(
      await result,
      isA<ArchiveDownloadSelection>().having((v) => v.url, 'normal', isNull),
    );
  });

  testWidgets('archive list errors retry and link request deduplicates', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final pending = Completer<Res<String>>();
    var lists = 0;
    var links = 0;
    final downloader = ArchiveDownloader(
      (id) async {
        expect(id, 'book');
        if (++lists == 1) throw StateError('offline');
        return Res([archive()]);
      },
      (id, selected) {
        expect(id, 'book');
        expect(selected, 'a');
        links++;
        return pending.future;
      },
    );
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Scaffold()),
    );
    final result = navigator.currentState!.push<ArchiveDownloadSelection>(
      MaterialPageRoute(
        builder: (_) =>
            ArchiveDownloadDialog(comicId: 'book', downloader: downloader),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Option A'));
    await tester.pump();
    await tester.tap(find.text('Confirm'));
    await tester.tap(find.text('Confirm'));
    expect(links, 1);
    pending.complete(const Res('https://example.test/a.zip'));
    await tester.pumpAndSettle();
    expect((await result)!.url, 'https://example.test/a.zip');
    expect(lists, 2);
  });

  for (final fail in [false, true]) {
    testWidgets('dismissed link request cannot close replacement; fail=$fail', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      final pending = Completer<Res<String>>();
      final downloader = ArchiveDownloader(
        (_) async => Res([archive()]),
        (_, _) => pending.future,
      );
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const Scaffold()),
      );
      final result = navigator.currentState!.push<ArchiveDownloadSelection>(
        MaterialPageRoute(
          builder: (_) =>
              ArchiveDownloadDialog(comicId: 'book', downloader: downloader),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Archive').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Option A'));
      await tester.pump();
      await tester.tap(find.text('Confirm'));
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(await result, isNull);
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Replacement')),
        ),
      );
      await tester.pumpAndSettle();
      if (fail) {
        pending.completeError(StateError('late'));
      } else {
        pending.complete(const Res('https://example.test/a.zip'));
      }
      await tester.pumpAndSettle();
      expect(find.text('Replacement'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
