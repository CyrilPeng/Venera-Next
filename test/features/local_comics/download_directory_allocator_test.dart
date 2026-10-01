import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/download_directory_allocator.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  late Directory root;
  late Map<(String, int), String> registered;
  late DownloadDirectoryAllocator allocator;

  setUp(() {
    root = Directory.systemTemp.createTempSync('download-allocation-');
    registered = {};
    allocator = DownloadDirectoryAllocator(
      rootPath: () => root.path,
      findRegisteredPath: (id, type) => registered[(id, type.value)],
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
    'concurrent same-title downloads reserve distinct empty directories',
    () async {
      final outputs = await Future.wait([
        for (var i = 0; i < 4; i++)
          allocator.allocate('$i', ComicType.local, 'Book'),
      ]);
      expect(
        outputs.map((output) => output.directory.path).toSet(),
        hasLength(4),
      );
      for (final output in outputs) {
        expect(output.isNew, isTrue);
        expect(output.directory.existsSync(), isTrue);
        expect(output.directory.listSync(), isEmpty);
      }
    },
  );

  test(
    'unregistered empty directories and occupied files are preserved',
    () async {
      final existing = Directory('${root.path}/Book')..createSync();
      final file = File('${root.path}/Book(1)')..writeAsStringSync('keep');
      final output = await allocator.allocate('new', ComicType.local, 'Book');
      expect(output.isNew, isTrue);
      expect(output.directory.path, endsWith('Book(2)'));
      expect(existing.existsSync(), isTrue);
      expect(existing.listSync(), isEmpty);
      expect(file.readAsStringSync(), 'keep');
    },
  );

  test(
    'registration is resolved when queued allocation runs and is source-specific',
    () async {
      final existing = Directory('${root.path}/registered')..createSync();
      final pending = allocator.allocate('same', ComicType.local, 'Book');
      registered[('same', ComicType.local.value)] = existing.path;
      final output = await pending;
      expect(output.directory.path, existing.path);
      expect(output.isNew, isFalse);
      final otherSource = await allocator.allocate(
        'same',
        const ComicType(7),
        'Book',
      );
      expect(otherSource.isNew, isTrue);
      expect(otherSource.directory.path, isNot(existing.path));
    },
  );

  test(
    'failure does not poison later allocations and title rules stay bounded',
    () async {
      await expectLater(
        allocator.allocate('invalid', ComicType.local, '...'),
        throwsException,
      );
      final output = await allocator.allocate(
        'valid',
        ComicType.local,
        'A' * 100,
      );
      expect(output.isNew, isTrue);
      expect(
        output.directory.uri.pathSegments.where((part) => part.isNotEmpty).last,
        'A' * 80,
      );
      final sanitized = await allocator.allocate(
        'sanitized',
        ComicType.local,
        'a/b',
      );
      expect(sanitized.directory.path, endsWith('a b'));
    },
  );
}
