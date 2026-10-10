import 'package:venera_next/foundation/operation_failure.dart';
import 'dart:convert';

import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';

import 'models.dart';
import 'normalization.dart';
import 'source.dart';
import 'types.dart';

import 'source_parser_context.dart';

class SourceComicParser {
  const SourceComicParser(this.context);
  final SourceParserContext context;

  LoadComicFunc? parseLoadComicFunc() {
    return (id) async {
      try {
        final details = await context.runReadCodeToCompletion<ComicDetails>(
          """
          ${context.sourceExpression}.comic.loadInfo(${jsonEncode(id)})
        """,
          consume: (raw) {
            final normalized = normalizeComicSourceComicDetails(
              raw,
              context.key,
              id,
            );
            if (normalized == null) {
              throw OperationFailure.message('Invalid data');
            }
            // The model copies its collections and retains only Dart values.
            // Complete conversion before the borrowed JS result is released.
            return ComicDetails.fromJson(normalized);
          },
        );
        return Res(details);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return context.failureResult(e, s);
      }
    };
  }

  LikeOrUnlikeComicFunc? parseLikeFunc() {
    if (!context.checkExists("comic.likeComic")) {
      return null;
    }
    return (id, isLiking) async {
      try {
        await context.runCodeToCompletion<void>("""
          ${context.sourceExpression}.comic.likeComic(${jsonEncode(id)}, ${jsonEncode(isLiking)})
        """, consume: (_) {});
        return const Res(true);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return context.failureResult(e, s);
      }
    };
  }

  StarRatingFunc? parseStarRatingFunc() {
    if (!context.checkExists("comic.starRating")) {
      return null;
    }
    return (id, rating) async {
      try {
        await context.runCodeToCompletion<void>("""
          ${context.sourceExpression}.comic.starRating(${jsonEncode(id)}, ${jsonEncode(rating)})
        """, consume: (_) {});
        return const Res(true);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return context.failureResult(e, s);
      }
    };
  }

  ArchiveDownloader? parseArchiveDownloader() {
    if (!context.checkExists("comic.archive")) {
      return null;
    }
    return ArchiveDownloader(
      (cid) => _readArchive<List<ArchiveInfo>>(
        () =>
            """
              ${context.sourceExpression}.comic.archive.getArchives(${jsonEncode(cid)})
            """,
        (raw) {
          final archives = normalizeComicSourceArchiveList(raw);
          if (archives == null) throw OperationFailure.message("Invalid data");
          return archives;
        },
      ),
      (cid, aid) => _readArchive<String>(
        () =>
            """
              ${context.sourceExpression}.comic.archive.getDownloadUrl(${jsonEncode(cid)}, ${jsonEncode(aid)})
            """,
        (raw) {
          final url = normalizeComicSourceArchiveDownloadUrl(raw);
          if (url == null) throw OperationFailure.message("Invalid data");
          return url;
        },
      ),
    );
  }

  Future<Res<T>> _readArchive<T>(
    String Function() code,
    T Function(dynamic result) consume,
  ) async {
    try {
      return Res(
        await context.runReadCodeToCompletion<T>(code(), consume: consume),
      );
    } catch (error, stack) {
      Log.error('Network', '$error\n$stack');
      return context.failureResult(error, stack);
    }
  }
}
