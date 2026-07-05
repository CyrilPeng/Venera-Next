import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/file_system.dart';

void main() {
  group('sanitizeFileNameWithSuffix', () {
    test('builds {title}{middle}{extension} for a normal case', () {
      final filename = sanitizeFileNameWithSuffix(
        'Naruto',
        middle: '_EP5_P12',
        extension: '.png',
      );

      expect(filename, 'Naruto_EP5_P12.png');
    });

    test('keeps extension and middle intact within the byte budget', () {
      const middle = '_EP999999_P999999';
      const extension = '.webp';
      final filename = sanitizeFileNameWithSuffix(
        '😀' * 80,
        middle: middle,
        extension: extension,
      );

      expect(filename.endsWith('$middle$extension'), isTrue);
      expect(
        utf8.encode(filename).length,
        lessThanOrEqualTo(maxExportFileNameUtf8Bytes),
      );
    });

    test('keeps ordinary CJK titles readable under the byte budget', () {
      final filename = sanitizeFileNameWithSuffix(
        '漫画标题' * 30,
        middle: '_EP1_P1',
        extension: '.jpg',
      );

      expect(filename.endsWith('_EP1_P1.jpg'), isTrue);
      expect(
        utf8.encode(filename).length,
        lessThanOrEqualTo(maxExportFileNameUtf8Bytes),
      );
      expect(filename.startsWith('漫画标题'), isTrue);
    });

    test('uses fallback when sanitizing leaves no title', () {
      final filename = sanitizeFileNameWithSuffix(
        '////::::****',
        middle: '_EP1_P1',
        extension: '.jpg',
        fallback: 'image',
      );

      expect(filename, 'image_EP1_P1.jpg');
    });

    test('handles ASCII titles correctly', () {
      final filename = sanitizeFileNameWithSuffix(
        'A' * 100,
        middle: '_EP1_P1',
        extension: '.jpg',
      );

      expect(filename.endsWith('_EP1_P1.jpg'), isTrue);
      expect(
        utf8.encode(filename).length,
        lessThanOrEqualTo(maxExportFileNameUtf8Bytes),
      );
    });

    test('handles Japanese precomposed characters', () {
      // じ is a single precomposed code point (U+3058).
      final filename = sanitizeFileNameWithSuffix(
        'じ' * 50,
        middle: '_EP1_P1',
        extension: '.jpg',
      );

      expect(filename.endsWith('_EP1_P1.jpg'), isTrue);
      expect(
        utf8.encode(filename).length,
        lessThanOrEqualTo(maxExportFileNameUtf8Bytes),
      );
    });

    test('falls back when both fileName and fallback sanitize to empty', () {
      final filename = sanitizeFileNameWithSuffix(
        '???',
        middle: '_EP1_P1',
        extension: '.jpg',
        fallback: 'comic',
      );

      expect(filename, 'comic_EP1_P1.jpg');
    });

    test('handles a long extension and CJK middle', () {
      const middle = '_EP第9999话_P9999';
      const extension = '.png';
      final filename = sanitizeFileNameWithSuffix(
        '漫画标题' * 20,
        middle: middle,
        extension: extension,
      );

      expect(filename.endsWith('$middle$extension'), isTrue);
      expect(
        utf8.encode(filename).length,
        lessThanOrEqualTo(maxExportFileNameUtf8Bytes),
      );
    });

    test('respects custom maxUtf8Bytes parameter', () {
      final filename = sanitizeFileNameWithSuffix(
        '漫画标题' * 20,
        middle: '_EP1_P1',
        extension: '.jpg',
        maxUtf8Bytes: 100,
      );

      expect(utf8.encode(filename).length, lessThanOrEqualTo(100));
      expect(filename.endsWith('_EP1_P1.jpg'), isTrue);
    });

    test('sanitizes invalid characters in middle (chapter title)', () {
      // A chapter name containing a path separator must not leak through.
      final filename = sanitizeFileNameWithSuffix(
        '漫画标题',
        middle: '_EP第1卷/前篇_P1',
        extension: '.png',
      );

      expect(filename.contains('/'), isFalse);
      expect(filename.endsWith('.png'), isTrue);
      expect(filename.contains('第1卷'), isTrue);
      expect(filename.contains('前篇'), isTrue);
    });

    test('sanitizes all invalid path characters in middle and extension', () {
      final filename = sanitizeFileNameWithSuffix(
        'title',
        middle: r'_EP<>:"/\|?*_P1',
        extension: r'.p<n>g',
      );

      for (final c in ['<', '>', ':', '"', '/', r'\', '|', '?', '*']) {
        expect(
          filename.contains(c),
          isFalse,
          reason: 'should not contain "$c": $filename',
        );
      }
    });

    test('caps title at maxSanitizedFileNameLength characters', () {
      final filename = sanitizeFileNameWithSuffix(
        'A' * 300,
        middle: '_EP1_P1',
        extension: '.jpg',
      );
      // Title length must not exceed the soft char cap.
      final tail = '_EP1_P1.jpg';
      final titlePart = filename.substring(0, filename.length - tail.length);
      expect(titlePart.length, lessThanOrEqualTo(maxSanitizedFileNameLength));
    });

    test('preserves extension when middle alone exceeds the budget', () {
      final filename = sanitizeFileNameWithSuffix(
        'title',
        middle: '_${'A' * 200}',
        extension: '.png',
        maxUtf8Bytes: 100,
      );

      expect(utf8.encode(filename).length, lessThanOrEqualTo(100));
      expect(filename.endsWith('.png'), isTrue);
    });

    test('truncates extension only when extension alone overflows', () {
      final filename = sanitizeFileNameWithSuffix(
        'title',
        middle: '_EP1_P1',
        extension: '.${'X' * 200}',
        maxUtf8Bytes: 50,
      );

      expect(utf8.encode(filename).length, lessThanOrEqualTo(50));
    });

    test('does not throw when fallback contains only invalid chars', () {
      expect(
        () => sanitizeFileNameWithSuffix(
          '???',
          middle: '_EP1_P1',
          extension: '.jpg',
          fallback: '////',
        ),
        returnsNormally,
      );
    });

    test('preserves trailing whitespace inside middle byte-faithfully', () {
      // Middle ends with a legitimate space; not invalid-char-derived.
      // The sanitizer must not strip it.
      const middle = '_EP1_P1 ';
      final filename = sanitizeFileNameWithSuffix(
        'title',
        middle: middle,
        extension: '.png',
      );

      expect(filename, 'title$middle.png');
    });

    test('handles a long title combined with a long middle', () {
      final filename = sanitizeFileNameWithSuffix(
        '漫画标题' * 30,
        middle: '_EP${'章' * 40}_P9999',
        extension: '.png',
      );

      expect(filename.endsWith('.png'), isTrue);
      expect(
        utf8.encode(filename).length,
        lessThanOrEqualTo(maxExportFileNameUtf8Bytes),
      );
      // Title is still represented even with a heavy middle.
      expect(filename.startsWith('漫画标题'), isTrue);
    });
  });
}
