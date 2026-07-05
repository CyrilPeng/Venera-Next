typedef ComicTypeSourceKeyResolver = String? Function(int value);

class ComicType {
  final int value;

  const ComicType(this.value);

  static ComicTypeSourceKeyResolver? _sourceKeyResolver;

  static void configureSourceKeyResolver(ComicTypeSourceKeyResolver? resolver) {
    _sourceKeyResolver = resolver;
  }

  @override
  bool operator ==(Object other) => other is ComicType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  String get sourceKey {
    if (this == local) {
      return "local";
    }
    final sourceKey = _sourceKeyResolver?.call(value);
    if (sourceKey == null) {
      throw StateError("Comic source key not found for $value.");
    }
    return sourceKey;
  }

  static const local = ComicType(0);

  factory ComicType.fromKey(String key) {
    if (key == "local") {
      return local;
    } else {
      return ComicType(key.hashCode);
    }
  }
}
