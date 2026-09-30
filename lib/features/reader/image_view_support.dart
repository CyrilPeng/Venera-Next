import 'package:flutter/material.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/reader/image_downloads.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/features/reader/waterfall_flow.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';

ImageProvider createReaderImageProviderFromRef(
  WaterfallImageRef imageRef,
  BuildContext context,
) {
  var reader = context.reader;
  return ReaderImageProvider(
    imageRef.imageKey,
    reader.type.comicSource?.key,
    reader.cid,
    imageRef.position.chapterId,
    imageRef.position.imageNumber,
    enableResize: reader.mode.isContinuous,
  );
}

/// [predownloadReaderImage] is used to download the image for the given page.
/// The image is downloaded into the image cache and saved to the local storage.
void predownloadReaderImage(
  int page,
  BuildContext context,
  ReaderImageDownloads downloads,
) {
  if (page <= 0 || page > context.reader.images!.length) {
    return;
  }
  var reader = context.reader;
  var imageKey = reader.images![page - 1];
  if (imageKey.startsWith("file://")) {
    return;
  }
  var cid = reader.cid;
  var eid = reader.eid;
  var sourceKey = reader.type.comicSource?.key;
  downloads.preload(imageKey, sourceKey, cid, eid);
}

void predownloadReaderImageRef(
  WaterfallImageRef imageRef,
  BuildContext context,
  ReaderImageDownloads downloads,
) {
  if (imageRef.imageKey.startsWith("file://")) {
    return;
  }
  var reader = context.reader;
  var sourceKey = reader.type.comicSource?.key;
  downloads.preload(
    imageRef.imageKey,
    sourceKey,
    reader.cid,
    imageRef.position.chapterId,
  );
}
