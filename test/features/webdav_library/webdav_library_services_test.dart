import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/webdav_library/webdav_library_api.dart';
import 'package:venera_next/features/webdav_library/webdav_library_discovery.dart';
import 'package:venera_next/features/webdav_library/webdav_library_session.dart';
import 'package:venera_next/features/webdav_library/webdav_library_snapshot_builder.dart';

void main() {
  late _Ops ops;
  late WebDavLibrarySession session;
  setUp(() {
    ops = _Ops();
    session = WebDavLibrarySession(
      WebDavLibraryConfig(
        url: 'https://example.com',
        user: '',
        pass: '',
        remotePath: '/books/',
      ),
      ops,
      isCurrent: () => true,
    );
  });

  test(
    'discovery uses explicit reuse policy without reading reused directories',
    () async {
      final directories = await WebDavLibraryDiscovery(session).discover(
        rootEntries: [
          const WebDavLibraryEntry(name: 'Book 10', isDirectory: true),
          const WebDavLibraryEntry(name: 'Book 2', isDirectory: true),
          const WebDavLibraryEntry(name: 'backup.cbz', isDirectory: false),
        ],
        canReuse: (directory) => directory.name == 'Book 2',
      );
      expect(directories.map((entry) => entry.id), ['Book 2', 'Book 10']);
      expect(ops.paths, ['/books/Book 10/']);
    },
  );

  test(
    'discovery caps directory reads at the existing 2000-entry budget',
    () async {
      final directories = await WebDavLibraryDiscovery(session).discover(
        rootEntries: List.generate(
          2001,
          (i) => WebDavLibraryEntry(name: 'Book $i', isDirectory: true),
        ),
        canReuse: (_) => false,
      );
      expect(ops.paths, hasLength(2000));
      expect(directories, hasLength(2000));
      expect(directories.last.id, 'Book 1999');
    },
  );

  test(
    'deep category traversal stops before an unbounded directory chain',
    () async {
      ops.read = (_) async => [
        const WebDavLibraryEntry(name: 'nested', isDirectory: true),
      ];
      final directories = await WebDavLibraryDiscovery(session).discover(
        rootEntries: [
          const WebDavLibraryEntry(name: 'Category', isDirectory: true),
        ],
        canReuse: (_) => false,
      );
      expect(ops.paths, hasLength(9));
      expect(directories.single.id, 'Category');
    },
  );

  test(
    'snapshot service builds and round-trips metadata chapters without storage',
    () async {
      ops.metadata = jsonEncode({
        'title': 'A Book',
        'author': 'Author',
        'tags': ['Tag'],
        'chapters': [
          {'title': 'Opening', 'start': 1, 'end': 2},
        ],
      });
      final snapshot = await WebDavLibrarySnapshotBuilder(session).build(
        'Book',
        rootEntries: [
          const WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
          const WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
          const WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
          const WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
        ],
      );
      expect(snapshot.title, 'A Book');
      expect(snapshot.cover, '/books/Book/cover.jpg');
      expect(snapshot.rootImages.map((entry) => entry.name), [
        '001.jpg',
        '002.jpg',
      ]);
      expect(snapshot.chapters, {'__cbz_range_0': 'Opening'});
      final serialized =
          jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, dynamic>;
      expect(serialized['formatVersion'], 3);
      expect(
        WebDavComicSnapshot.fromJson(serialized).toJson(),
        snapshot.toJson(),
      );
      expect(ops.paths, isEmpty);
    },
  );

  test(
    'discovery propagates cancellation instead of returning fallback entries',
    () async {
      final response = Completer<List<WebDavLibraryEntry>>();
      ops.read = (_) => response.future;
      final pending = WebDavLibraryDiscovery(session).discover(
        rootEntries: [
          const WebDavLibraryEntry(name: 'Book', isDirectory: true),
        ],
        canReuse: (_) => false,
      );
      session.cancel();
      response.complete([]);
      await expectLater(pending, throwsA(isA<WebDavLibraryCancelled>()));
    },
  );
}

class _Ops extends WebDavLibraryOps {
  final paths = <String>[];
  String metadata = '{}';
  Future<List<WebDavLibraryEntry>> Function(String) read = (_) async => [];

  @override
  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String path,
  ) {
    paths.add(path);
    return read(path);
  }

  @override
  Future<String> readText(WebDavLibraryConfig config, String path) async =>
      metadata;

  @override
  Future<void> test(WebDavLibraryConfig config) async {}
}
