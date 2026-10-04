import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/image_export.dart';
import 'package:venera_next/foundation/image_work.dart';

void main() {
  const selection = ReaderImageSelection(
    imageKey: 'image',
    sourceKey: 'source',
    comicId: 'book',
    chapterId: 'chapter-id',
    title: 'Book',
    chapter: 3,
    imageNumber: 7,
  );
  final png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
  late ImageWork work;

  setUp(() => work = ImageWork());
  tearDown(() => work.dispose());

  test(
    'save and share use captured image identity and detected type',
    () async {
      var current = selection;
      final saved = <ReaderImageExport>[];
      final shared = <ReaderImageExport>[];
      final pending = Completer<Uint8List>();
      final exporter = ReaderImageExporter(
        work: work,
        select: () async => current,
        read: (item) {
          expect(item.cacheKey, 'image@source@book@chapter-id');
          current = const ReaderImageSelection(
            imageKey: 'other',
            sourceKey: 's',
            comicId: 'b',
            chapterId: 'c',
            title: 'Changed',
            chapter: 9,
            imageNumber: 1,
          );
          return pending.future;
        },
        save: saved.add,
        share: shared.add,
        onError: (e, s) => fail('$e'),
      );
      final job = exporter.export(sharing: false);
      await pumpEventQueue();
      pending.complete(png);
      await job;
      expect(saved.single.filename, 'Book_EP3_P7.png');
      expect(saved.single.type.mime, 'image/png');
      expect(saved.single.bytes, same(png));
      current = selection;
      await exporter.export(sharing: true);
      expect(shared.single.filename, saved.single.filename);
      await exporter.dispose();
    },
  );

  test('cancelled selection allows a later export to succeed', () async {
    var selections = 0;
    var reads = 0;
    final saved = <ReaderImageExport>[];
    final exporter = ReaderImageExporter(
      work: work,
      select: () async => ++selections == 1 ? null : selection,
      read: (_) async {
        reads++;
        return png;
      },
      save: saved.add,
      share: (_) => fail('share'),
      onError: (e, s) => fail('$e'),
    );
    await exporter.export(sharing: false);
    expect(reads, 0);
    expect(saved, isEmpty);
    await exporter.export(sharing: false);
    expect(reads, 1);
    expect(saved.single.filename, 'Book_EP3_P7.png');
    await exporter.dispose();
  });

  for (final duringRead in [false, true]) {
    test(
      'disposal waits for cancelled ${duringRead ? 'read' : 'selection'}',
      () async {
        final selected = Completer<ReaderImageSelection?>();
        final bytes = Completer<Uint8List>();
        var reads = 0;
        var cancellations = 0;
        var jobFinished = false;
        var disposalFinished = false;
        var exitPrepared = false;
        final exporter = ReaderImageExporter(
          work: work,
          select: () => selected.future,
          cancelSelection: () => cancellations++,
          read: (_) {
            reads++;
            return bytes.future;
          },
          save: (_) => fail('late save'),
          share: (_) => fail('late share'),
          onError: (e, s) => fail('late error: $e'),
        );
        final job = exporter
            .export(sharing: true)
            .then((_) => jobFinished = true);
        if (duringRead) {
          selected.complete(selection);
          await pumpEventQueue();
        }
        final disposal = exporter.dispose().then(
          (_) => disposalFinished = true,
        );
        final preparation = work.prepareForExit().then((release) {
          exitPrepared = true;
          return release;
        });
        await pumpEventQueue();
        expect(jobFinished, isFalse);
        expect(disposalFinished, isFalse);
        expect(exitPrepared, isFalse);
        expect(cancellations, duringRead ? 0 : 1);
        if (duringRead) {
          bytes.complete(png);
        } else {
          selected.complete(selection);
        }
        await job;
        await disposal;
        (await preparation)();
        await exporter.export(sharing: false);
        expect(reads, duringRead ? 1 : 0);
      },
    );
  }

  test(
    'exit cancellation closes active selection and release allows retry',
    () async {
      final selected = Completer<ReaderImageSelection?>();
      var selections = 0;
      var overlayOpen = false;
      var cancellations = 0;
      var reads = 0;
      var saves = 0;
      final exporter = ReaderImageExporter(
        work: work,
        select: () {
          if (++selections > 1) return Future.value(selection);
          overlayOpen = true;
          return selected.future;
        },
        cancelSelection: () {
          cancellations++;
          overlayOpen = false;
          selected.complete(null);
        },
        read: (_) async {
          reads++;
          return png;
        },
        save: (_) => saves++,
        share: (_) => fail('share'),
        onError: (e, s) => fail('$e'),
      );
      final job = exporter.export(sharing: false);
      expect(overlayOpen, isTrue);
      final release = await work.prepareForExit();
      await job;
      expect(overlayOpen, isFalse);
      expect(cancellations, 1);
      expect(reads, 0);
      await exporter.export(sharing: false);
      expect(selections, 1);
      release();
      await exporter.export(sharing: false);
      expect(reads, 1);
      expect(saves, 1);
      await exporter.dispose();
    },
  );

  for (final sharing in [false, true]) {
    test(
      'queued ${sharing ? 'share' : 'save'} rechecks task before native dispatch',
      () async {
        final queued = Completer<void>();
        final turn = Completer<void>();
        var nativeCalls = 0;
        var prepared = false;
        Future<void> deliver(ReaderImageExport image) async {
          if (!queued.isCompleted) queued.complete();
          await turn.future;
          image.checkStop();
          nativeCalls++;
        }

        final exporter = ReaderImageExporter(
          work: work,
          select: () async => selection,
          read: (_) async => png,
          save: deliver,
          share: deliver,
          onError: (error, _) => fail('Cancellation reached UI: $error'),
        );
        final job = exporter.export(sharing: sharing);
        await queued.future;
        final preparing = work.prepareForExit().then((release) {
          prepared = true;
          return release;
        });
        await pumpEventQueue();
        expect(prepared, isFalse);
        expect(nativeCalls, 0);
        turn.complete();
        await job;
        final release = await preparing;
        expect(nativeCalls, 0);
        release();
        await exporter.export(sharing: sharing);
        expect(nativeCalls, 1);
        await exporter.dispose();
      },
    );

    test(
      'started ${sharing ? 'share' : 'save'} remains owned until completion',
      () async {
        final delivery = Completer<void>();
        final delivered = Completer<void>();
        var jobFinished = false;
        var disposed = false;
        var prepared = false;
        Future<void> deliver(ReaderImageExport image) {
          expect(image.bytes, same(png));
          image.checkStop();
          delivered.complete();
          return delivery.future;
        }

        final exporter = ReaderImageExporter(
          work: work,
          select: () async => selection,
          read: (_) async => png,
          save: deliver,
          share: deliver,
          onError: (e, s) => fail('$e'),
        );
        final job = exporter
            .export(sharing: sharing)
            .then((_) => jobFinished = true);
        await delivered.future;
        final disposal = exporter.dispose().then((_) => disposed = true);
        final preparation = work.prepareForExit().then((release) {
          prepared = true;
          return release;
        });
        await pumpEventQueue();
        expect(jobFinished, isFalse);
        expect(disposed, isFalse);
        expect(prepared, isFalse);
        delivery.complete();
        await job;
        await disposal;
        (await preparation)();
      },
    );
  }

  for (final stage in ['selection', 'read', 'platform']) {
    for (final disposeExporter in [false, true]) {
      test(
        '$stage failure after ${disposeExporter ? 'disposal' : 'exit hold'} is retained',
        () async {
          final selected = Completer<ReaderImageSelection?>();
          final bytes = Completer<Uint8List>();
          final delivery = Completer<void>();
          final entered = Completer<void>();
          final failure = StateError('late $stage');
          final stack = StackTrace.fromString('original $stage stack');
          final errors = <Object>[];
          final exporter = ReaderImageExporter(
            work: work,
            select: () {
              if (stage == 'selection') entered.complete();
              return selected.future;
            },
            read: (_) {
              if (stage == 'read') entered.complete();
              return bytes.future;
            },
            save: (_) => fail('save'),
            share: (_) {
              entered.complete();
              return delivery.future;
            },
            onError: (e, s) => errors.add(e),
          );
          final job = exporter.export(sharing: true);
          if (stage != 'selection') selected.complete(selection);
          if (stage == 'platform') bytes.complete(png);
          await entered.future;
          final disposal = disposeExporter
              ? exporter.dispose()
              : Future<void>.value();
          var drained = false;
          final drainExpectation = expectLater(
            work.prepareForExit(),
            throwsA(
              isA<ImageWorkFailure>().having(
                (e) => e.failures,
                'original failure and stack',
                [(error: failure, stack: stack)],
              ),
            ),
          ).then((_) => drained = true);
          await pumpEventQueue();
          expect(drained, isFalse);
          switch (stage) {
            case 'selection':
              selected.completeError(failure, stack);
            case 'read':
              bytes.completeError(failure, stack);
            case 'platform':
              delivery.completeError(failure, stack);
          }
          await job;
          await disposal;
          await drainExpectation;
          expect(errors, isEmpty);
          await exporter.dispose();
        },
      );
    }
  }

  test(
    'read and platform failures are reported and later export can recover',
    () async {
      var reads = 0;
      var saves = 0;
      final errors = <Object>[];
      final exporter = ReaderImageExporter(
        work: work,
        select: () async => selection,
        read: (_) async {
          if (++reads == 1) throw StateError('read');
          return png;
        },
        save: (_) async {
          if (++saves == 1) throw StateError('platform');
        },
        share: (_) {},
        onError: (e, s) => errors.add(e),
      );
      await exporter.export(sharing: false);
      await exporter.export(sharing: false);
      await exporter.export(sharing: false);
      expect(errors, hasLength(2));
      expect(saves, 2);
      await exporter.dispose();
    },
  );
}
