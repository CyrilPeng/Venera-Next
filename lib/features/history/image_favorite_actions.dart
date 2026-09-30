import 'package:venera_next/features/history/image_favorites_models.dart';
import 'package:venera_next/foundation/consts.dart';

enum ImageFavoriteResult {
  collected,
  uncollected,
  protectedCover,
  chapterOrderChanged,
}

/// Metadata captured by the reader adapter; pages remain one-based source pages.
class ImageFavoriteInput {
  const ImageFavoriteInput({
    required this.id,
    required this.sourceKey,
    required this.eid,
    required this.ep,
    required this.epName,
    required this.title,
    required this.subtitle,
    required this.author,
    required this.tags,
    required this.translatedTags,
    required this.maxPage,
    required this.page,
    required this.imageKey,
    required this.coverKey,
  });
  final String id,
      sourceKey,
      eid,
      epName,
      title,
      subtitle,
      author,
      imageKey,
      coverKey;
  final int ep, maxPage, page;
  final List<String> tags, translatedTags;
}

/// Collection policy; the adapter owns storage, translation and UI feedback.
class ImageFavoriteActions {
  ImageFavoriteActions({
    required this.findComic,
    required this.save,
    required this.remove,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final ImageFavoritesComic? Function(String id, String sourceKey) findComic;
  final void Function(ImageFavoritesComic) save;
  final void Function(ImageFavorite) remove;
  final DateTime Function() now;

  ImageFavorite? find(String id, String sourceKey, String eid, int page) {
    final comic = findComic(id, sourceKey);
    final chapter = comic?.imageFavoritesEp
        .where((e) => e.eid == eid)
        .firstOrNull;
    return chapter?.imageFavorites
        .where((image) => image.page == page)
        .firstOrNull;
  }

  ImageFavoriteResult toggle(ImageFavoriteInput data) {
    final liked = find(data.id, data.sourceKey, data.eid, data.page);
    if (liked != null) {
      if (data.page == firstPage && !canUncollectImageFavorite(liked)) {
        return ImageFavoriteResult.protectedCover;
      }
      remove(liked);
      return ImageFavoriteResult.uncollected;
    }
    final comic =
        findComic(data.id, data.sourceKey) ??
        ImageFavoritesComic(
          data.id,
          [],
          data.title,
          data.sourceKey,
          data.tags,
          data.translatedTags,
          now(),
          data.author,
          {},
          data.subtitle,
          data.maxPage,
        );
    final image = ImageFavorite(
      data.page,
      data.imageKey,
      null,
      data.eid,
      data.id,
      data.ep,
      data.sourceKey,
      data.epName,
    );
    var chapter = comic.imageFavoritesEp
        .where((e) => e.ep == data.ep)
        .firstOrNull;
    if (chapter == null) {
      chapter = ImageFavoritesEp(
        data.eid,
        data.ep,
        [
          if (data.page != firstPage)
            image.copyWith(
              page: firstPage,
              isAutoFavorite: true,
              imageKey: data.coverKey,
            ),
          image,
        ],
        data.epName,
        data.maxPage,
      );
      comic.imageFavoritesEp.add(chapter);
    } else {
      if (chapter.eid != data.eid && chapter.eid.isNotEmpty) {
        return ImageFavoriteResult.chapterOrderChanged;
      }
      if (chapter.eid.isEmpty && data.eid.isNotEmpty) {
        // Imported chapters have no source ID. Persist the resolved identity
        // on the chapter and keep existing in-memory image identities aligned.
        chapter.eid = data.eid;
        chapter.imageFavorites = chapter.imageFavorites
            .map((image) => image.copyWith(eid: data.eid))
            .toList();
      }
      chapter.imageFavorites.add(image);
    }
    save(comic);
    return ImageFavoriteResult.collected;
  }
}
