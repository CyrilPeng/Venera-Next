import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/image_export.dart';

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

  test(
    'save and share use captured image identity and detected type',
    () async {
      var current = selection;
      final saved = <ReaderImageExport>[];
      final shared = <ReaderImageExport>[];
      final pending = Completer<Uint8List>();
      final exporter = ReaderImageExporter(
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
      current = selection;
      await exporter.export(sharing: true);
      expect(shared.single.filename, saved.single.filename);
      exporter.dispose();
    },
  );

  test('cancelled selection does not read or deliver', () async {
    final exporter = ReaderImageExporter(
      select: () async => null,
      read: (_) async => throw StateError('must not read'),
      save: (_) => fail('save'),
      share: (_) => fail('share'),
      onError: (e, s) => fail('$e'),
    );
    await exporter.export(sharing: false);
    exporter.dispose();
  });

  for (final duringRead in [false, true]) {
    test(
      'disposal stops pending ${duringRead ? 'read' : 'selection'}',
      () async {
        final selected = Completer<ReaderImageSelection?>();
        final bytes = Completer<Uint8List>();
        var reads = 0;
        final exporter = ReaderImageExporter(
          select: () => selected.future,
          read: (_) {
            reads++;
            return bytes.future;
          },
          save: (_) => fail('late save'),
          share: (_) => fail('late share'),
          onError: (e, s) => fail('late error: $e'),
        );
        final job = exporter.export(sharing: true);
        if (duringRead) {
          selected.complete(selection);
          await pumpEventQueue();
        }
        exporter.dispose();
        await job;
        if (duringRead) {
          bytes.completeError(StateError('late file error'));
        } else {
          selected.complete(selection);
        }
        await pumpEventQueue();
        await exporter.export(sharing: false);
        expect(reads, duringRead ? 1 : 0);
      },
    );
  }

  test(
    'read and platform failures are reported and later export can recover',
    () async {
      var reads = 0;
      var saves = 0;
      final errors = <Object>[];
      final exporter = ReaderImageExporter(
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
      exporter.dispose();
    },
  );
}
