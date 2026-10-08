import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/comment_markup.dart';

void main() {
  test('plain content normalizes only CRLF and ampersands', () {
    final result = parseCommentMarkup('中文 &amp; text\r\n&lt;b&gt;\rnext');
    expect(result.textRuns.single.text, '中文 & text\n&lt;b&gt;\rnext');
    expect(result.textRuns.single.tags, isEmpty);
    expect(result.images, isEmpty);
    expect(parseCommentMarkup('').textRuns, isEmpty);
  });

  test(
    'nested tags retain independent ordered snapshots for each text run',
    () {
      final runs = parseCommentMarkup(
        'plain<b>bold<i>both</i>end</b>tail',
      ).textRuns;
      expect(runs.map((e) => e.text), ['plain', 'bold', 'both', 'end', 'tail']);
      expect(runs.map((e) => e.tags.map((t) => t.name).toList()), [
        <String>[],
        ['b'],
        ['b', 'i'],
        ['b'],
        <String>[],
      ]);
    },
  );

  test('all existing formatting tags and CSS attributes are retained', () {
    final result = parseCommentMarkup(
      '<strong><u><s><span style="font-weight:lighter;color:red">text</span></s></u></strong>',
    );
    expect(result.textRuns.single.tags.map((e) => e.name), [
      'strong',
      'u',
      's',
      'span',
    ]);
    expect(result.textRuns.single.tags.last.attributes, {
      'style': 'font-weight:lighter;color:red',
    });
  });

  test('automatic links remain independent from enclosing formatting tags', () {
    final runs = parseCommentMarkup(
      '<b>before https://example.test/a after</b>',
    ).textRuns;
    expect(runs.map((e) => e.text), [
      'before ',
      'https://example.test/a',
      ' after',
    ]);
    expect(runs.map((e) => e.isAutoLink), [false, true, false]);
    expect(runs[1].tags, isEmpty);
    expect(runs[2].tags.single.name, 'b');
  });

  test('explicit anchors preserve attributes and suppress automatic links', () {
    final runs = parseCommentMarkup(
      '<a href="https://example.test/a">https://example.test/b</a>',
    ).textRuns;
    expect(runs.single.isAutoLink, isFalse);
    expect(
      runs.single.tags.single.attributes['href'],
      'https://example.test/a',
    );
    final invalid = parseCommentMarkup(
      '<a href="invalid">https://example.test/b</a>',
    );
    expect(invalid.textRuns.single.isAutoLink, isFalse);
    expect(invalid.textRuns.single.tags.single.attributes['href'], 'invalid');
  });

  test('URL boundaries and validation use the existing dialect', () {
    final runs = parseCommentMarkup(
      'https://example.test/a?one=yes&two=2, https://localhost x',
    ).textRuns;
    expect(runs.where((e) => e.isAutoLink).map((e) => e.text), [
      'https://example.test/a?one=yes&two=2',
    ]);
    expect(
      runs.map((e) => e.text).join(),
      'https://example.test/a?one=yes&two=2, https://localhost x',
    );
  });

  test('images retain order and the first enclosing anchor', () {
    final result = parseCommentMarkup(
      'before<a href="https://outer.test"><a href="https://inner.test">'
      '<img src="first.jpg"></a><img src="second.jpg"></a><img src="third.jpg">after',
    );
    expect(result.images.map((e) => e.url), [
      'first.jpg',
      'second.jpg',
      'third.jpg',
    ]);
    expect(result.images.map((e) => e.link), [
      'https://outer.test',
      'https://outer.test',
      null,
    ]);
    expect(result.textRuns.map((e) => e.text).join(), 'beforeafter');
  });

  test('image tags without a source disappear without creating an image', () {
    final result = parseCommentMarkup('a<img alt="missing">b');
    expect(result.images, isEmpty);
    expect(result.textRuns.map((e) => e.text), ['a', 'b']);
  });

  test('legacy break spellings retain their distinct behavior', () {
    final result = parseCommentMarkup('a<br>b</br>c<br/>d');
    expect(result.textRuns.map((e) => e.text).join(), 'a\nb\nc<br/>d');
  });

  test('unknown and uppercase tags remain literal text', () {
    final result = parseCommentMarkup('<B>upper</B><unknown>text</unknown><');
    expect(result.textRuns.single.text, '<B>upper</B><unknown>text</unknown><');
    expect(result.textRuns.single.tags, isEmpty);
  });

  test('mismatched closing tags remain literal inside the active tag', () {
    final runs = parseCommentMarkup('<b>text</i>tail</b>end').textRuns;
    expect(runs.map((e) => e.text), ['text</i>tail', 'end']);
    expect(runs.first.tags.single.name, 'b');
    expect(runs.last.tags, isEmpty);
  });

  test(
    'legacy attribute splitting is preserved instead of general HTML parsing',
    () {
      final runs = parseCommentMarkup(
        '<a href="https://example.test?a=b" title="two words">link</a>',
      ).textRuns;
      expect(runs.single.tags.single.attributes, {'title': 'two'});
      expect(runs.single.isAutoLink, isFalse);
    },
  );

  test(
    'results and tag attributes cannot be changed through retained inputs',
    () {
      final attributes = {'href': 'https://example.test'};
      final tag = CommentTag('a', attributes);
      final tags = [tag];
      final run = CommentTextRun('link', tags: tags);
      final runs = [run];
      final images = [const CommentImage('image.jpg', null)];
      final result = CommentMarkup(runs, images);
      attributes.clear();
      tags.clear();
      runs.clear();
      images.clear();
      expect(
        result.textRuns.single.tags.single.attributes['href'],
        'https://example.test',
      );
      expect(result.images.single.url, 'image.jpg');
      expect(() => result.textRuns.clear(), throwsUnsupportedError);
      expect(() => result.images.clear(), throwsUnsupportedError);
      expect(() => run.tags.clear(), throwsUnsupportedError);
      expect(() => tag.attributes.clear(), throwsUnsupportedError);
    },
  );
}
