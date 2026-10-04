import 'dart:async';

import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/image_http_client.dart';
import 'package:venera_next/network/image_loading_config.dart';
import 'package:venera_next/network/image_stream.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/request_scope.dart';

import 'package:venera_next/foundation/image_work.dart';

/// A view owns its subscriptions; the reading session owns their actual finish.
class ReaderImageDownloads {
  ReaderImageDownloads({
    required ImageWork work,
    Stream<ImageDownloadProgress> Function(String, String?, String, String)?
    loader,
  }) : _work = work,
       _loader = loader ?? ImageDownloader.loadComicImage;

  final ImageWork _work;
  final Stream<ImageDownloadProgress> Function(String, String?, String, String)
  _loader;
  final _pending =
      <
        (String, String?, String, String),
        ({ImageWorkTask task, RequestScope scope})
      >{};
  Future<void>? _disposal;

  void preload(String imageKey, String? sourceKey, String cid, String eid) {
    if (_disposal != null || imageKey.startsWith('file://')) return;
    final key = (imageKey, sourceKey, cid, eid);
    if (_pending.containsKey(key)) return;
    final scope = RequestScope();
    final task = _work.start(onCancel: scope.cancel);
    if (task == null) {
      scope.dispose();
      return;
    }
    final download = (task: task, scope: scope);
    _pending[key] = download;
    unawaited(_download(key, download));
  }

  Future<void> _download(
    (String, String?, String, String) key,
    ({ImageWorkTask task, RequestScope scope}) download,
  ) async {
    try {
      download.task.check();
      final stream = _loader(key.$1, key.$2, key.$3, key.$4);
      download.task.check();
      await readImageStream(
        stream,
        cancelSignal: download.scope.whenCancelled,
        checkStop: download.scope.check,
      );
    } on RequestCancelled {
      // Only this view's subscription is released on cancellation.
    } on ImageWorkTaskCancelled {
      // Admission can be cancelled reentrantly by an injected loader.
    } catch (error, stack) {
      if (download.task.isCancelled ||
          error is ImageStreamCleanupFailure ||
          error is ImageHttpCleanupFailure ||
          error is ImageLoadingConfigFailure ||
          error is ImageLoadingConfigCleanupFailure) {
        download.task.recordFailure(error, stack);
      } else {
        Log.error('Reader preload', error, stack);
      }
    } finally {
      download.scope.dispose();
      _pending.remove(key);
      download.task.finish();
    }
  }

  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    final pending = _pending.values.toList();
    final completion = Completer<void>();
    _disposal = completion.future;
    for (final download in pending) {
      download.task.cancel();
    }
    completion.complete(
      Future.wait(pending.map((e) => e.task.done)).then((_) {}),
    );
    return completion.future;
  }
}
