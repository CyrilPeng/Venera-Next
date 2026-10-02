import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/sync/data_sync_archive_order.dart';

void main() {
  test(
    'dates and versions compare numerically with stable leading-zero ties',
    () {
      final names = [
        '10-1.venera',
        '2-10.venera',
        '2-9.venera',
        '02-009.venera',
      ];
      names.sort(compareDataSyncArchiveNames);
      expect(names, [
        '02-009.venera',
        '2-9.venera',
        '2-10.venera',
        '10-1.venera',
      ]);
    },
  );

  test(
    'legacy names and arbitrarily large numeric fields have a total order',
    () {
      final names = [
        '',
        '0',
        '00',
        '-',
        '0-a',
        '00-1',
        '2-9.venera',
        '2-10.venera',
        '9999999999999999999999999-1.venera',
        '10000000000000000000000000-1.venera',
        'backup.venera',
        'backup2.venera',
        'backup10.venera',
        '../20-8.venera',
      ]..sort(compareDataSyncArchiveNames);
      for (var i = 0; i < names.length; i++) {
        expect(compareDataSyncArchiveNames(names[i], names[i]), 0);
        for (var j = i + 1; j < names.length; j++) {
          expect(compareDataSyncArchiveNames(names[i], names[j]), lessThan(0));
          expect(
            compareDataSyncArchiveNames(names[j], names[i]),
            greaterThan(0),
          );
        }
      }
      expect(
        names.indexOf('backup2.venera'),
        lessThan(names.indexOf('backup10.venera')),
      );
      expect(
        names.indexOf('9999999999999999999999999-1.venera'),
        lessThan(names.indexOf('10000000000000000000000000-1.venera')),
      );
    },
  );
}
