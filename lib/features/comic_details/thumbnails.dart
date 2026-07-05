import 'package:flutter/material.dart';
import 'package:sliver_tools/sliver_tools.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/image.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/consts.dart';
import 'package:venera_next/foundation/image_provider/cached_image.dart';
import 'package:venera_next/foundation/translations.dart';

class ComicThumbnails extends StatefulWidget {
  const ComicThumbnails({
    super.key,
    required this.comicId,
    required this.sourceKey,
    required this.initialThumbnails,
    required this.loadComicThumbnail,
    required this.readPage,
  });

  final String comicId;
  final String sourceKey;
  final List<String> initialThumbnails;
  final ComicThumbnailLoader? loadComicThumbnail;
  final void Function(int page) readPage;

  @override
  State<ComicThumbnails> createState() => _ComicThumbnailsState();
}

class _ComicThumbnailsState extends State<ComicThumbnails> {
  late List<String> thumbnails;

  bool isInitialLoading = true;

  String? next;

  String? error;

  bool isLoading = false;

  @override
  void initState() {
    super.initState();
    thumbnails = List.from(widget.initialThumbnails);
    loadNext();
  }

  void loadNext() async {
    final loadComicThumbnail = widget.loadComicThumbnail;
    if (loadComicThumbnail == null) return;
    if (!isInitialLoading && next == null) {
      return;
    }
    if (isLoading) return;
    Future.microtask(() {
      setState(() {
        isLoading = true;
      });
    });
    var res = await loadComicThumbnail(widget.comicId, next);
    if (res.success) {
      thumbnails.addAll(res.data);
      next = res.subData;
      isInitialLoading = false;
    } else {
      error = res.errorMessage;
    }
    if (mounted) {
      setState(() {
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiSliver(
      children: [
        SliverToBoxAdapter(child: ListTile(title: Text("Preview".tl))),
        SliverGrid(
          delegate: SliverChildBuilderDelegate((context, index) {
            if (index == thumbnails.length - 1 && error == null) {
              loadNext();
            }
            var url = thumbnails[index];
            ImagePart? part;
            if (url.contains('@')) {
              var params = url.split('@')[1].split('&');
              url = url.split('@')[0];
              double? x1, y1, x2, y2;
              try {
                for (var p in params) {
                  if (p.startsWith('x')) {
                    var r = p.split('=')[1];
                    x1 = double.parse(r.split('-')[0]);
                    x2 = double.parse(r.split('-')[1]);
                  }
                  if (p.startsWith('y')) {
                    var r = p.split('=')[1];
                    y1 = double.parse(r.split('-')[0]);
                    y2 = double.parse(r.split('-')[1]);
                  }
                }
              } catch (_) {
                // ignore
              }
              part = ImagePart(x1: x1, y1: y1, x2: x2, y2: y2);
            }
            return Padding(
              padding: context.width < changePoint
                  ? const EdgeInsets.all(4)
                  : const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Expanded(
                    child: ClickInkWell(
                      onTap: () => widget.readPage(index + 1),
                      borderRadius: const BorderRadius.all(Radius.circular(8)),
                      child: Container(
                        foregroundDecoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        width: double.infinity,
                        height: double.infinity,
                        clipBehavior: Clip.antiAlias,
                        child: AnimatedImage(
                          image: CachedImageProvider(
                            url,
                            sourceKey: widget.sourceKey,
                          ),
                          fit: BoxFit.contain,
                          width: double.infinity,
                          height: double.infinity,
                          part: part,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text((index + 1).toString()),
                ],
              ),
            );
          }, childCount: thumbnails.length),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 200,
            childAspectRatio: 0.68,
          ),
        ),
        if (error != null)
          SliverToBoxAdapter(
            child: Column(
              children: [
                Text(error!),
                Button.outlined(onPressed: loadNext, child: Text("Retry".tl)),
              ],
            ),
          )
        else if (isLoading)
          const SliverListLoadingIndicator(),
        const SliverToBoxAdapter(child: Divider()),
      ],
    );
  }
}
