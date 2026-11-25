import 'dart:convert';

import 'package:analyzer/dart/analysis/utilities.dart';

import 'check_translations.dart';

void checkTranslations() {
  final keys = [
    "First Second",
    "Don't",
    r'Raw\n',
    'A\nB',
    'Count @n',
    'One',
    'Two',
  ];
  final dictionaries = {
    'zh_CN': {for (final key in keys) key: key},
    'zh_TW': {for (final key in keys) key: key},
  };
  final fixture = parseString(
    content:
        r'''
void example(bool condition, String dynamicKey) {
  'First '
      'Second'
      .tl;
  'Don\'t'.tl;
  r'Raw\n'.tl;
  ''' +
        "'''A\nB'''" +
        r'''.tl;
  'Count @n'
      .tlParams({'n': 1});
  (condition ? 'One' : 'Two').tl;
  ['One', 'Two'].tl;
  // 'Commented out'.tl
  final sample = "'Inside a string'.tl";
  dynamicKey.tl;
}
''',
  );
  final usage = TranslationUsage(
    'fixture.dart',
    dictionaries,
    fixture.lineInfo,
  );
  fixture.unit.accept(usage);
  if (usage.keys.difference(keys.toSet()).isNotEmpty ||
      keys.toSet().difference(usage.keys).isNotEmpty ||
      usage.errors.isNotEmpty ||
      usage.dynamicTargets != 1) {
    throw StateError(
      'Literal extraction failed: ${usage.keys}, ${usage.errors}',
    );
  }
  void rejects(String content) {
    try {
      readTranslations(content);
    } on FormatException {
      return;
    }
    throw StateError('Invalid dictionary accepted: $content');
  }

  rejects(r'{"zh_CN":{"Key":"first","\u004bey":"second"}}');
  rejects('{"zh_CN":{"Key":"first"},"zh_CN":{"Key":"second"}}');
  rejects('{"zh_CN":{"Key":" "}}');
  rejects('{"zh_CN":{"Key":12}}');
  rejects('[]');
  if (readTranslations(jsonEncode(dictionaries)).length != 2) {
    throw StateError('Valid JSON rejected');
  }
  final invalid = {
    'zh_CN': {'Count @n @n': '數量 @n'},
    'zh_TW': {'Other @x': '其他 @wrong'},
  };
  if (dictionaryErrors(invalid).length != 3) {
    throw StateError('Key/placeholder mismatch was not detected');
  }
  final badCalls = parseString(
    content: """
void example() {
  'Count @n'.tl;
  'Count @n'.tlParams({'wrong': 1});
  'Missing'.tl;
}
""",
  );
  final badUsage = TranslationUsage(
    'bad.dart',
    dictionaries,
    badCalls.lineInfo,
  );
  badCalls.unit.accept(badUsage);
  if (badUsage.errors.length != 4) {
    throw StateError(
      'Missing keys/arguments were not detected: ${badUsage.errors}',
    );
  }
  print('Translation AST and dictionary checks passed');
}
