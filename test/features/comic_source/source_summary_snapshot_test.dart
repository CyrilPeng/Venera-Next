import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/source.dart';
import 'package:venera_next/features/comic_source/source_summary_snapshot.dart';

class _Source extends Fake implements ComicSource {
  _Source(this.key, this.name, this.version);
  @override
  final String key;
  @override
  final String name;
  @override
  final String version;
}

void main() {
  test(
    'summary preserves name order and counts newer installed versions once',
    () {
      final sources = <ComicSource>[
        _Source('one', 'First', '1.0.0'),
        _Source('two', 'Second', '2.0.0'),
        _Source('three', 'Third', '1.0.0-alpha'),
        _Source('one', 'Duplicate identity', '99.0.0'),
      ];
      final updates = {
        'one': '1.0.0-hotfix',
        'two': '1.9.9',
        'three': '1.0.0',
        'uninstalled': 'invalid',
      };
      final summary = ComicSourceSummarySnapshot.fromSources(sources, updates);
      sources.clear();
      updates.clear();
      expect(summary.names, ['First', 'Second', 'Third', 'Duplicate identity']);
      expect(summary.availableUpdates, 2);
      expect(() => summary.names.clear(), throwsUnsupportedError);
    },
  );

  test('equal, older and missing versions do not become available updates', () {
    final sources = [
      _Source('equal', 'Equal', '2.3.4'),
      _Source('newer', 'Newer', '2.3.5'),
      _Source('no-update', 'No update', '1.0.0'),
    ];
    final summary = ComicSourceSummarySnapshot.fromSources(sources, {
      'equal': '2.3.4',
      'newer': '2.3.4',
    });
    expect(summary.availableUpdates, 0);
    expect(const ComicSourceSummarySnapshot.empty().names, isEmpty);
  });
}
