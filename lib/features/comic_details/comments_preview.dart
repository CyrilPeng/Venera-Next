import 'package:flutter/material.dart';
import 'package:sliver_tools/sliver_tools.dart';
import 'package:venera_next/components/layout.dart';
import 'package:venera_next/components/rich_comment_content.dart';
import 'package:venera_next/features/comic_details/action_button.dart';
import 'package:venera_next/features/comic_details/comments_page.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/image_provider/cached_image.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

class ComicCommentsPreview extends StatefulWidget {
  const ComicCommentsPreview({
    super.key,
    required this.comments,
    required this.showMore,
  });

  final List<Comment> comments;

  final void Function() showMore;

  @override
  State<ComicCommentsPreview> createState() => _ComicCommentsPreviewState();
}

class _ComicCommentsPreviewState extends State<ComicCommentsPreview> {
  final scrollController = ScrollController();

  late List<Comment> comments;

  @override
  void initState() {
    comments = widget.comments.where((c) => !shouldBlockComment(c)).toList();
    super.initState();
  }

  @override
  void didUpdateWidget(covariant ComicCommentsPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    comments = widget.comments.where((c) => !shouldBlockComment(c)).toList();
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  void _scroll(double offset) {
    if (scrollController.positions.length != 1) return;
    final position = scrollController.position;
    if (!position.hasPixels || !position.hasContentDimensions) return;
    scrollController.animateTo(
      (position.pixels + offset).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MultiSliver(
      children: [
        SliverLazyToBoxAdapter(
          child: ListTile(
            title: Text("Comments".tl),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => _scroll(-340),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => _scroll(340),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 184,
                child: MediaQuery.removePadding(
                  removeTop: true,
                  context: context,
                  child: ListView.builder(
                    controller: scrollController,
                    scrollDirection: Axis.horizontal,
                    itemCount: comments.length,
                    itemBuilder: (context, index) {
                      return _CommentWidget(comment: comments[index]);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ComicDetailActionButton(
                icon: const Icon(Icons.comment),
                text: "View more".tl,
                onPressed: widget.showMore,
                iconColor: context.useTextColor(Colors.green),
              ).fixHeight(48).paddingRight(8).toAlign(Alignment.centerRight),
              const SizedBox(height: 8),
            ],
          ),
        ),
        const SliverToBoxAdapter(child: Divider()),
      ],
    );
  }
}

class _CommentWidget extends StatelessWidget {
  const _CommentWidget({required this.comment});

  final Comment comment;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 0, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      width: 324,
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            children: [
              if (comment.avatar != null)
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    color: context.colorScheme.surfaceContainer,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image(
                    image: CachedImageProvider(comment.avatar!),
                    width: 36,
                    height: 36,
                    fit: BoxFit.cover,
                  ),
                ).paddingRight(8),
              Expanded(
                child: Text(
                  comment.userName,
                  style: ts.bold,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: RichCommentContent(
              text: comment.content,
              showImages: false,
            ).fixWidth(324),
          ),
          const SizedBox(height: 4),
          if (comment.time != null)
            Text(comment.time!, style: ts.s12).toAlign(Alignment.centerLeft),
        ],
      ),
    );
  }
}
