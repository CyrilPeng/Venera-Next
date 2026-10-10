import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/local_comics/local_comics_page.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/selection_operation.dart';

import '../../components/sidebar_presentation_test.dart'
    show pumpSidebar, settleSidebarWork;

void main() {
  tearDown(() => LocalManager.current?.dispose());
  for (final fails in [false, true]) {
    testWidgets('R1 original host drains folder opening, failure=$fails', (
      tester,
    ) async {
      final registry = SelectionTaskRegistry();
      final pending = Completer<void>();
      final paths = <String>[];
      final messages = <String>[];
      registerShowMessageHandler((_, message) => messages.add(message));
      LocalManager().path = 'synthetic-original';
      final comic = LocalComic(
        id: 'one',
        title: 'Synthetic comic',
        subtitle: '',
        tags: const [],
        directory: 'book',
        chapters: null,
        cover: '',
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: DateTime(2026),
      );
      final originalPath = comic.baseDir;
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) =>
              SelectionTasksScope(registry: registry, child: child!),
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold();
            },
          ),
        ),
      );
      final work = openComicFolder(
        context,
        comic,
        openDirectory: (path) {
          paths.add(path);
          return pending.future;
        },
      );
      LocalManager().path = 'synthetic-replacement';
      await pumpSidebar(tester);
      expect(paths, [originalPath]);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Replacement'))),
      );
      var closed = false;
      Object? closeFailure;
      final closing = registry.closeAndWait().then<void>(
        (_) => closed = true,
        onError: (Object error, StackTrace stack) {
          closeFailure = error;
          closed = true;
        },
      );
      await pumpSidebar(tester);
      final closedEarly = closed;
      if (fails) {
        pending.completeError(StateError('synthetic opener failed'));
      } else {
        pending.complete();
      }
      await settleSidebarWork(tester, () async {
        await work;
        await closing;
      });
      expect(closedEarly, isFalse);
      if (fails) {
        expect(closeFailure, isA<SelectionCleanupFailure>());
        expect(closeFailure.toString(), contains('synthetic opener failed'));
      } else {
        expect(closeFailure, isNull);
      }
      expect(messages, isEmpty);
      expect(find.text('Replacement'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
