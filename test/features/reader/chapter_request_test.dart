import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart'
    show ComicChapters;
import 'package:venera_next/features/reader/chapter_request.dart';
import 'package:venera_next/features/reader/waterfall_controller.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/network/request_scope.dart';

void main() {
  test(
    'grouped loading retains repeated IDs, empty groups and immutable maps',
    () async {
      final source = <String, Map<String, String>>{
        'empty': {},
        'first': {'same': 'First'},
        'second': {'same': 'Second'},
      };
      final request = ReaderChapterRequest(
        identity: Object(),
        chapters: ComicChapters.grouped(source),
        isCurrent: () => true,
        canInteract: () => true,
        load: (chapter, snapshot, _) async {
          expect(snapshot!.positionAt(chapter).group, 3);
          expect(snapshot.getGroup('second')['same'], 'Second');
          expect(
            () => snapshot.getGroup('second')['same'] = 'mutated',
            throwsUnsupportedError,
          );
          expect(() => snapshot.toJson().clear(), throwsUnsupportedError);
          return [snapshot.positionAt(chapter).id];
        },
      );
      source['first']!['same'] = 'Renamed';
      source['second']!.clear();
      final scope = RequestScope();
      try {
        expect(request.chapterTitle(1), 'First');
        expect(request.chapterTitle(2), 'Second');
        expect(await request.load(2, scope), ['same']);
      } finally {
        scope.dispose();
      }
    },
  );

  test('retired request cancels before entering the loader', () async {
    var calls = 0;
    final request = ReaderChapterRequest(
      identity: Object(),
      chapters: null,
      isCurrent: () => false,
      canInteract: () => false,
      load: (_, _, _) async {
        calls++;
        return [];
      },
    );
    final scope = RequestScope();
    try {
      await expectLater(
        request.load(1, scope),
        throwsA(isA<RequestCancelled>()),
      );
      expect(scope.isCancelled, isTrue);
      expect(calls, 0);
    } finally {
      scope.dispose();
    }
  });

  for (final fail in [false, true]) {
    test(
      'retired chapter still drains original loader; failure=$fail',
      () async {
        var current = true;
        final pending = Completer<List<String>>();
        final started = Completer<void>();
        final error = StateError('original chapter failed');
        final request = ReaderChapterRequest(
          identity: Object(),
          chapters: const ComicChapters({'one': 'One'}),
          isCurrent: () => current,
          canInteract: () => current,
          load: (_, _, _) {
            started.complete();
            return pending.future;
          },
        );
        final work = ImageWork();
        final controller = WaterfallController(
          maxChapter: 1,
          load: request.load,
          chapterId: request.chapterId,
          imageWork: work,
          onChanged: () {},
          onPreviousError: (_, _) {},
        );
        final loading = controller.navigate(1);
        await started.future;
        current = false;
        var drained = false;
        final closing = controller.dispose().then((_) => drained = true);
        expect(await loading, isFalse);
        await pumpEventQueue();
        expect(drained, isFalse);
        if (fail) {
          pending.completeError(error);
        } else {
          pending.complete(['old']);
        }
        await closing;
        expect(controller.flow.isEmpty, isTrue);
        if (fail) {
          await expectLater(
            work.dispose(),
            throwsA(
              predicate(
                (e) => e.toString().contains('original chapter failed'),
              ),
            ),
          );
        } else {
          await work.dispose();
        }
      },
    );
  }
}
