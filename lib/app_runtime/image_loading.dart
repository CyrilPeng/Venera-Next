import 'dart:async';

import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/network/images.dart';

/// Stop producers and requests together, then join their actual cleanup. On
/// recovery requests reopen before mounted providers resume loading images.
Future<void Function()> prepareImageLoadingForExit({
  Future<void Function()> Function()? prepareProviders,
  Future<void Function()> Function()? prepareRequests,
}) async {
  final releases = <String, void Function()>{};
  final failures = <({String stage, Object error, StackTrace stack})>[];
  Future<void> prepare(
    String stage,
    Future<void Function()> Function() action,
  ) async {
    try {
      releases[stage] = await action();
    } catch (error, stack) {
      failures.add((stage: stage, error: error, stack: stack));
    }
  }

  await Future.wait([
    prepare('providers', prepareProviders ?? BaseImageProvider.prepareForExit),
    prepare('requests', prepareRequests ?? ImageDownloader.prepareForExit),
  ]);
  var released = false;
  void release() {
    if (released) return;
    released = true;
    final recoveryFailures =
        <({String stage, Object error, StackTrace stack})>[];
    for (final stage in ['requests', 'providers']) {
      try {
        releases[stage]?.call();
      } catch (error, stack) {
        recoveryFailures.add((
          stage: '$stage resume',
          error: error,
          stack: stack,
        ));
      }
    }
    if (recoveryFailures.isNotEmpty) {
      throw ImageLoadingPreparationFailure(recoveryFailures);
    }
  }

  if (failures.isNotEmpty) {
    try {
      release();
    } on ImageLoadingPreparationFailure catch (error) {
      failures.addAll(error.failures);
    }
    throw ImageLoadingPreparationFailure(failures);
  }
  return release;
}

class ImageLoadingPreparationFailure implements Exception {
  ImageLoadingPreparationFailure(
    Iterable<({String stage, Object error, StackTrace stack})> failures,
  ) : failures = List.unmodifiable(failures);

  final List<({String stage, Object error, StackTrace stack})> failures;

  @override
  String toString() =>
      'Image loading shutdown failed: '
      '${failures.map((failure) => '${failure.stage}: ${failure.error}').join('; ')}';
}
