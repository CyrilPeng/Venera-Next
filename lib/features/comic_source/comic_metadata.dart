import 'dart:async';

typedef ComicMetadataPublicationFactory =
    Future<void> Function(String cover)? Function(
      String sourceKey,
      String comicId,
    );

ComicMetadataPublicationFactory? _publicationFactory;

/// Composition captures existing storage/source identities before a read.
/// Source parsing retains no dependency on favorites, history or the window.
void configureComicMetadataPublication([
  ComicMetadataPublicationFactory? factory,
]) {
  _publicationFactory = factory;
}

Future<void> Function(String)? captureComicMetadataPublication(
  String sourceKey,
  String id,
) => _publicationFactory?.call(sourceKey, id);
