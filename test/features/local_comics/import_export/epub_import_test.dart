import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:venera_next/features/local_comics/import_export/import_export.dart';
import 'package:venera_next/foundation/file_system.dart';

void main() {
  group('EPUB import parser', () {
    test('reads metadata, cover, spine order, and NCX chapters', () {
      final root = _createEpubRoot();
      try {
        _writePackage(
          root,
          manifest: '''
            <item id="cover" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
            <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
          ''',
          spine: '<itemref idref="c1"/><itemref idref="c2"/>',
          spineAttributes: 'toc="toc"',
        );
        _write(root, 'OPS/images/cover.jpg', [0]);
        _write(root, 'OPS/images/001.jpg', [1]);
        _write(root, 'OPS/images/002.png', [2]);
        _writeText(
          root,
          'OPS/text/ch1.xhtml',
          '<html xmlns="http://www.w3.org/1999/xhtml"><body><img src="../images/002.png"/><img src="../images/001.jpg"/></body></html>',
        );
        _writeText(
          root,
          'OPS/text/ch2.xhtml',
          '<html xmlns="http://www.w3.org/1999/xhtml"><body><img src="../images/001.jpg"/></body></html>',
        );
        _writeText(root, 'OPS/toc.ncx', '''
          <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/">
            <navMap>
              <navPoint><navLabel><text>Volume 1</text></navLabel><content src="text/ch1.xhtml"/></navPoint>
              <navPoint><navLabel><text>Volume 2</text></navLabel><content src="text/ch2.xhtml"/></navPoint>
            </navMap>
          </ncx>
          ''');

        final data = EpubComicImporter.inspectExtracted(
          root,
          fallbackTitle: 'Fallback',
        );

        expect(data.title, 'Example Book');
        expect(data.author, 'Example Author');
        expect(data.cover.file.name, 'cover.jpg');
        expect(data.preserveChapters, isTrue);
        expect(data.chapters.map((chapter) => chapter.title), [
          'Volume 1',
          'Volume 2',
        ]);
        expect(data.chapters.first.pages.map((page) => page.file.name), [
          '002.png',
          '001.jpg',
        ]);
      } finally {
        root.parent.deleteSync(recursive: true);
      }
    });

    test('uses EPUB 3 navigation labels as chapters', () {
      final root = _createEpubRoot();
      try {
        _writePackage(
          root,
          manifest: '''
            <item id="p1" href="images/001.jpg" media-type="image/jpeg"/>
            <item id="p2" href="images/002.jpg" media-type="image/jpeg"/>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          ''',
          spine: '<itemref idref="p1"/><itemref idref="p2"/>',
        );
        _write(root, 'OPS/images/001.jpg', [1]);
        _write(root, 'OPS/images/002.jpg', [2]);
        _writeText(root, 'OPS/nav.xhtml', '''
          <html xmlns="http://www.w3.org/1999/xhtml"><body><nav>
            <a href="images/001.jpg">First</a>
            <a href="images/002.jpg">Second</a>
          </nav></body></html>
          ''');

        final data = EpubComicImporter.inspectExtracted(
          root,
          fallbackTitle: 'Fallback',
        );

        expect(data.preserveChapters, isTrue);
        expect(data.chapters.map((chapter) => chapter.title), [
          'First',
          'Second',
        ]);
      } finally {
        root.parent.deleteSync(recursive: true);
      }
    });

    test('flattens direct image spine items without chapter navigation', () {
      final root = _createEpubRoot();
      try {
        _writePackage(
          root,
          manifest: '''
            <item id="p2" href="images/002.png" media-type="image/png"/>
            <item id="p1" href="images/001.jpg" media-type="image/jpeg"/>
          ''',
          spine: '<itemref idref="p2"/><itemref idref="p1"/>',
        );
        _write(root, 'OPS/images/001.jpg', [1]);
        _write(root, 'OPS/images/002.png', [2]);

        final data = EpubComicImporter.inspectExtracted(
          root,
          fallbackTitle: 'Fallback',
        );

        expect(data.preserveChapters, isFalse);
        expect(data.chapters, hasLength(1));
        expect(data.chapters.single.pages.map((page) => page.file.name), [
          '002.png',
          '001.jpg',
        ]);
        expect(data.cover.file.name, '002.png');
      } finally {
        root.parent.deleteSync(recursive: true);
      }
    });

    test('reads the layout produced by the VeneraNext EPUB exporter', () {
      final temp = Directory.systemTemp.createTempSync('epub_import_');
      final root = Directory(FilePath.join(temp.path, 'book'))..createSync();
      try {
        _writeText(root, 'META-INF/container.xml', '''
          <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
          </container>
          ''');
        _writeText(root, 'content.opf', '''
          <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
            <metadata><dc:title>Exported &amp; Imported</dc:title><dc:creator>Author</dc:creator><meta name="cover" content="cover_image"/></metadata>
            <manifest>
              <item id="cover_image" href="OEBPS/images/cover.jpg" media-type="image/jpeg"/>
              <item id="chapter0" href="OEBPS/0.html" media-type="application/xhtml+xml"/>
              <item id="chapter1" href="OEBPS/1.html" media-type="application/xhtml+xml"/>
              <item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            </manifest>
            <spine toc="toc"><itemref idref="chapter0"/><itemref idref="chapter1"/></spine>
          </package>
          ''');
        _write(root, 'OEBPS/images/cover.jpg', [0]);
        _write(root, 'OEBPS/images/img0.jpg', [1]);
        _write(root, 'OEBPS/images/img1.jpg', [2]);
        _writeText(
          root,
          'OEBPS/0.html',
          '<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>One</h1><img src="images/img0.jpg"/></body></html>',
        );
        _writeText(
          root,
          'OEBPS/1.html',
          '<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>Two</h1><img src="images/img1.jpg"/></body></html>',
        );
        _writeText(root, 'toc.ncx', '''
          <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
            <navPoint><navLabel><text>One</text></navLabel><content src="OEBPS/0.html"/></navPoint>
            <navPoint><navLabel><text>Two</text></navLabel><content src="OEBPS/1.html"/></navPoint>
          </navMap></ncx>
          ''');

        final data = EpubComicImporter.inspectExtracted(
          root,
          fallbackTitle: 'Fallback',
        );

        expect(data.title, 'Exported & Imported');
        expect(data.cover.file.name, 'cover.jpg');
        expect(data.chapters.map((chapter) => chapter.title), ['One', 'Two']);
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test('falls back to the first page when cover metadata is stale', () {
      final root = _createEpubRoot();
      try {
        _writePackage(
          root,
          manifest: '''
            <item id="cover" href="images/missing.jpg" media-type="image/jpeg" properties="cover-image"/>
            <item id="page" href="images/001.jpg" media-type="image/jpeg"/>
          ''',
          spine: '<itemref idref="page"/>',
        );
        _write(root, 'OPS/images/001.jpg', [1]);

        final data = EpubComicImporter.inspectExtracted(
          root,
          fallbackTitle: 'Fallback',
        );

        expect(data.cover.file.name, '001.jpg');
      } finally {
        root.parent.deleteSync(recursive: true);
      }
    });

    test('rejects text-only reading content', () {
      final root = _createEpubRoot();
      try {
        _writePackage(
          root,
          manifest:
              '<item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>',
          spine: '<itemref idref="c1"/>',
        );
        _writeText(
          root,
          'OPS/text/ch1.xhtml',
          '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Novel text</p></body></html>',
        );

        expect(
          () => EpubComicImporter.inspectExtracted(
            root,
            fallbackTitle: 'Fallback',
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('Text-based EPUB'),
            ),
          ),
        );
      } finally {
        root.parent.deleteSync(recursive: true);
      }
    });

    test('rejects image references outside the EPUB root', () {
      final root = _createEpubRoot();
      try {
        _writePackage(
          root,
          manifest:
              '<item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>',
          spine: '<itemref idref="c1"/>',
        );
        _writeText(
          root,
          'OPS/text/ch1.xhtml',
          '<html xmlns="http://www.w3.org/1999/xhtml"><body><img src="../../../outside.jpg"/></body></html>',
        );

        expect(
          () => EpubComicImporter.inspectExtracted(
            root,
            fallbackTitle: 'Fallback',
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('escapes the archive'),
            ),
          ),
        );
      } finally {
        root.parent.deleteSync(recursive: true);
      }
    });
  });
}

Directory _createEpubRoot() {
  final temp = Directory.systemTemp.createTempSync('epub_import_');
  final root = Directory(FilePath.join(temp.path, 'book'))..createSync();
  _writeText(root, 'META-INF/container.xml', '''
    <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    ''');
  return root;
}

void _writePackage(
  Directory root, {
  required String manifest,
  required String spine,
  String spineAttributes = '',
}) {
  _writeText(root, 'OPS/package.opf', '''
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>Example Book</dc:title>
        <dc:creator>Example Author</dc:creator>
      </metadata>
      <manifest>$manifest</manifest>
      <spine $spineAttributes>$spine</spine>
    </package>
    ''');
}

void _writeText(Directory root, String relativePath, String content) {
  final file = File(path.joinAll([root.path, ...relativePath.split('/')]));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

void _write(Directory root, String relativePath, List<int> bytes) {
  final file = File(path.joinAll([root.path, ...relativePath.split('/')]));
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
}
