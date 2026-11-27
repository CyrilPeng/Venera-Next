import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:venera_next/network/image_http_client.dart';
import 'package:venera_next/network/image_loading_config.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/request_scope.dart';

import 'cache_manager.dart';
import 'cover_cache_record.dart';
import 'log.dart';

@immutable
class ComicCoverIdentity {
  const ComicCoverIdentity(this.sourceKey, this.id);
  final String sourceKey;
  final String id;
  String get storageKey => jsonEncode([sourceKey, id]);
  @override
  bool operator ==(Object other) =>
      other is ComicCoverIdentity &&
      sourceKey == other.sourceKey &&
      id == other.id;
  @override
  int get hashCode => Object.hash(sourceKey, id);
}

class ComicCoverMetadata {
  const ComicCoverMetadata(this.url, this.publish);
  final String url;
  final Future<void> Function(String url, void Function() checkActive) publish;
}

class ComicCoverSnapshot {
  const ComicCoverSnapshot(this.url, this.cacheKey);
  final String url;
  final String? cacheKey;
}

typedef ComicCoverMetadataLoader =
    Future<ComicCoverMetadata?> Function(
      ComicCoverIdentity identity,
      RequestScope scope,
    );
typedef ComicCoverImageLoader =
    Future<ThumbnailRefreshResult> Function(
      String url,
      ComicCoverIdentity identity,
      RequestScope scope,
      CoverCacheRecord? previous,
      Uint8List? cachedBytes,
      bool force,
    );

/// Visible covers own leases. Metadata reads and conditional image requests
/// share two slots, fixed freshness, cancellation and a bounded memory cache.
/// Database/source ownership is captured by the application composition layer.
class ComicCoverManager {
  ComicCoverManager({
    required this.cache,
    required ComicCoverMetadataLoader loadMetadata,
    ComicCoverImageLoader? loadImage,
    Future<void> Function(Uint8List)? validateImage,
    DateTime Function()? now,
    void Function() Function(ComicCoverIdentity)? captureOwner,
    this.freshness = const Duration(hours: 24),
    this.retryDelay = const Duration(minutes: 5),
  }) : _loadMetadata = loadMetadata,
       _loadImage = loadImage ?? _download,
       _validateImage = validateImage ?? _validate,
       _captureOwner = captureOwner,
       _now = now ?? DateTime.now;

  static ComicCoverManager? instance;
  static final _metadataZone = Object();
  static bool get isRefreshingMetadata => Zone.current[_metadataZone] == true;
  final CacheManager cache;
  final ComicCoverMetadataLoader _loadMetadata;
  final ComicCoverImageLoader _loadImage;
  final Future<void> Function(Uint8List) _validateImage;
  final void Function() Function(ComicCoverIdentity)? _captureOwner;
  final DateTime Function() _now;
  final Duration freshness;
  final Duration retryDelay;
  final _entries = <ComicCoverIdentity, _CoverEntry>{};
  final _tasks = <Future<void>, RequestScope>{};
  final _cleanupFailures = <Object>[];
  final _waiters = Queue<Completer<void>>();
  int _running = 0;
  bool _held = false;
  bool _closed = false;
  Future<void>? _disposal;
  Future<void Function()>? _preparation;
  bool get isClosed => _closed;

  static Future<ThumbnailRefreshResult> _download(
    String url,
    ComicCoverIdentity identity,
    RequestScope scope,
    CoverCacheRecord? previous,
    Uint8List? bytes,
    bool force,
  ) => ImageDownloader.refreshThumbnail(
    url,
    identity.sourceKey,
    identity.id,
    scope,
    validators: previous?.url == url ? previous?.validators : null,
    cachedBytes: bytes,
    force: force,
  );

