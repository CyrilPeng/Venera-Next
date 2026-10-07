import 'dart:async';
import 'dart:convert';

import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';

import 'normalization.dart';
import 'models.dart';
import 'source.dart';
import 'types.dart';

import 'source_parser_context.dart';

class SourceCommentsParser {
  const SourceCommentsParser(this.context);
  final SourceParserContext context;

  Future<Res<bool>> _retryAfterLogin(
    Future<Res<bool>> Function() action,
  ) async {
    try {
      context.checkCurrent();
      final source = ComicSource.requireRuntime(context.key, context.identity);
      final result = await action();
      context.checkCurrent();
      if (result.error && result.errorMessage!.contains('Login expired')) {
        final loggedIn = await source.reLogin();
        context.checkCurrent();
        if (!loggedIn) {
          return const Res.error('Login expired and re-login failed');
        }
        return action();
      }
      return result;
    } catch (error, stack) {
      return Res.fromException(error, stack);
    }
  }

  CommentsLoader? parseCommentsLoader() {
    if (!context.checkExists("comic.loadComments")) return null;
    return (id, subId, page, replyTo) => _readComments(
      () =>
          """
          ${context.sourceExpression}.comic.loadComments(
            ${jsonEncode(id)}, ${jsonEncode(subId)}, ${jsonEncode(page)}, ${jsonEncode(replyTo)})
        """,
    );
  }

  Future<Res<List<Comment>>> _readComments(String Function() code) async {
    try {
      return await context.runReadCodeToCompletion<Res<List<Comment>>>(
        code(),
        consume: (raw) {
          final result = normalizeComicSourceCommentsResult(raw);
          if (result == null) throw 'Invalid data';
          return Res(result.comments, subData: result.data['maxPage'] as int?);
        },
      );
    } catch (error, stack) {
      Log.error('Network', error, stack);
      return Res.fromException(error, stack);
    }
  }

  SendCommentFunc? parseSendCommentFunc() {
    if (!context.checkExists("comic.sendComment")) return null;
    return (id, subId, content, replyTo) async {
      Future<Res<bool>> func() async {
        try {
          await context.runCode("""
            ${context.sourceExpression}.comic.sendComment(
              ${jsonEncode(id)}, ${jsonEncode(subId)}, ${jsonEncode(content)}, ${jsonEncode(replyTo)})
          """);
          return const Res(true);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.fromException(e, s);
        }
      }

      return _retryAfterLogin(func);
    };
  }

  ChapterCommentsLoader? parseChapterCommentsLoader() {
    if (!context.checkExists("comic.loadChapterComments")) return null;
    return (comicId, epId, page, replyTo) => _readComments(
      () =>
          """
          ${context.sourceExpression}.comic.loadChapterComments(
            ${jsonEncode(comicId)}, ${jsonEncode(epId)}, ${jsonEncode(page)}, ${jsonEncode(replyTo)})
        """,
    );
  }

  SendChapterCommentFunc? parseSendChapterCommentFunc() {
    if (!context.checkExists("comic.sendChapterComment")) return null;
    return (comicId, epId, content, replyTo) async {
      Future<Res<bool>> func() async {
        try {
          await context.runCode("""
            ${context.sourceExpression}.comic.sendChapterComment(
              ${jsonEncode(comicId)}, ${jsonEncode(epId)}, ${jsonEncode(content)}, ${jsonEncode(replyTo)})
          """);
          return const Res(true);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.fromException(e, s);
        }
      }

      return _retryAfterLogin(func);
    };
  }

  VoteCommentFunc? parseVoteCommentFunc() {
    if (!context.checkExists("comic.voteComment")) {
      return null;
    }
    return (id, subId, commentId, isUp, isCancel) async {
      try {
        var res = await context.runCode("""
          ${context.sourceExpression}.comic.voteComment(${jsonEncode(id)}, ${jsonEncode(subId)}, ${jsonEncode(commentId)}, ${jsonEncode(isUp)}, ${jsonEncode(isCancel)})
        """);
        return Res(res is num ? res.toInt() : 0);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.fromException(e, s);
      }
    };
  }

  LikeCommentFunc? parseLikeCommentFunc() {
    if (!context.checkExists("comic.likeComment")) {
      return null;
    }
    return (id, subId, commentId, isLiking) async {
      try {
        var res = await context.runCode("""
          ${context.sourceExpression}.comic.likeComment(${jsonEncode(id)}, ${jsonEncode(subId)}, ${jsonEncode(commentId)}, ${jsonEncode(isLiking)})
        """);
        return Res(res is num ? res.toInt() : 0);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.fromException(e, s);
      }
    };
  }
}
