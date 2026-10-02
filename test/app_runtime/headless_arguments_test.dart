import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/headless_arguments.dart';

void main() {
  test('documented commands preserve selectors and accept global log flag', () {
    for (final direction in ['up', 'down']) {
      final request = parseHeadlessArguments([
        '--ignore-disheadless-log',
        '--headless',
        'webdav',
        direction,
      ]).data;
      expect(request.command, HeadlessCommand.webdav);
      expect(request.subcommand, direction);
    }
    expect(
      parseHeadlessArguments([
        '--headless',
        'updatescript',
        'all',
      ]).data.command,
      HeadlessCommand.updateScript,
    );
    expect(
      parseHeadlessArguments(['--headless', 'updatesubscribe']).data.comic,
      isNull,
    );
    final request = parseHeadlessArguments([
      '--headless',
      'updatesubscribe',
      '--ignore-disheadless-log',
      '--update-comic-by-id-type',
      '漫画 id',
      'source-key',
    ]).data;
    expect(request.comic, (id: '漫画 id', sourceKey: 'source-key'));
  });

  for (final args in <List<String>>[
    [],
    ['webdav', 'up'],
    ['--headless'],
    ['--headless', 'unknown'],
    ['--headless', 'webdav'],
    ['--headless', 'webdav', 'delete'],
    ['--headless', 'webdav', 'up', 'extra'],
    ['--headless', 'updatescript'],
    ['--headless', 'updatescript', 'all', 'extra'],
    ['--headless', 'updatesubscribe', 'extra'],
    ['--headless', 'updatesubscribe', '--update-comic-by-id-type', 'id'],
    [
      '--headless',
      'updatesubscribe',
      '--update-comic-by-id-type',
      '',
      'source',
    ],
    [
      '--headless',
      'updatesubscribe',
      '--update-comic-by-id-type',
      'id',
      '--option',
    ],
    [
      '--headless',
      'updatesubscribe',
      '--update-comic-by-id-type',
      'id',
      'source',
      'extra',
    ],
  ]) {
    test('reject malformed arguments: $args', () {
      expect(parseHeadlessArguments(args).error, isTrue);
    });
  }
}