  static Future<void> _validate(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width <= 0 || descriptor.height <= 0) {
        throw const FormatException('Invalid cover image');
      }
      codec = await descriptor.instantiateCodec(
        targetWidth: descriptor.width > 64 ? 64 : descriptor.width,
        targetHeight: descriptor.height > 64 ? 64 : descriptor.height,
      );
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  _CoverEntry _entry(ComicCoverIdentity identity, String url) {
    final existing = _entries.remove(identity);
    if (existing != null) {
      _entries[identity] = existing;
      if (existing.url.isEmpty) existing.url = url;
      return existing;
    }
    final entry = _CoverEntry(identity, url);
    _entries[identity] = entry;
    entry.ready = cache.readCoverRecord(identity.storageKey).then((record) {
      entry.record = record;
      if (record != null) {
        entry.url = record.url;
        entry.cacheKey = record.cacheKey;
        if (entry.metadataUrl == null) {
          entry.nextAttempt = record.checkedAt.add(freshness);
        }
        entry.publish();
      }
    });
    // An inactive record is still a read owned by this manager's cache, whose
    // serialized queue is drained by the bootstrap after this producer stops.
    entry.ready.catchError((Object error, StackTrace stack) {
      Log.error('Cover cache', error, stack);
    });
    _trim();
    return entry;
  }

  void _trim() {
    if (_entries.length <= 512) return;
    for (final entry in _entries.values.toList()) {
      if (entry.leases == 0 && entry.work == null) {
        _entries.remove(entry.identity);
        entry.sequence++;
        entry.timer?.cancel();
        // A record read can still publish into this notifier.
        entry.ready.then<void>(
          (_) => entry.dispose(),
          onError: (Object _, StackTrace _) => entry.dispose(),
        );
      }
      if (_entries.length <= 512) break;
    }
  }

  ComicCoverLease acquire(ComicCoverIdentity identity, String url) {
    if (_closed) throw StateError('Comic covers are closed');
    final entry = _entry(identity, url);
    entry.leases++;
    _schedule(entry);
    return ComicCoverLease._(this, entry);
  }

  void _release(_CoverEntry entry) {
    entry.leases--;
    if (entry.leases == 0) {
      entry.timer?.cancel();
      entry.timer = null;
      entry.scope?.cancel();
    }
    _trim();
  }

  /// Capture before a source request, not after it. A newer request or a closed
  /// producer invalidates both this publication and its queued database writes.
  Future<void> Function(String) captureMetadata(
    ComicCoverIdentity identity,
    Future<void> Function(String, void Function()) persist,
  ) {
    final entry = _entry(identity, '');
    final sequence = ++entry.sequence;
    void check() {
      if (_closed ||
          _held ||
          entry.sequence != sequence ||
          !identical(_entries[identity], entry)) {
        throw const RequestCancelled();
      }
    }

    return (url) async {
      check();
      if (url.trim().isEmpty || url.startsWith('file://')) return;
      await entry.ready;
      check();
      await persist(url, check);
      check();
      final sameUrl = url == (entry.metadataUrl ?? entry.record?.url);
      entry.metadataUrl = url;
      entry.metadataCheckedAt = _now();
      // Reading details with the same URL has not revalidated the image.
      if (sameUrl) return;
      entry.nextAttempt = _now();
      entry.scope?.cancel();
      _schedule(entry);
    };
  }

  void _schedule(_CoverEntry entry) {
    if (_closed ||
        _held ||
        _cleanupFailures.isNotEmpty ||
        entry.leases == 0 ||
        entry.work != null) {
      return;
    }
    entry.timer?.cancel();
    final delay = entry.nextAttempt?.difference(_now()) ?? Duration.zero;
    if (delay > Duration.zero) {
      entry.timer = Timer(delay, () => _schedule(entry));
      return;
    }
    _start(entry, false).catchError((Object error, StackTrace stack) {
      if (error is! RequestCancelled && error is! TimeoutException) {
        Log.error('Cover refresh', error, stack);
      }
    });
  }

  ComicCoverSnapshot? snapshotFor(ComicCoverIdentity identity) {
    final entry = _entries[identity];
    return entry == null ? null : ComicCoverSnapshot(entry.url, entry.cacheKey);
  }

  void reportMissingVersion(ComicCoverIdentity identity, String cacheKey) {
    final entry = _entries[identity];
    if (_closed || entry == null || entry.cacheKey != cacheKey) return;
    entry.cacheKey = null;
    entry.nextAttempt = null;
    entry.publish();
    _schedule(entry);
  }

