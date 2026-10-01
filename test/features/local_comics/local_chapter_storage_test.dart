import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/local_chapter_storage.dart';

void main() {
  test(
    'directory mapping preserves existing filenames and reserved character replacements',
    () {
      expect(localChapterDirectoryName('chapter/one:two'), 'chapter_one_two');
      expect(localChapterDirectoryName(r'a\b*c?d"e<f>g|h'), 'a_b_c_d_e_f_g_h');
      expect(localChapterDirectoryName('第一章. 01'), '第一章. 01');
      expect(localChapterDirectoryName('..'), '..');
    },
  );

  test(
    'cleanup protects aliases of retained directories and deduplicates removals',
    () {
      expect(
        localChapterDirectoriesToDelete(
          removed: [
            'shared/a',
            'OTHER',
            'other.',
            'kept ',
            'new/a',
            'new:a',
            'last',
          ],
          retained: ['shared:a', 'other', 'kept'],
        ),
        ['new_a', 'last'],
      );
      expect(
        localChapterDirectoriesToDelete(
          removed: ['A', 'a', 'b.', 'b '],
          retained: [],
        ),
        ['A', 'b.'],
      );
    },
  );

  test(
    'empty and dot directory targets are excluded without changing input lists',
    () {
      const removed = ['', '.', '..', '.. ', ' ', 'good'];
      const retained = ['keep'];
      expect(
        localChapterDirectoriesToDelete(removed: removed, retained: retained),
        ['good'],
      );
      expect(removed, ['', '.', '..', '.. ', ' ', 'good']);
      expect(retained, ['keep']);
      expect(
        localChapterDirectoriesToDelete(removed: [], retained: retained),
        isEmpty,
      );
    },
  );
}
