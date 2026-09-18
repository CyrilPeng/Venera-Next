import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/reader/reader_page.dart';

void main() {
  test(
    'viewport initialization does not overwrite saved progress before loading',
    () {
      final history = History.fromMap({
        'id': '1',
        'type': 0,
        'time': 1000,
        'title': 'Book',
        'subtitle': '',
        'cover': '',
        'ep': 2,
        'page': 10,
        'max_page': 20,
      });
      final reader = ReaderState()..history = history;
      reader.page = 1;
      expect(history.page, 10);
      expect(history.ep, 2);
      expect(history.time.millisecondsSinceEpoch, 1000);
      reader.images = List.filled(20, 'page');
      reader.isLoading = true;
      reader.page = 2;
      expect(history.page, 10);
    },
  );
}
