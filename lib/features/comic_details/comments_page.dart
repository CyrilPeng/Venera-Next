import 'package:venera_next/foundation/log.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/image.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/components/rich_comment_content.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/components/side_bar.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/image_provider/cached_image.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

bool shouldBlockComment(Comment comment) {
  var blockedWords = appdata.settings["blockedCommentWords"] as List;
  if (blockedWords.isEmpty) return false;

  var content = comment.content.toLowerCase();
  for (var word in blockedWords) {
    if (content.contains(word.toString().toLowerCase())) {
      return true;
    }
  }
  return false;
}

class CommentsPage extends StatefulWidget {
  const CommentsPage({
    super.key,
    required this.data,
    required this.source,
    this.replyComment,
  });

  final ComicDetails data;

  final ComicSource source;

  final Comment? replyComment;

  @override
  State<CommentsPage> createState() => _CommentsPageState();
}

class _CommentsPageState extends State<CommentsPage> {
  bool _loading = true;
  List<Comment>? _comments;
  String? _error;
  int _page = 1;
  int? maxPage;
  var controller = TextEditingController();
  bool sending = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  bool _firstLoadRunning = false;
  bool _loadingMore = false;
  String? _moreError;
  int _generation = 0;

  void firstLoad() async {
    if (_firstLoadRunning) return;
    _firstLoadRunning = true;
    final generation = _generation;
    try {
      final res = await Future.sync(
        () => widget.source.commentsLoader!(
          widget.data.comicId,
          widget.data.subId,
          1,
          widget.replyComment?.id,
        ),
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = res.error ? (res.errorMessage ?? 'Unknown error'.tl) : null;
        if (!res.error) {
          _comments = res.data.where((c) => !shouldBlockComment(c)).toList();
          maxPage = res.subData;
        }
        _loading = false;
      });
    } catch (error, stack) {
      Log.error('Load comments', error, stack);
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    } finally {
      if (generation == _generation) _firstLoadRunning = false;
    }
  }

  void loadMore() async {
    if (_loadingMore) return;
    _loadingMore = true;
    final generation = _generation;
    try {
      final res = await Future.sync(
        () => widget.source.commentsLoader!(
          widget.data.comicId,
          widget.data.subId,
          _page + 1,
          widget.replyComment?.id,
        ),
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _moreError = res.error
            ? (res.errorMessage ?? 'Unknown error'.tl)
            : null;
        if (!res.error) {
          _comments!.addAll(res.data.where((c) => !shouldBlockComment(c)));
          _page++;
          if (maxPage == null && res.data.isEmpty) maxPage = _page;
        }
      });
    } catch (error, stack) {
      Log.error('Load more comments', error, stack);
      if (!mounted || generation != _generation) return;
      setState(() => _moreError = error.toString());
    } finally {
      if (generation == _generation) _loadingMore = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: Appbar(title: Text("Comments".tl), style: AppbarStyle.shadow),
      body: buildBody(context),
    );
  }

  Widget buildBody(BuildContext context) {
    if (_loading) {
      firstLoad();
      return const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      return NetworkError(
        message: _error!,
        retry: () {
          setState(() {
            _loading = true;
          });
        },
        withAppbar: false,
      );
    } else {
      var showAvatar =
          _comments!.any((e) {
            return e.avatar != null;
          }) ||
          (widget.replyComment?.avatar != null);
      return Column(
        children: [
          Expanded(
            child: SmoothScrollProvider(
              builder: (context, controller, physics) {
                return ListView.builder(
                  controller: controller,
                  physics: physics,
                  primary: false,
                  padding: EdgeInsets.zero,
                  itemCount: _comments!.length + 2,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      if (widget.replyComment != null) {
                        return Column(
                          children: [
                            _CommentTile(
                              comment: widget.replyComment!,
                              source: widget.source,
                              comic: widget.data,
                              showAvatar: showAvatar,
                              showActions: false,
                            ),
                            const SizedBox(height: 8),
                            Container(
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(
                                    color: context.colorScheme.outlineVariant,
                                    width: 0.6,
                                  ),
                                ),
                              ),
                              child: Text("Replies".tl, style: ts.s18),
                            ),
                          ],
                        );
                      } else {
                        return const SizedBox();
                      }
                    }
                    index--;

                    if (index == _comments!.length) {
                      if (_page < (maxPage ?? _page + 1)) {
                        if (_moreError != null) {
                          return TextButton(
                            onPressed: () {
                              setState(() => _moreError = null);
                              loadMore();
                            },
                            child: Text(_moreError!),
                          );
                        }
                        loadMore();
                        return const ListLoadingIndicator();
                      } else {
                        return const SizedBox();
                      }
                    }

                    return _CommentTile(
                      comment: _comments![index],
                      source: widget.source,
                      comic: widget.data,
                      showAvatar: showAvatar,
                    );
                  },
                );
              },
            ),
          ),
          buildBottom(context),
        ],
      );
    }
  }

  Widget buildBottom(BuildContext context) {
    if (widget.source.sendCommentFunc == null) {
      return const SizedBox(height: 0);
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Material(
        color: context.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(24),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isCollapsed: true,
                  hintText: "Comment".tl,
                ),
                minLines: 1,
                maxLines: 5,
              ),
            ),
            if (sending)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                onPressed: () async {
                  if (sending || controller.text.isEmpty) {
                    return;
                  }
                  setState(() {
                    sending = true;
                  });
                  try {
                    var b = await widget.source.sendCommentFunc!(
                      widget.data.comicId,
                      widget.data.subId,
                      controller.text,
                      widget.replyComment?.id,
                    );
                    if (!mounted || !context.mounted) return;
                    if (!b.error) {
                      controller.text = "";
                      setState(() {
                        sending = false;
                        _generation++;
                        _firstLoadRunning = false;
                        _loadingMore = false;
                        _moreError = null;
                        _error = null;
                        _loading = true;
                        _comments?.clear();
                        _page = 1;
                        maxPage = null;
                      });
                    } else {
                      context.showMessage(
                        message: b.errorMessage ?? "Error".tl,
                      );
                      setState(() {
                        sending = false;
                      });
                    }
                  } catch (error, stack) {
                    Log.error('Send comment', error, stack);
                    if (mounted && context.mounted) {
                      context.showMessage(message: error.toString());
                    }
                  } finally {
                    if (mounted) setState(() => sending = false);
                  }
                },
                icon: Icon(
                  Icons.send,
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
          ],
        ).paddingLeft(16).paddingRight(4),
      ),
    );
  }
}

