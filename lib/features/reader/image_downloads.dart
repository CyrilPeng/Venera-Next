import 'dart:async';

import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/image_stream.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/request_scope.dart';

/// Downloads owned by one reader view; decoding remains with image providers.
class ReaderImageDownloads {
  final _scope = RequestScope();
  final _pending = <(String, String?, String, String), Future<void>>{};
  Future<void>? _disposal;

  void preload(String imageKey, String? sourceKey, String cid, String eid) {
    if (_scope.isCancelled || imageKey.startsWith('file://')) return;
    final key = (imageKey, sourceKey, cid, eid);
    if (_pending.containsKey(key)) return;
    _pending[key] = _download(key).whenComplete(() {
      _pending.remove(key);
    });
  }

  Future<void> _download((String, String?, String, String) key) async {
    try {
      await readImageStream(
        ImageDownloader.loadComicImage(key.$1, key.$2, key.$3, key.$4),
        cancelSignal: _scope.whenCancelled,
        checkStop: _scope.check,
      );
    } on RequestCancelled {
      // Expected when the owning view is removed.
    } catch (error, stack) {
      if (!_scope.isCancelled) Log.error('Reader preload', error, stack);
    }
  }

  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    _scope.cancel();
    _scope.dispose();
    return _disposal = Future.wait(_pending.values.toList()).then((_) {});
  }
}
