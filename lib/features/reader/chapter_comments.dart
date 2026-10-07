import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:venera_next/components/image.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/components/rich_comment_content.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart'
    show Comment;
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/image_provider/cached_image.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';
import 'comments_controller.dart';
import 'sidebar_binding.dart';

class ChapterCommentsPage extends StatelessWidget {
  const ChapterCommentsPage({
    super.key,
    required this.request,
    required this.work,
    this.onRetired,
  });
  final ReaderChapterCommentsRequest request;
  final ImageWork work;
  final VoidCallback? onRetired;
  @override
  Widget build(BuildContext context) => _ChapterCommentsView(
    request: request,
    work: work,
    embedded: false,
    onRetired: onRetired,
  );
}

class EmbeddedChapterCommentsPage extends StatelessWidget {
  const EmbeddedChapterCommentsPage({
    super.key,
    required this.request,
    required this.work,
    required this.onExit,
  });
  final ReaderChapterCommentsRequest request;
  final ImageWork work;
  final Future<void> Function() onExit;
  @override
  Widget build(BuildContext context) => _ChapterCommentsView(
    request: request,
    work: work,
    embedded: true,
    onExit: onExit,
  );
}

class _ChapterCommentsView extends StatefulWidget {
  const _ChapterCommentsView({
    required this.request,
    required this.work,
    required this.embedded,
    this.onExit,
    this.onRetired,
  });
  final ReaderChapterCommentsRequest request;
  final ImageWork work;
  final bool embedded;
  final Future<void> Function()? onExit;
  final VoidCallback? onRetired;
  @override
  State<_ChapterCommentsView> createState() => _ChapterCommentsViewState();
}

class _ChapterCommentsViewState extends State<_ChapterCommentsView> {
  late ReaderChapterCommentsController _comments;
  final _text = TextEditingController();
  final _scroll = ScrollController();
  String _lastText = '';
  int _draftRevision = 0;
  VoidCallback? _removeValidity;
  late final _replies = ReaderSidebarBinding(
    canOpen: () => mounted && _comments.isCurrent,
    acquireInteraction: () => () {},
    onError: (error, stack) => Log.error('Chapter replies', error, stack),
  );

  void _observeValidity() {
    _removeValidity?.call();
    final owner = _comments;
    var retired = false;
    void changed() {
      if (retired ||
          !mounted ||
          !identical(_comments, owner) ||
          owner.isCurrent) {
        return;
      }
      retired = true;
      _replies.close();
      widget.onRetired?.call();
    }

    _removeValidity = owner.request.observeValidity?.call(changed);
    changed();
  }

  void _openReplies(ReaderChapterCommentsController owner, Comment comment) {
    if (!mounted || !identical(_comments, owner) || !owner.isCurrent) return;
    final request = owner.request.replies(comment);
    ReaderSidebarHandle? handle;
    handle = _replies.show(
      context,
      ChapterCommentsPage(
        request: request,
        work: owner.work,
        onRetired: () => handle?.close(),
      ),
      width: 500,
      showBarrier: false,
      isRequestCurrent: request.isCurrent,
    );
  }

  ReaderChapterCommentsController _create() => ReaderChapterCommentsController(
    request: widget.request,
    work: widget.work,
    includeComment: (comment) {
      final content = comment.content.toLowerCase();
      return !(appdata.settings['blockedCommentWords'] as List).any(
        (word) => content.contains(word.toString().toLowerCase()),
      );
    },
    onChanged: () {
      if (mounted) setState(() {});
    },
    onError: (error, stack) {
      Log.error('Chapter comments', error, stack);
      if (mounted) context.showMessage(message: error.toString());
    },
  );
  @override
  void initState() {
    super.initState();
    _text.addListener(_trackDraft);
    _comments = _create();
    _observeValidity();
    unawaited(_comments.refresh(notify: false));
  }

  void _trackDraft() {
    if (_lastText == _text.text) return;
    _lastText = _text.text;
    _draftRevision++;
  }

