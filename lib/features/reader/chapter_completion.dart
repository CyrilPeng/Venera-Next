import 'dart:async';

import 'package:flutter/foundation.dart';

@immutable
class ReaderChapterCompletedEvent {
  const ReaderChapterCompletedEvent({
    required this.sourceKey,
    required this.comicId,
    required this.chapterKey,
    required this.chapterTitle,
  });

  final String sourceKey;
  final String comicId;
  final String chapterKey;
  final String chapterTitle;

  @override
  bool operator ==(Object other) =>
      other is ReaderChapterCompletedEvent &&
      other.sourceKey == sourceKey &&
      other.comicId == comicId &&
      other.chapterKey == chapterKey &&
      other.chapterTitle == chapterTitle;

  @override
  int get hashCode => Object.hash(sourceKey, comicId, chapterKey, chapterTitle);
}

typedef ReaderChapterCompletedHandler =
    FutureOr<void> Function(ReaderChapterCompletedEvent event);

ReaderChapterCompletedHandler? _chapterCompletedHandler;

void configureReaderChapterCompletedHandler(
  ReaderChapterCompletedHandler? handler,
) {
  _chapterCompletedHandler = handler;
}

bool isReaderChapterCompletionPosition({
  required bool isActive,
  required bool hasImages,
  required int page,
  required int lastImagePage,
  required int totalPages,
}) =>
    isActive &&
    hasImages &&
    lastImagePage > 0 &&
    page >= lastImagePage &&
    page <= totalPages;

class ReaderChapterCompletionNotifier {
  ReaderChapterCompletionNotifier([ReaderChapterCompletedHandler? handler])
    : _handler = handler ?? _chapterCompletedHandler;

  final ReaderChapterCompletedHandler? _handler;
  final Set<String> _notified = <String>{};

  Future<void> notify({
    required bool isAtEnd,
    required ReaderChapterCompletedEvent event,
  }) async {
    final handler = _handler;
    if (!isAtEnd || handler == null || !_notified.add(event.chapterKey)) {
      return;
    }
    await Future.sync(() => handler(event));
  }
}
