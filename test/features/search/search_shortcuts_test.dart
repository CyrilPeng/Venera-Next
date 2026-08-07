import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/search/search.dart';

void main() {
  test('search shortcuts round-trip author metadata', () {
    const shortcut = SearchShortcut(
      kind: SearchShortcutKind.author,
      sourceKey: 'example',
      namespace: 'artist',
      value: 'Author Name',
    );

    final restored = SearchShortcut.fromJson(shortcut.toJson());

    expect(restored?.kind, SearchShortcutKind.author);
    expect(restored?.sourceKey, 'example');
    expect(restored?.namespace, 'artist');
    expect(restored?.value, 'Author Name');
    expect(restored?.identity, shortcut.identity);
  });

  test('search shortcut identity keeps sources and kinds separate', () {
    const author = SearchShortcut(
      kind: SearchShortcutKind.author,
      sourceKey: 'source-a',
      namespace: 'author',
      value: 'same name',
    );
    const tag = SearchShortcut(
      kind: SearchShortcutKind.tag,
      sourceKey: 'source-a',
      namespace: 'artist',
      value: 'same name',
    );
    const otherSource = SearchShortcut(
      kind: SearchShortcutKind.author,
      sourceKey: 'source-b',
      namespace: 'author',
      value: 'same name',
    );

    expect({author.identity, tag.identity, otherSource.identity}, hasLength(3));
  });

  test('invalid search shortcut data is ignored', () {
    expect(SearchShortcut.fromJson(null), isNull);
    expect(SearchShortcut.fromJson({'kind': 'unknown'}), isNull);
    expect(
      SearchShortcut.fromJson({
        'kind': 'author',
        'sourceKey': 'example',
        'namespace': 'author',
        'value': '',
      }),
      isNull,
    );
  });
}