  @override
  void didUpdateWidget(_ChapterCommentsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.work, oldWidget.work) ||
        widget.request.key != _comments.request.key ||
        !_comments.request.isCurrent()) {
      _replies.close();
      _removeValidity?.call();
      _removeValidity = null;
      unawaited(_comments.dispose());
      _text.clear();
      _comments = _create();
      _observeValidity();
      unawaited(_comments.refresh(notify: false));
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _removeValidity?.call();
    _replies.dispose();
    unawaited(_comments.dispose());
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final owner = _comments;
    final revision = _draftRevision;
    if (await owner.send(_text.text) &&
        mounted &&
        identical(_comments, owner) &&
        revision == _draftRevision) {
      _text.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = Column(
      children: [
        _header(),
        Expanded(child: _body()),
        if (widget.embedded || (!_comments.loading && _comments.error == null))
          _composer(),
      ],
    );
    if (!widget.embedded) {
      return Scaffold(
        resizeToAvoidBottomInset: false,
        body: SafeArea(bottom: false, child: content),
      );
    }
    return ColoredBox(
      color: context.colorScheme.surface,
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: content,
        ),
      ),
    );
  }

  Widget _header() => Padding(
    padding: const EdgeInsets.all(8),
    child: Row(
      children: [
        IconButton(
          style: IconButton.styleFrom(
            minimumSize: const Size.square(48),
            visualDensity: VisualDensity.standard,
          ),
          icon: const Icon(Icons.arrow_back),
          tooltip: (widget.embedded ? 'Exit' : 'Back').tl,
          onPressed: () {
            if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
            if (widget.embedded) {
              unawaited(widget.onExit!());
            } else {
              Navigator.maybePop(context);
            }
          },
        ),
        const SizedBox(width: 4),
        const ExcludeSemantics(child: Icon(Icons.comment)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (MediaQuery.viewInsetsOf(context).bottom == 0 &&
                  (MediaQuery.sizeOf(context).height >= 500 ||
                      MediaQuery.textScalerOf(context).scale(18) <= 27))
                Text(
                  'Chapter Comments'.tl,
                  style: ts.s18,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              Tooltip(
                message: widget.request.chapterTitle,
                child: Text(
                  widget.request.chapterTitle,
                  style: ts.s12,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _body() {
    if (_comments.loading) return Center(child: _progress());
    if (_comments.error case final error?) {
      return NetworkError(
        message: error.toString(),
        retry: () => unawaited(_comments.refresh()),
        withAppbar: false,
      );
    }
    final items = _comments.comments;
    final owner = _comments;
    final parent = widget.request.replyComment;
    if (items.isEmpty && parent == null && !_comments.hasMore) {
      return Center(child: Text('No comments yet'.tl, style: ts.s14));
    }
    final avatars =
        parent?.avatar != null || items.any((item) => item.avatar != null);
    Widget row(int index) {
      if (index == items.length) return _more();
      final comment = items[index];
      return _ChapterCommentTile(
        key: ObjectKey(comment),
        comment: comment,
        owner: _comments,
        onReplies: (comment) => _openReplies(owner, comment),
        showAvatar: avatars,
      );
    }

    if (widget.embedded) {
      return Scrollbar(
        controller: _scroll,
        thumbVisibility: true,
        thickness: 8,
        child: MasonryGridView.count(
          controller: _scroll,
          crossAxisCount:
              MediaQuery.orientationOf(context) == Orientation.landscape &&
                  MediaQuery.textScalerOf(context).scale(14) <= 21
              ? 2
              : 1,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          itemCount: items.length + 1,
          itemBuilder: (_, index) => row(index),
        ),
      );
    }
    return SmoothScrollProvider(
      controller: _scroll,
      builder: (context, controller, physics) => ListView.builder(
        controller: controller,
        physics: physics,
        primary: false,
        padding: EdgeInsets.zero,
        itemCount: items.length + 2,
        itemBuilder: (_, index) {
          if (index != 0) return row(index - 1);
          if (parent == null) return const SizedBox();
          return Column(
            children: [
              _ChapterCommentTile(
                key: ObjectKey(parent),
                comment: parent,
                owner: _comments,
                onReplies: (comment) => _openReplies(owner, comment),
                showAvatar: avatars,
                showActions: false,
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Replies'.tl, style: ts.s18),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _more() {
    if (!_comments.hasMore) return const SizedBox();
    if (_comments.moreError case final error?) {
      return TextButton(
        onPressed: () => unawaited(_comments.loadMore(notify: true)),
        child: Text(error.toString()),
      );
    }
    unawaited(_comments.loadMore());
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(child: _progress()),
    );
  }

  Widget _progress() => CircularProgressIndicator(
    value: MediaQuery.disableAnimationsOf(context) ? 0.5 : null,
  );
  Widget _composer() {
    if (widget.request.send == null) return const SizedBox();
    return FocusTraversalGroup(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Material(
          color: context.colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      isCollapsed: true,
                      hintText: 'Comment'.tl,
                    ),
                    minLines: 1,
                    maxLines:
                        MediaQuery.viewInsetsOf(context).bottom > 0 &&
                            MediaQuery.orientationOf(context) ==
                                Orientation.landscape
                        ? 1
                        : 5,
                  ),
                ),
                if (_comments.sending)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(width: 24, height: 24, child: _progress()),
                  )
                else
                  IconButton(
                    style: IconButton.styleFrom(
                      minimumSize: const Size.square(48),
                      visualDensity: VisualDensity.standard,
                    ),
                    tooltip: 'Send'.tl,
                    onPressed: _comments.isCurrent
                        ? () => unawaited(_send())
                        : null,
                    icon: Icon(
                      Icons.send,
                      color: context.colorScheme.secondary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChapterCommentTile extends StatefulWidget {
  const _ChapterCommentTile({
    super.key,
    required this.comment,
    required this.owner,
    required this.showAvatar,
    required this.onReplies,
    this.showActions = true,
  });
  final Comment comment;
  final ReaderChapterCommentsController owner;
  final void Function(Comment) onReplies;
  final bool showAvatar, showActions;
  @override
  State<_ChapterCommentTile> createState() => _ChapterCommentTileState();
}

class _ChapterCommentTileState extends State<_ChapterCommentTile> {
  bool _liking = false, _votingUp = false, _votingDown = false;
  late bool _liked;
  late int _likes;
  int? _vote;
  void _reset() {
    _liked = widget.comment.isLiked ?? false;
    _likes = widget.comment.score ?? 0;
    _vote = widget.comment.voteStatus;
    _liking = _votingUp = _votingDown = false;
  }

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(_ChapterCommentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.comment, oldWidget.comment) ||
        !identical(widget.owner, oldWidget.owner)) {
      _reset();
    }
  }

  Future<void> _like() async {
    if (!mounted || !widget.owner.isCurrent || _liking) return;
    final owner = widget.owner, comment = widget.comment;
    final liked = !_liked;
    bool current() =>
        mounted &&
        identical(widget.owner, owner) &&
        identical(widget.comment, comment);
    setState(() => _liking = true);
    try {
      final result = await owner.mutate(
        () => owner.request.like!(comment.id!, liked),
        canPresent: current,
      );
      if (result != null && current()) {
        _liked = liked;
        _likes += liked ? 1 : -1;
      }
    } finally {
      if (current()) setState(() => _liking = false);
    }
  }

  Future<void> _voteFor(bool up) async {
    if (!mounted || !widget.owner.isCurrent || _votingUp || _votingDown) return;
    final owner = widget.owner, comment = widget.comment;
    final cancel = _vote == (up ? 1 : -1);
    bool current() =>
        mounted &&
        identical(widget.owner, owner) &&
        identical(widget.comment, comment);
    setState(() {
      _votingUp = up;
      _votingDown = !up;
    });
    try {
      final result = await owner.mutate(
        () => owner.request.vote!(comment.id!, up, cancel),
        canPresent: current,
      );
      if (result != null && current()) {
        _vote = cancel ? 0 : (up ? 1 : -1);
        comment.voteStatus = _vote;
        comment.score = result.dataOrNull ?? comment.score;
      }
    } finally {
      if (current()) {
        setState(() {
          _votingUp = _votingDown = false;
        });
      }
    }
  }

  Widget _action({
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    bool busy = false,
    bool selected = false,
  }) => IconButton(
    style: IconButton.styleFrom(
      minimumSize: const Size.square(48),
      visualDensity: VisualDensity.standard,
    ),
    tooltip: label,
    isSelected: selected,
    onPressed: busy || !widget.owner.isCurrent ? null : onPressed,
    icon: busy
        ? SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              value: MediaQuery.disableAnimationsOf(context) ? 0.5 : null,
            ),
          )
        : Icon(icon),
  );

  @override
  Widget build(BuildContext context) {
    final comment = widget.comment, request = widget.owner.request;
    final owner = widget.owner, onReplies = widget.onReplies;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showAvatar)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ClipOval(
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: comment.avatar == null
                      ? ColoredBox(
                          color: context.colorScheme.secondaryContainer,
                        )
                      : AnimatedImage(
                          image: CachedImageProvider(
                            comment.avatar!,
                            sourceKey: request.sourceKey,
                          ),
                        ),
                ),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(comment.userName, style: ts.bold),
                if (comment.time != null) Text(comment.time!, style: ts.s12),
                const SizedBox(height: 4),
                if (!comment.content.contains('<') &&
                    !comment.content.contains('http'))
                  SelectableText(comment.content)
                else
                  RichCommentContent(text: comment.content),
                if (widget.showActions)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (comment.score != null && request.vote != null)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _action(
                                label: 'Upvote'.tl,
                                icon: Icons.arrow_upward,
                                busy: _votingUp,
                                selected: _vote == 1,
                                onPressed: _votingDown
                                    ? null
                                    : () => unawaited(_voteFor(true)),
                              ),
                              Text(comment.score.toString()),
                              _action(
                                label: 'Downvote'.tl,
                                icon: Icons.arrow_downward,
                                busy: _votingDown,
                                selected: _vote == -1,
                                onPressed: _votingUp
                                    ? null
                                    : () => unawaited(_voteFor(false)),
                              ),
                            ],
                          ),
                        if (comment.score != null && request.like != null)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _action(
                                label: (_liked ? 'Unlike' : 'Like').tl,
                                icon: _liked
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                busy: _liking,
                                selected: _liked,
                                onPressed: () => unawaited(_like()),
                              ),
                              Text(_likes.toString()),
                            ],
                          ),
                        if (comment.replyCount != null && comment.id != null)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _action(
                                label: 'Replies'.tl,
                                icon: Icons.insert_comment_outlined,
                                onPressed: () {
                                  if (!mounted ||
                                      !identical(widget.owner, owner) ||
                                      !identical(widget.comment, comment) ||
                                      !owner.isCurrent) {
                                    return;
                                  }
                                  onReplies(comment);
                                },
                              ),
                              Text(comment.replyCount.toString()),
                            ],
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
