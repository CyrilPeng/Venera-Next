import 'package:venera_next/features/comic_source/comic_source_api.dart';

/// A cover belongs to its presentation, even when another section shows the
/// same comic. Metadata replacements keep that presentation's identity.
class ComicCoverHeroIds {
  static int _nextId = 0;
  final _ids = <(String, String), int>{};

  static int allocate() => _nextId++;

  int forComic(Comic comic) =>
      _ids.putIfAbsent((comic.sourceKey, comic.id), allocate);

  void retain(Iterable<Comic> comics) {
    final identities = {
      for (final comic in comics) (comic.sourceKey, comic.id),
    };
    _ids.removeWhere((identity, _) => !identities.contains(identity));
  }
}
