import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('comic archive user-facing strings are translated', () {
    final translations = Map<String, dynamic>.from(
      jsonDecode(File('assets/translation.json').readAsStringSync()),
    );
    const keys = [
      'Comic Archive',
      'Comic Archive Backup',
      'Archive to WebDAV',
      'Backup Complete',
      'No archive files',
      'Download and Import',
      'Delete selected archive files?',
      'This is only used for CBZ archive backup and restore.',
      '@a archives · @b',
      'Latest',
      'Success: @a',
      'Skipped: @a',
      'Failed: @a',
      'Success: @a, Failed: @b',
      'Deleted: @a, Failed: @b',
      'Sync archive config',
      'Sync archive WebDAV URL, username, password and remote path with app data.',
    ];

    for (final locale in ['zh_CN', 'zh_TW']) {
      final map = Map<String, dynamic>.from(translations[locale] as Map);
      for (final key in keys) {
        expect(map, contains(key), reason: '$locale missing "$key"');
      }
    }
  });
}
