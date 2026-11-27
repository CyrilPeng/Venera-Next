import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/comic_cover.dart';
import 'package:venera_next/foundation/cover_cache_record.dart';
import 'package:venera_next/network/images.dart';

Uint8List coverPng(int red) => Uint8List.fromList(
  img.encodePng(
    img.Image(width: 1, height: 1)..setPixelRgba(0, 0, red, 30, 40, 255),
  ),
);

class CoverCacheFixture {
  CoverCacheFixture({
    ComicCoverMetadataLoader? metadata,
    ComicCoverImageLoader? image,
    void Function() Function(ComicCoverIdentity)? captureOwner,
    bool decode = true,
    bool autoDispose = true,
  }) {
    root = Directory.systemTemp.createTempSync('venera-cover-cache-');
    cache = CacheManager.open(dataPath: root.path, cacheRoot: root.path);
    manager = ComicCoverManager(
      cache: cache,
      now: () => now,
      validateImage: decode ? null : (_) async {},
      captureOwner: captureOwner,
      loadMetadata:
          metadata ??
          (identity, scope) async {
            metadataCalls++;
            return ComicCoverMetadata(url, (cover, check) async {
              check();
              publications.add((identity, cover));
            });
          },
      loadImage:
          image ??
          (url, identity, scope, previous, cachedBytes, force) async {
            imageCalls++;
            forced.add(force);
            return ThumbnailRefreshResult(
              bytes: bytes,
              validators: const ThumbnailValidators(
                requestKey: 'test-request',
                etag: 'test-etag',
              ),
              notModified: false,
            );
          },
    );
    if (autoDispose) {
      addTearDown(() async {
        await manager.dispose();
        await cache.dispose();
        await root.delete(recursive: true);
      });
    }
  }

  late final Directory root;
  late final CacheManager cache;
  late final ComicCoverManager manager;
  DateTime now = DateTime.utc(2026, 11, 27);
  String url = 'https://fixture.invalid/old.png';
  Uint8List bytes = coverPng(100);
  int metadataCalls = 0;
  int imageCalls = 0;
  final publications = <(ComicCoverIdentity, String)>[];
  final forced = <bool>[];
}

Future<void> coverChanged(
  ComicCoverLease lease,
  bool Function(ComicCoverSnapshot) matches,
) {
  if (matches(lease.snapshot)) return Future.value();
  final changed = Completer<void>();
  void listener() {
    if (matches(lease.snapshot) && !changed.isCompleted) changed.complete();
  }

  lease.changes.addListener(listener);
  return changed.future
      .timeout(const Duration(seconds: 10))
      .whenComplete(() => lease.changes.removeListener(listener));
}
