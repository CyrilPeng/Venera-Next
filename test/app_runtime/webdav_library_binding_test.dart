import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/webdav_library.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/webdav_library/webdav_library_api.dart';

void main() {
  test(
    'remount replaces disposed source callbacks and disabled mount removes source',
    () async {
      final directory = Directory.systemTemp.createTempSync('webdav-mount-');
      final sources = <WebDavLibrarySource>[];
      final manager = ComicSourceManager();
      addTearDown(() async {
        manager.remove(WebDavLibrarySource.sourceKey);
        for (final source in sources) {
          await source.closeAndWait();
        }
        directory.deleteSync(recursive: true);
      });
      WebDavLibraryServices create({required bool enabled}) {
        final values = <String, Object?>{
          'webdavComicLibrary': enabled ? ['https://example.com', '', ''] : [],
        };
        late WebDavLibrarySource source;
        final settings = WebDavLibrarySettingsStore(
          readValue: (key) => values[key],
          persist: (patch) async => values.addAll(patch.toSettings()),
        );
        source = WebDavLibrarySource(
          readSettings: settings.read,
          cache: WebDavLibraryCache('${directory.path}/${sources.length}.db'),
          ops: _Ops(),
        );
        sources.add(source);
        return WebDavLibraryServices(source: source, settings: settings);
      }

      final first = create(enabled: true);
      mountWebDavLibrary(first);
      final oldAdapter = manager.find(WebDavLibrarySource.sourceKey)!;
      first.source.dispose();
      final second = create(enabled: true);
      mountWebDavLibrary(second);
      final adapter = manager.find(WebDavLibrarySource.sourceKey)!;
      expect(adapter, isNot(same(oldAdapter)));
      expect((await adapter.loadComicInfo!('Book')).success, isTrue);
      expect(
        manager.all().where(
          (source) => source.key == WebDavLibrarySource.sourceKey,
        ),
        hasLength(1),
      );
      mountWebDavLibrary(create(enabled: false));
      expect(manager.find(WebDavLibrarySource.sourceKey), isNull);
    },
  );
}

class _Ops extends WebDavLibraryOps {
  @override
  Future<void> test(WebDavLibraryConfig config) async {}

  @override
  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String path,
  ) async => [const WebDavLibraryEntry(name: '001.jpg', isDirectory: false)];

  @override
  Future<String> readText(WebDavLibraryConfig config, String path) async =>
      '{}';
}
