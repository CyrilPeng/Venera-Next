/// HTTP validators describe the original response, before a source transforms
/// image bytes. They are reusable only for the same configured request.
class ThumbnailValidators {
  const ThumbnailValidators({
    required this.requestKey,
    this.etag,
    this.lastModified,
  });

  final String requestKey;
  final String? etag;
  final String? lastModified;
}

/// Cover freshness is independent of the disk cache's access-based eviction.
class CoverCacheRecord {
  const CoverCacheRecord({
    required this.url,
    required this.cacheKey,
    required this.checkedAt,
    required this.validators,
  });

  final String url;
  final String cacheKey;
  final DateTime checkedAt;
  final ThumbnailValidators validators;
}
