import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/import_export/import_export.dart';

void main() {
  group('CBZ compatibility helpers', () {
    test(
      'compatiblePageFileName pads to four digits and preserves extension',
      () {
        expect(CBZ.compatiblePageFileName(1, 'jpg'), '0001.jpg');
      },
    );

    test(
      'buildComicInfoXmlForTesting includes page metadata without cover',
      () {
        final xml = CBZ.buildComicInfoXmlForTesting(
          ComicMetaData(
            title: 'Title & <Story>',
            author: 'Author "A" & Co',
            tags: ['tag <one>', 'tag & two'],
          ),
          pageCount: 3,
        );

        expect(xml, contains('<Title>Title &amp; &lt;Story&gt;</Title>'));
        expect(xml, contains('<Writer>Author &quot;A&quot; &amp; Co</Writer>'));
        expect(xml, contains('<Tags>tag &lt;one&gt;, tag &amp; two</Tags>'));
        expect(xml, isNot(contains('<Genre>')));
        expect(xml, contains('<PageCount>3</PageCount>'));
        expect(xml, contains('<Manga>Unknown</Manga>'));
        expect(xml, contains('<BlackAndWhite>Unknown</BlackAndWhite>'));
        expect(xml, contains('<Page Image="0" Type="Story" />'));
        expect(xml, contains('<Page Image="1" Type="Story" />'));
        expect(xml, contains('<Page Image="2" Type="Story" />'));
        expect(xml, isNot(contains('Type="FrontCover"')));
      },
    );

    test('buildChapterRangesForTesting calculates contiguous page ranges', () {
      final chapters = CBZ.buildChapterRangesForTesting({
        'Chapter 1': 2,
        'Chapter 2': 3,
      });

      expect(chapters, hasLength(2));
      expect(chapters[0].title, 'Chapter 1');
      expect(chapters[0].start, 1);
      expect(chapters[0].end, 2);
      expect(chapters[1].title, 'Chapter 2');
      expect(chapters[1].start, 3);
      expect(chapters[1].end, 5);
    });

    test('localFilePathFromImageUriForTesting strips file URI prefix', () {
      final result = CBZ.localFilePathFromImageUriForTesting(
        'file:///tmp/a.jpg',
      );

      expect(result.startsWith('file://'), isFalse);
      expect(result, contains('a.jpg'));
    });

    test(
      'localFilePathFromImageUriForTesting leaves plain paths unchanged',
      () {
        const plainPath = '/tmp/a.jpg';

        expect(CBZ.localFilePathFromImageUriForTesting(plainPath), plainPath);
      },
    );
  });
}
