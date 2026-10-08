enum SearchShortcutKind { author, tag }

class SearchShortcut {
  const SearchShortcut({
    required this.kind,
    required this.sourceKey,
    required this.namespace,
    required this.value,
  });

  final SearchShortcutKind kind;
  final String sourceKey;
  final String namespace;
  final String value;

  bool get isAuthor => kind == SearchShortcutKind.author;

  String get identity =>
      '$sourceKey\u0000${kind.name}\u0000$namespace\u0000$value';

  Map<String, dynamic> toJson() {
    return {
      'kind': kind.name,
      'sourceKey': sourceKey,
      'namespace': namespace,
      'value': value,
    };
  }

  static SearchShortcut? fromJson(dynamic value) {
    if (value is! Map) return null;
    final kindValue = value['kind'];
    final sourceKey = value['sourceKey'];
    final namespace = value['namespace'];
    final shortcutValue = value['value'];
    if (kindValue is! String ||
        sourceKey is! String ||
        namespace is! String ||
        shortcutValue is! String ||
        sourceKey.trim().isEmpty ||
        namespace.trim().isEmpty ||
        shortcutValue.trim().isEmpty) {
      return null;
    }

    final kind = switch (kindValue) {
      'author' => SearchShortcutKind.author,
      'tag' => SearchShortcutKind.tag,
      _ => null,
    };
    if (kind == null) return null;
    return SearchShortcut(
      kind: kind,
      sourceKey: sourceKey.trim(),
      namespace: namespace.trim(),
      value: shortcutValue.trim(),
    );
  }
}
