import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/app.dart';

import 'image_favorites_repository_test.dart' show comic;

void main() {
  setUpAll(() => App.cachePath = Directory.systemTemp.path);
  for (final removed in [true, false]) {
    test(
      'cache read failure is a miss only after eviction: $removed',
      () async {
        final root = Directory.systemTemp.createTempSync('image-cache-race-');
        final file = File('${root.path}/cached')..writeAsBytesSync([1]);
        final error = FileSystemException('injected read failure', file.path);
        final racing = _ReadRaceFile(file, error, removed);
        try {
          await IOOverrides.runZoned(() async {
            final provider = ImageFavoritesProvider(
              comic('cached').images.single,
            );
            if (removed) {
              expect(await provider.readFromCache(), isNull);
            } else {
              await expectLater(provider.readFromCache(), throwsA(same(error)));
            }
            expect(racing.reads, 1);
          }, createFile: (_) => racing);
          expect(file.existsSync(), !removed);
        } finally {
          root.deleteSync(recursive: true);
        }
      },
    );
  }
}

class _ReadRaceFile implements File {
  _ReadRaceFile(this.file, this.error, this.removeBeforeRead);

  final File file;
  final FileSystemException error;
  final bool removeBeforeRead;
  int reads = 0;

  @override
  bool existsSync() => file.existsSync();

  @override
  Future<Uint8List> readAsBytes() async {
    reads++;
    if (removeBeforeRead) await file.delete();
    throw error;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