  Future<void> refresh(
    ComicCoverIdentity identity,
    String url, {
    RequestScope? parent,
  }) async {
    if (_closed || _held) throw const RequestCancelled();
    if (_cleanupFailures.isNotEmpty) {
      throw ComicCoverCleanupFailure(_cleanupFailures);
    }
    parent?.check();
    final entry = _entry(identity, url);
    entry.leases++;
    final lease = ComicCoverLease._(this, entry);
    try {
      final pending = lease._entry.work;
      if (pending != null) {
        try {
          await pending;
        } catch (error) {
          if (_cleanupFailure(error)) rethrow;
        }
      }
      parent?.check();
      if (_closed || _held) throw const RequestCancelled();
      await _start(lease._entry, true, parent: parent);
    } finally {
      lease.release();
    }
  }

  Future<void> _start(_CoverEntry entry, bool force, {RequestScope? parent}) {
    if (entry.work != null) return entry.work!;
    final scope = RequestScope(
      parent: parent,
      timeout: const Duration(seconds: 45),
      bypassCache: true,
    );
    entry.scope = scope;
    final work = Future<void>.microtask(() => _run(entry, scope, force));
    entry.work = work;
    _tasks[work] = scope;
    void finished() {
      _tasks.remove(work);
      entry.work = null;
      entry.scope = null;
      scope.dispose();
      _schedule(entry);
      _trim();
    }

    work.then<void>(
      (_) => finished(),
      onError: (Object error, StackTrace _) {
        if (_cleanupFailure(error)) _cleanupFailures.add(error);
        finished();
      },
    );
    return work;
  }

