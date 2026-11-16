import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';

void main() {
  group('ComicInfoXml.readNotes', () {
    test('returns the Notes text when present', () {
      const xml = '''
      <ComicInfo>
        <Title>Book</Title>
        <Notes>Chapters: Ch1: 1-2; Ch2: 3-5</Notes>
      </ComicInfo>
      ''';
      expect(ComicInfoXml.readNotes(xml), 'Chapters: Ch1: 1-2; Ch2: 3-5');
    });

    test('returns null when Notes is absent', () {
      const xml = '<ComicInfo><Title>Book</Title></ComicInfo>';
      expect(ComicInfoXml.readNotes(xml), isNull);
    });

    test('returns null on malformed xml', () {
      expect(ComicInfoXml.readNotes('<ComicInfo><Title>Book'), isNull);
    });
  });

  group('ComicInfoXml.readMetadata', () {
    test('reads title, writer and tags', () {
      const xml = '''
      <ComicInfo>
        <Title>My Book</Title>
        <Writer>Author A</Writer>
        <Genre>Action, Adventure</Genre>
        <Tags>fantasy</Tags>
      </ComicInfo>
      ''';
      final meta = ComicInfoXml.readMetadata(xml)!;
      expect(meta.title, 'My Book');
      expect(meta.author, 'Author A');
      expect(meta.tags, ['Action', 'Adventure', 'fantasy']);
    });

    test('reads chapters from Notes', () {
      const xml = '''
      <ComicInfo>
        <Title>My Book</Title>
        <Notes>Chapters: 第01卷 第1章: 1-2; 第02卷 第3章: 3-5</Notes>
      </ComicInfo>
      ''';
      final meta = ComicInfoXml.readMetadata(xml)!;
      expect(meta.chapters, hasLength(2));
      expect(meta.chapters![0].title, '第01卷 第1章');
      expect(meta.chapters![0].start, 1);
      expect(meta.chapters![0].end, 2);
      expect(meta.chapters![1].title, '第02卷 第3章');
      expect(meta.chapters![1].start, 3);
      expect(meta.chapters![1].end, 5);
    });

    test('returns null when title is missing', () {
      const xml = '<ComicInfo><Writer>X</Writer></ComicInfo>';
      expect(ComicInfoXml.readMetadata(xml), isNull);
    });
  });

  group('parseChaptersFromNotes', () {
    test('parses a Venera-exported chapter list', () {
      final chapters = parseChaptersFromNotes(
        'Chapters: 第01卷: 1-2; 第02卷: 3-5',
      )!;
      expect(chapters, hasLength(2));
      expect(chapters[0].title, '第01卷');
      expect(chapters[0].start, 1);
      expect(chapters[0].end, 2);
      expect(chapters[1].title, '第02卷');
      expect(chapters[1].start, 3);
      expect(chapters[1].end, 5);
    });

    test('preserves titles containing colons', () {
      final chapters = parseChaptersFromNotes('Chapters: 番外篇: 特别: 3-4')!;
      expect(chapters, hasLength(1));
      expect(chapters[0].title, '番外篇: 特别');
      expect(chapters[0].start, 3);
      expect(chapters[0].end, 4);
    });

    test('returns null when notes do not carry a chapter list', () {
      expect(parseChaptersFromNotes('Just some notes'), isNull);
      expect(parseChaptersFromNotes(''), isNull);
    });

    test('returns null on overlapping or disordered ranges', () {
      expect(parseChaptersFromNotes('Chapters: B: 1-2; A: 1-3'), isNull);
      expect(parseChaptersFromNotes('Chapters: A: 1-3; B: 3-5'), isNull);
    });
  });
}
