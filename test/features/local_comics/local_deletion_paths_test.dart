import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/features/local_comics/local_deletion_paths.dart';

void main() {
  test(
    'preserves overlapping references and library ancestors with normalized aliases',
    () {
      final root = p.absolute('fixture');
      String path(String part) => p.join(root, part);
      expect(
        localDirectoriesToDelete(
          libraryPath: path('library'),
          candidates: [
            root,
            path('library'),
            path('shared'),
            path('parent'),
            path('child/a'),
            path('free'),
            path('free/../free'),
          ],
          retained: [path('shared/.'), path('parent/book'), path('child')],
        ),
        [path('free')],
      );
    },
  );

  test(
    'resolves missing suffixes through an existing native ancestor',
    () async {
      final root = Directory.systemTemp.createTempSync('deletion-identity-');
      try {
        final actual = await root.resolveSymbolicLinks();
        expect(
          await resolveLocalNativePath(p.join(root.path, 'missing', 'child')),
          p.join(actual, 'missing', 'child'),
        );
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );

  test('identity lookup failure prevents producing a cleanup list', () async {
    final root = p.absolute('fixture');
    await expectLater(
      resolveLocalDirectoriesToDelete(
        libraryPath: p.join(root, 'library'),
        candidates: [p.join(root, 'delete')],
        retained: [p.join(root, 'unreadable')],
        resolvePath: (path) async {
          if (path.endsWith('unreadable')) throw const FileSystemException();
          return path;
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
}
