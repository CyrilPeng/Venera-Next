import 'package:venera_next/network/images.dart';

void configureComicSourceImageDownloader({
  required ThumbnailLoadingConfigResolver thumbnailLoadingConfig,
  required ThumbnailCoverResolver thumbnailCover,
  required ComicImageLoadingConfigResolver comicImageLoadingConfig,
}) {
  ImageDownloader.configureSourceImageLoading(
    thumbnailLoadingConfig: thumbnailLoadingConfig,
    thumbnailCover: thumbnailCover,
    comicImageLoadingConfig: comicImageLoadingConfig,
  );
}