class _CommentTile extends StatefulWidget {
  const _CommentTile({
    required this.comment,
    required this.source,
    required this.comic,
    required this.showAvatar,
    this.showActions = true,
  });

  final Comment comment;

  final ComicSource source;

  final ComicDetails comic;

  final bool showAvatar;

  final bool showActions;

  @override
  State<_CommentTile> createState() => _CommentTileState();
}

class _CommentTileState extends State<_CommentTile> {
  @override
  void initState() {
    likes = widget.comment.score ?? 0;
    isLiked = widget.comment.isLiked ?? false;
    voteStatus = widget.comment.voteStatus;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showAvatar)
            Container(
              width: 36,
              height: 36,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: Theme.of(context).colorScheme.secondaryContainer,
              ),
              child: widget.comment.avatar == null
                  ? null
                  : AnimatedImage(
                      image: CachedImageProvider(
                        widget.comment.avatar!,
                        sourceKey: widget.source.key,
                      ),
                    ),
            ).paddingRight(8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.comment.userName, style: ts.bold),
                if (widget.comment.time != null)
                  Text(widget.comment.time!, style: ts.s12),
                const SizedBox(height: 4),
                _CommentContent(text: widget.comment.content),
                buildActions(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildActions() {
    if (!widget.showActions) {
      return const SizedBox();
    }
    if (widget.comment.score == null && widget.comment.replyCount == null) {
      return const SizedBox();
    }
    return SizedBox(
      height: 36,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (widget.comment.score != null &&
              widget.source.voteCommentFunc != null)
            buildVote(),
          if (widget.comment.score != null &&
              widget.source.likeCommentFunc != null)
            buildLike(),
          if (widget.comment.replyCount != null) buildReply(),
        ],
      ),
    ).paddingTop(8);
  }

  Widget buildReply() {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ClickInkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          showSideBar(
            context,
            CommentsPage(
              data: widget.comic,
              source: widget.source,
              replyComment: widget.comment,
            ),
            showBarrier: false,
          );
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_comment_outlined, size: 16),
            const SizedBox(width: 8),
            Text(widget.comment.replyCount.toString()),
          ],
        ).padding(const EdgeInsets.symmetric(horizontal: 12, vertical: 4)),
      ),
    );
  }

  bool isLiking = false;

  bool isLiked = false;

  var likes = 0;

  Widget buildLike() {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ClickInkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          if (isLiking) return;
          setState(() {
            isLiking = true;
          });
          try {
            var res = await widget.source.likeCommentFunc!(
              widget.comic.comicId,
              widget.comic.subId,
              widget.comment.id!,
              !isLiked,
            );
            if (!mounted) return;
            if (res.success) {
              isLiked = !isLiked;
              likes += isLiked ? 1 : -1;
            } else {
              context.showMessage(message: res.errorMessage ?? "Error".tl);
            }
          } catch (error, stack) {
            Log.error('Like comment', error, stack);
            if (mounted) context.showMessage(message: error.toString());
          } finally {
            if (mounted) setState(() => isLiking = false);
          }
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLiking)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(),
              )
            else if (isLiked)
              Icon(
                Icons.favorite,
                size: 16,
                color: context.useTextColor(Colors.red),
              )
            else
              const Icon(Icons.favorite_border, size: 16),
            const SizedBox(width: 8),
            Text(likes.toString()),
          ],
        ).padding(const EdgeInsets.symmetric(horizontal: 12, vertical: 4)),
      ),
    );
  }

  int? voteStatus;

  bool isVotingUp = false;

  bool isVotingDown = false;

  void vote(bool isUp) async {
    if (isVotingUp || isVotingDown) return;
    setState(() {
      if (isUp) {
        isVotingUp = true;
      } else {
        isVotingDown = true;
      }
    });
    var isCancel = (isUp && voteStatus == 1) || (!isUp && voteStatus == -1);
    try {
      var res = await widget.source.voteCommentFunc!(
        widget.comic.comicId,
        widget.comic.subId,
        widget.comment.id!,
        isUp,
        isCancel,
      );
      if (!mounted) return;
      if (res.success) {
        if (isCancel) {
          voteStatus = 0;
        } else {
          if (isUp) {
            voteStatus = 1;
          } else {
            voteStatus = -1;
          }
        }
        widget.comment.voteStatus = voteStatus;
        widget.comment.score = res.data ?? widget.comment.score;
      } else {
        context.showMessage(message: res.errorMessage ?? "Error".tl);
      }
    } catch (error, stack) {
      Log.error('Vote comment', error, stack);
      if (mounted) context.showMessage(message: error.toString());
    } finally {
      if (mounted) {
        setState(() {
          isVotingUp = false;
          isVotingDown = false;
        });
      }
    }
  }

  Widget buildVote() {
    var upColor = context.colorScheme.outline;
    if (voteStatus == 1) {
      upColor = context.useTextColor(Colors.red);
    }
    var downColor = context.colorScheme.outline;
    if (voteStatus == -1) {
      downColor = context.useTextColor(Colors.blue);
    }

    return Container(
      margin: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Button.icon(
            isLoading: isVotingUp,
            icon: const Icon(Icons.arrow_upward),
            size: 18,
            color: upColor,
            onPressed: () => vote(true),
          ),
          const SizedBox(width: 4),
          Text(widget.comment.score.toString()),
          const SizedBox(width: 4),
          Button.icon(
            isLoading: isVotingDown,
            icon: const Icon(Icons.arrow_downward),
            size: 18,
            color: downColor,
            onPressed: () => vote(false),
          ),
        ],
      ),
    );
  }
}

class _CommentContent extends StatelessWidget {
  const _CommentContent({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (!text.contains('<') && !text.contains('http')) {
      return SelectableText(text);
    } else {
      return RichCommentContent(text: text);
    }
  }
}