  Future<void> _acquireSlot(RequestScope scope) async {
    scope.check();
    if (_running < 2) {
      _running++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    try {
      await scope.runToCompletion(
        () => Future.any([
          waiter.future,
          scope.whenCancelled.then<void>((_) => scope.check()),
        ]),
      );
    } catch (_) {
      if (!_waiters.remove(waiter)) _releaseSlot();
      rethrow;
    }
  }

  void _releaseSlot() {
    if (_waiters.isEmpty) {
      _running--;
    } else {
      _waiters.removeFirst().complete();
    }
  }

  Future<void> _run(_CoverEntry entry, RequestScope scope, bool force) async {
    var slot = false;
    int? sequence;
    void Function()? ownerCheck;
    void check() {
      scope.check();
      ownerCheck?.call();
      if (_closed ||
          _held ||
          (sequence != null && entry.sequence != sequence)) {
        throw const RequestCancelled();
      }
    }

    try {
      await entry.ready;
      check();
      if (!force && entry.nextAttempt?.isAfter(_now()) == true) return;
      await _acquireSlot(scope);
      slot = true;
      ownerCheck = _captureOwner?.call(entry.identity);
      check();
      sequence = ++entry.sequence;
      ComicCoverMetadata? metadata;
      if (force ||
          entry.metadataUrl == null ||
          !entry.metadataCheckedAt!.add(freshness).isAfter(_now())) {
        metadata = await runZoned(
          () =>
              scope.runToCompletion(() => _loadMetadata(entry.identity, scope)),
          zoneValues: {_metadataZone: true},
        );
        check();
      }
      final url = metadata?.url ?? entry.metadataUrl ?? entry.url;
      if (url.isEmpty || url.startsWith('file://')) {
        throw const FormatException('Invalid cover URL');
      }
      final previous = entry.record;
      Uint8List? oldBytes;
      if (previous?.url == url) {
        final oldFile = await cache.findCache(previous!.cacheKey);
        check();
        oldBytes = await oldFile?.readAsBytes();
        check();
      }
      final result = await runZoned(
        () => scope.runToCompletion(
          () =>
              _loadImage(url, entry.identity, scope, previous, oldBytes, force),
        ),
        zoneValues: {_metadataZone: true},
      );
      check();
      await _validateImage(result.bytes);
      check();
      final contentKey =
          'cover:${entry.identity.storageKey}:${sha256.convert(result.bytes)}';
      // Versioned writes prevent a late initial/old download from replacing the
      // newly validated bytes. Successful 304 responses retain the same version.
      if (contentKey != previous?.cacheKey || oldBytes == null) {
        await cache.writeCache(contentKey, result.bytes);
        check();
      }
      await metadata?.publish(url, check);
      check();
      final record = CoverCacheRecord(
        url: url,
        cacheKey: contentKey,
        checkedAt: _now(),
        validators: result.validators,
      );
      await cache.writeCoverRecord(
        entry.identity.storageKey,
        record,
        checkActive: check,
      );
      check();
      entry.record = record;
      entry.url = url;
      entry.cacheKey = contentKey;
      entry.metadataUrl = url;
      entry.metadataCheckedAt = record.checkedAt;
      entry.nextAttempt = record.checkedAt.add(freshness);
      entry.publish();
    } catch (error) {
      if ((!scope.isCancelled || error is TimeoutException) &&
          !_closed &&
          !_held &&
          (sequence == null || entry.sequence == sequence)) {
        entry.nextAttempt = _now().add(retryDelay);
      }
      rethrow;
    } finally {
      if (slot) _releaseSlot();
    }
  }

  static bool _cleanupFailure(Object error) =>
      error is ImageHttpCleanupFailure ||
      error is ImageLoadingConfigFailure ||
      error is ImageLoadingConfigCleanupFailure;

  Future<void> _join() async {
    final failures = Set<Object>.identity()..addAll(_cleanupFailures);
    await Future.wait(
      _tasks.keys.toList().map(
        (work) => work.then<void>(
          (_) {},
          onError: (Object error, StackTrace _) {
            if (_cleanupFailure(error)) failures.add(error);
          },
        ),
      ),
    );
    if (failures.isNotEmpty) throw ComicCoverCleanupFailure(failures);
  }

  Future<void Function()> prepareForExit() =>
      _preparation ??= _prepareForExit();
  Future<void Function()> _prepareForExit() async {
    _held = true;
    for (final entry in _entries.values) {
      entry.timer?.cancel();
    }
    for (final scope in _tasks.values.toList()) {
      scope.cancel();
    }
    var released = false;
    void release() {
      if (released || _closed) return;
      released = true;
      _held = false;
      _preparation = null;
      for (final entry in _entries.values.toList()) {
        entry.metadataUrl = null;
        entry.metadataCheckedAt = null;
        entry.nextAttempt = _now();
        _schedule(entry);
      }
    }

    try {
      await _join();
      return release;
    } catch (_) {
      release();
      rethrow;
    }
  }

  Future<void> dispose() => _disposal ??= _dispose();
  Future<void> _dispose() async {
    _closed = true;
    for (final entry in _entries.values) {
      entry.timer?.cancel();
    }
    for (final scope in _tasks.values.toList()) {
      scope.cancel();
    }
    await _join();
    await Future.wait(
      _entries.values.map((entry) => entry.ready.catchError((Object _) {})),
    );
    for (final entry in _entries.values) {
      entry.dispose();
    }
    _entries.clear();
    if (identical(instance, this)) instance = null;
  }
}

class ComicCoverCleanupFailure implements Exception {
  ComicCoverCleanupFailure(Iterable<Object> failures)
    : failures = List.unmodifiable(failures);
  final List<Object> failures;
  @override
  String toString() => 'Cover cleanup failed: ${failures.join('; ')}';
}

class ComicCoverLease {
  ComicCoverLease._(this._manager, this._entry);
  final ComicCoverManager _manager;
  final _CoverEntry _entry;
  bool _released = false;
  ComicCoverSnapshot get snapshot =>
      ComicCoverSnapshot(_entry.url, _entry.cacheKey);
  Listenable get changes => _entry;
  void release() {
    if (_released) return;
    _released = true;
    _manager._release(_entry);
  }
}

class _CoverEntry extends ChangeNotifier {
  _CoverEntry(this.identity, this.url);
  final ComicCoverIdentity identity;
  String url;
  String? cacheKey;
  String? metadataUrl;
  DateTime? metadataCheckedAt;
  CoverCacheRecord? record;
  late Future<void> ready;
  int leases = 0;
  int sequence = 0;
  DateTime? nextAttempt;
  Future<void>? work;
  RequestScope? scope;
  Timer? timer;

  void publish() => notifyListeners();
}
