import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/image.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/image_provider/cached_image.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/translations.dart';

import 'rating.dart';

typedef ComicPageBuilder =
    Widget Function({
      required String id,
      required String sourceKey,
      String? cover,
      String? title,
      int? heroID,
    });

typedef AddComicFavoriteHandler = void Function(List<Comic> comics);

ComicPageBuilder? _comicPageBuilder;

AddComicFavoriteHandler? _addComicFavoriteHandler;

void configureComicWidgets({
  ComicPageBuilder? comicPageBuilder,
  AddComicFavoriteHandler? addFavorite,
}) {
  _comicPageBuilder = comicPageBuilder;
  _addComicFavoriteHandler = addFavorite;
}

Widget _buildComicPage({
  required String id,
  required String sourceKey,
  String? cover,
  String? title,
  int? heroID,
}) {
  final builder =
      _comicPageBuilder ??
      (throw StateError("Comic page builder is not configured."));
  return builder(
    id: id,
    sourceKey: sourceKey,
    cover: cover,
    title: title,
    heroID: heroID,
  );
}

void _openComicPage({
  BuildContext? context,
  required String id,
  required String sourceKey,
  String? cover,
  String? title,
  int? heroID,
}) {
  final targetContext = context ?? App.mainNavigatorKey?.currentContext;
  targetContext?.to(
    () => _buildComicPage(
      id: id,
      sourceKey: sourceKey,
      cover: cover,
      title: title,
      heroID: heroID,
    ),
  );
}

void _addComicToFavorites(List<Comic> comics) {
  final handler =
      _addComicFavoriteHandler ??
      (throw StateError("Add comic favorite handler is not configured."));
  handler(comics);
}

ImageProvider? _findImageProvider(Comic comic) {
  ImageProvider image;
  if (comic is LocalComic) {
    image = LocalComicImageProvider(comic);
  } else if (comic is History) {
    image = HistoryImageProvider(comic);
  } else if (comic.sourceKey == 'local') {
    var localComic = LocalManager().find(comic.id, ComicType.local);
    if (localComic == null) {
      return null;
    }
    image = FileImage(localComic.coverFile);
  } else {
    image = CachedImageProvider(
      comic.cover,
      sourceKey: comic.sourceKey,
      cid: comic.id,
      fallback: comic is FavoriteItem
          ? () => _loadLocalCoverFallback(comic.sourceKey, comic.id)
          : null,
    );
  }
  return image;
}

Future<Uint8List?> _loadLocalCoverFallback(String sourceKey, String id) async {
  final localComic = LocalManager().find(id, ComicType.fromKey(sourceKey));
  if (localComic == null) {
    return null;
  }
  final file = localComic.coverFile;
  if (!await file.exists()) {
    return null;
  }
  final data = await file.readAsBytes();
  return data.isEmpty ? null : data;
}

bool _hasNewUpdate(Comic comic) {
  final type = _comicTypeOf(comic);
  if (type == ComicType.local) {
    return false;
  }
  return LocalFavoritesManager().hasNewUpdate(comic.id, type);
}

Widget _buildUpdateBadge(BuildContext context) {
  return Container(
    height: 24,
    width: 24,
    color: Colors.deepOrange.shade700,
    child: const Icon(Icons.update, size: 16, color: Colors.white),
  );
}

ComicType _comicTypeOf(Comic comic) {
  if (comic is FavoriteItem) {
    return comic.type;
  }
  if (comic is History) {
    return comic.type;
  }
  if (comic is LocalComic) {
    return comic.comicType;
  }
  return ComicType.fromKey(comic.sourceKey);
}

class ComicTile extends StatelessWidget {
  const ComicTile({
    super.key,
    required this.comic,
    this.enableLongPressed = true,
    this.badge,
    this.menuOptions,
    this.onTap,
    this.onLongPressed,
    this.onBlocked,
    this.heroID,
  });

  final Comic comic;

  final bool enableLongPressed;

  final String? badge;

  final List<MenuEntry>? menuOptions;

  final VoidCallback? onTap;

  final VoidCallback? onLongPressed;

  final VoidCallback? onBlocked;

  final int? heroID;

  void _onTap() {
    if (onTap != null) {
      onTap!();
      return;
    }
    _openComicPage(
      id: comic.id,
      sourceKey: comic.sourceKey,
      cover: comic.cover,
      title: comic.title,
      heroID: heroID,
    );
  }

  void _onLongPressed(context) {
    if (onLongPressed != null) {
      onLongPressed!();
      return;
    }
    onLongPress(context);
  }

  void onLongPress(BuildContext context) {
    var renderBox = context.findRenderObject() as RenderBox;
    var size = renderBox.size;
    var location = renderBox.localToGlobal(
      Offset((size.width - 242) / 2, size.height / 2),
    );
    showMenu(location, context);
  }

  void onSecondaryTap(TapDownDetails details, BuildContext context) {
    showMenu(details.globalPosition, context);
  }

  void showMenu(Offset location, BuildContext context) {
    showMenuX(App.rootContext, location, [
      MenuEntry(
        icon: Icons.chrome_reader_mode_outlined,
        text: 'Details'.tl,
        onClick: () {
          _openComicPage(
            id: comic.id,
            sourceKey: comic.sourceKey,
            cover: comic.cover,
            title: comic.title,
          );
        },
      ),
      MenuEntry(
        icon: Icons.copy,
        text: 'Copy Title'.tl,
        onClick: () {
          Clipboard.setData(ClipboardData(text: comic.title));
          App.rootContext.showMessage(message: 'Title copied'.tl);
        },
      ),
      MenuEntry(
        icon: Icons.stars_outlined,
        text: 'Add to favorites'.tl,
        onClick: () {
          _addComicToFavorites([comic]);
        },
      ),
      MenuEntry(
        icon: Icons.block,
        text: 'Block'.tl,
        onClick: () => block(context),
      ),
      ...?menuOptions,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    var type = appdata.settings['comicDisplayMode'];

    Widget child = type == 'detailed'
        ? _buildDetailedMode(context)
        : _buildBriefMode(context);

    final comicType = _comicTypeOf(comic);
    var isFavorite = appdata.settings['showFavoriteStatusOnTile']
        ? LocalFavoritesManager().isExist(comic.id, comicType)
        : false;
    var history = appdata.settings['showHistoryStatusOnTile']
        ? HistoryManager().find(comic.id, comicType)
        : null;
    var hasUpdate = appdata.settings['showUpdateStatusOnTile']
        ? _hasNewUpdate(comic)
        : false;
    if (history?.page == 0) {
      history!.page = 1;
    }

    if (!isFavorite && history == null && !hasUpdate) {
      return child;
    }

    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          left: type == 'detailed' ? 16 : 6,
          top: 8,
          child: Container(
            height: 24,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(4)),
            clipBehavior: Clip.antiAlias,
            child: Row(
              children: [
                if (isFavorite)
                  Container(
                    height: 24,
                    width: 24,
                    color: Colors.green,
                    child: const Icon(
                      Icons.bookmark_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                if (history != null)
                  Container(
                    height: 24,
                    color: Colors.blue.toOpacity(0.9),
                    constraints: const BoxConstraints(minWidth: 24),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: CustomPaint(
                      painter: _ReadingHistoryPainter(
                        history.page,
                        history.maxPage,
                      ),
                    ),
                  ),
                if (hasUpdate) _buildUpdateBadge(context),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget buildImage(BuildContext context) {
    var image = _findImageProvider(comic);
    if (image == null) {
      return const SizedBox();
    }
    return AnimatedImage(
      image: image,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
    );
  }

  Widget _buildDetailedMode(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constrains) {
        final height = constrains.maxHeight - 16;

        Widget image = Container(
          width: height * 0.68,
          height: double.infinity,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: context.colorScheme.outlineVariant,
                blurRadius: 1,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: buildImage(context),
        );

        if (heroID != null) {
          image = Hero(tag: "cover$heroID", child: image);
        }

        return ClickInkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _onTap,
          onLongPress: enableLongPressed ? () => _onLongPressed(context) : null,
          onSecondaryTapDown: (detail) => onSecondaryTap(detail, context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 24, 8),
            child: Row(
              children: [
                image,
                SizedBox.fromSize(size: const Size(16, 5)),
                Expanded(
                  child: _ComicDescription(
                    title: comic.maxPage == null
                        ? comic.title.replaceAll("\n", "")
                        : "[${comic.maxPage}P]${comic.title.replaceAll("\n", "")}",
                    subtitle: comic.subtitle ?? '',
                    description: comic.description,
                    badge: badge ?? comic.language,
                    tags: comic.tags,
                    maxLines: 2,
                    enableTranslate:
                        ComicSource.find(
                          comic.sourceKey,
                        )?.enableTagsTranslate ??
                        false,
                    rating: comic.stars,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBriefMode(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        Widget image = Container(
          decoration: BoxDecoration(
            color: context.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.toOpacity(0.2),
                blurRadius: 2,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: buildImage(context),
        );

        if (heroID != null) {
          image = Hero(tag: "cover$heroID", child: image);
        }

        return ClickInkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _onTap,
          onLongPress: enableLongPressed ? () => _onLongPressed(context) : null,
          onSecondaryTapDown: (detail) => onSecondaryTap(detail, context),
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: image),
                    Align(
                      alignment: Alignment.bottomRight,
                      child: (() {
                        final subtitle = comic.subtitle
                            ?.replaceAll('\n', '')
                            .trim();
                        final text = comic.description.isNotEmpty
                            ? comic.description.split('|').join('\n')
                            : (subtitle?.isNotEmpty == true ? subtitle : null);
                        final fortSize = constraints.maxWidth < 80
                            ? 8.0
                            : constraints.maxWidth < 150
                            ? 10.0
                            : 12.0;

                        if (text == null) {
                          return const SizedBox();
                        }

                        var children = <Widget>[];
                        var lines = text.split('\n');
                        lines.removeWhere((e) => e.trim().isEmpty);
                        if (lines.length > 3) {
                          lines = lines.sublist(0, 3);
                        }
                        for (var line in lines) {
                          children.add(
                            Container(
                              margin: const EdgeInsets.fromLTRB(2, 0, 2, 2),
                              padding: constraints.maxWidth < 80
                                  ? const EdgeInsets.fromLTRB(3, 1, 3, 1)
                                  : constraints.maxWidth < 150
                                  ? const EdgeInsets.fromLTRB(4, 2, 4, 2)
                                  : const EdgeInsets.fromLTRB(5, 2, 5, 2),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                color: Colors.black.toOpacity(0.5),
                              ),
                              constraints: BoxConstraints(
                                maxWidth: constraints.maxWidth,
                              ),
                              child: Text(
                                line,
                                style: TextStyle(
                                  fontWeight: FontWeight.w500,
                                  fontSize: fortSize,
                                  color: Colors.white,
                                ),
                                textAlign: TextAlign.right,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          );
                        }
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: children,
                        );
                      })(),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                child: Text(
                  comic.title.replaceAll('\n', ''),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ).paddingHorizontal(6).paddingVertical(8),
        );
      },
    );
  }

  List<String> _splitText(String text) {
    // split text by comma, brackets
    var words = <String>[];
    var buffer = StringBuffer();
    var inBracket = false;
    String? prevBracket;
    for (var i = 0; i < text.length; i++) {
      var c = text[i];
      if (c == '[' || c == '(') {
        if (inBracket) {
          buffer.write(c);
        } else {
          if (buffer.isNotEmpty) {
            words.add(buffer.toString().trim());
            buffer.clear();
          }
          inBracket = true;
          prevBracket = c;
        }
      } else if (c == ']' || c == ')') {
        if (prevBracket == '[' && c == ']' || prevBracket == '(' && c == ')') {
          if (buffer.isNotEmpty) {
            words.add(buffer.toString().trim());
            buffer.clear();
          }
          inBracket = false;
        } else {
          buffer.write(c);
        }
      } else if (c == ',') {
        if (inBracket) {
          buffer.write(c);
        } else {
          words.add(buffer.toString().trim());
          buffer.clear();
        }
      } else {
        buffer.write(c);
      }
    }
    if (buffer.isNotEmpty) {
      words.add(buffer.toString().trim());
    }
    words.removeWhere((element) => element == "");
    words = words.toSet().toList();
    return words;
  }

  void block(BuildContext comicTileContext) {
    showDialog(
      context: App.rootContext,
      builder: (context) {
        var words = <String>[];
        var all = <String>[];
        all.addAll(_splitText(comic.title));
        if (comic.subtitle != null && comic.subtitle != "") {
          all.add(comic.subtitle!);
        }
        all.addAll(comic.tags ?? []);
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: 'Block'.tl,
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.min(400, context.height - 136),
                ),
                child: SingleChildScrollView(
                  child: Wrap(
                    runSpacing: 8,
                    spacing: 8,
                    children: [
                      for (var word in all)
                        OptionChip(
                          text: (comic.tags?.contains(word) ?? false)
                              ? word.translateTagIfNeed
                              : word,
                          isSelected: words.contains(word),
                          onTap: () {
                            setState(() {
                              if (!words.contains(word)) {
                                words.add(word);
                              } else {
                                words.remove(word);
                              }
                            });
                          },
                        ),
                    ],
                  ),
                ).paddingHorizontal(16),
              ),
              actions: [
                Button.filled(
                  onPressed: () {
                    context.pop();
                    for (var word in words) {
                      appdata.settings['blockedWords'].add(word);
                    }
                    appdata.saveData();
                    context.showMessage(message: 'Blocked'.tl);
                    onBlocked?.call();
                  },
                  child: Text('Block'.tl),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _ComicDescription extends StatelessWidget {
  const _ComicDescription({
    required this.title,
    required this.subtitle,
    required this.description,
    required this.enableTranslate,
    this.badge,
    this.maxLines = 2,
    this.tags,
    this.rating,
  });

  final String title;
  final String subtitle;
  final String description;
  final String? badge;
  final List<String>? tags;
  final int maxLines;
  final bool enableTranslate;
  final double? rating;

  @override
  Widget build(BuildContext context) {
    if (tags != null) {
      tags!.removeWhere((element) => element.removeAllBlank == "");
      for (var s in tags!) {
        s = s.replaceAll("\n", " ");
      }
    }
    var enableTranslate =
        App.locale.languageCode == 'zh' && this.enableTranslate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title.trim(),
          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14.0),
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          softWrap: true,
        ),
        if (subtitle != "")
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 10.0,
              color: context.colorScheme.onSurface.toOpacity(0.7),
            ),
            maxLines: 1,
            softWrap: true,
            overflow: TextOverflow.ellipsis,
          ),
        const SizedBox(height: 4),
        if (tags != null && tags!.isNotEmpty)
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxHeight < 22) {
                  return Container();
                }
                int cnt = (constraints.maxHeight - 22).toInt() ~/ 25;
                return Container(
                  clipBehavior: Clip.antiAlias,
                  height: 21 + cnt * 24,
                  width: double.infinity,
                  decoration: const BoxDecoration(),
                  child: Wrap(
                    runAlignment: WrapAlignment.start,
                    clipBehavior: Clip.antiAlias,
                    crossAxisAlignment: WrapCrossAlignment.end,
                    spacing: 4,
                    runSpacing: 3,
                    children: [
                      for (var s in tags!)
                        Container(
                          height: 21,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth * 0.45,
                          ),
                          decoration: BoxDecoration(
                            color: s == "Unavailable"
                                ? context.colorScheme.errorContainer
                                : context.colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Center(
                            widthFactor: 1,
                            child: Text(
                              enableTranslate
                                  ? TagsTranslation.translateTag(s)
                                  : s.split(':').last,
                              style: const TextStyle(fontSize: 12),
                              softWrap: true,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                        ),
                    ],
                  ),
                ).toAlign(Alignment.topCenter);
              },
            ),
          )
        else
          const Spacer(),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (rating != null) StarRating(value: rating!, size: 18),
                  Text(
                    description,
                    style: const TextStyle(fontSize: 12.0),
                    maxLines: (tags == null || tags!.isEmpty) ? 3 : 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (badge != null)
              Container(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                ),
                child: Center(
                  child: Text(
                    "${badge![0].toUpperCase()}${badge!.substring(1).toLowerCase()}",
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _ReadingHistoryPainter extends CustomPainter {
  final int page;
  final int? maxPage;

  const _ReadingHistoryPainter(this.page, this.maxPage);

  @override
  void paint(Canvas canvas, Size size) {
    if (maxPage == null) {
      // 在中央绘制page
      final textPainter = TextPainter(
        text: TextSpan(
          text: "$page",
          style: TextStyle(fontSize: size.width * 0.8, color: Colors.white),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(
          (size.width - textPainter.width) / 2,
          (size.height - textPainter.height) / 2,
        ),
      );
    } else if (page == maxPage) {
      // 在中央绘制勾
      final paint = Paint()
        ..color = Colors.white
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      canvas.drawLine(
        Offset(size.width * 0.2, size.height * 0.5),
        Offset(size.width * 0.45, size.height * 0.75),
        paint,
      );
      canvas.drawLine(
        Offset(size.width * 0.45, size.height * 0.75),
        Offset(size.width * 0.85, size.height * 0.3),
        paint,
      );
    } else {
      // 在左上角绘制page, 在右下角绘制maxPage
      final textPainter = TextPainter(
        text: TextSpan(
          text: "$page",
          style: TextStyle(fontSize: size.width * 0.8, color: Colors.white),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, const Offset(0, 0));
      final textPainter2 = TextPainter(
        text: TextSpan(
          text: "/$maxPage",
          style: TextStyle(fontSize: size.width * 0.5, color: Colors.white),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter2.layout();
      textPainter2.paint(
        canvas,
        Offset(
          size.width - textPainter2.width,
          size.height - textPainter2.height,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is! _ReadingHistoryPainter ||
        oldDelegate.page != page ||
        oldDelegate.maxPage != maxPage;
  }
}

class SimpleComicTile extends StatelessWidget {
  const SimpleComicTile({
    super.key,
    required this.comic,
    this.onTap,
    this.withTitle = false,
    this.heroID,
    this.gaplessPlayback = false,
  });

  final Comic comic;

  final void Function()? onTap;

  final bool withTitle;

  final int? heroID;

  final bool gaplessPlayback;

  @override
  Widget build(BuildContext context) {
    var image = _findImageProvider(comic);

    Widget child = image == null
        ? const SizedBox()
        : AnimatedImage(
            image: image,
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: gaplessPlayback,
          );

    child = Container(
      width: 98,
      height: 136,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Theme.of(context).colorScheme.secondaryContainer,
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );

    if (appdata.settings['showUpdateStatusOnTile'] && _hasNewUpdate(comic)) {
      child = Stack(
        children: [
          child,
          Positioned(
            left: 0,
            top: 0,
            child: Container(
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.only(
                  bottomRight: Radius.circular(4),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: _buildUpdateBadge(context),
            ),
          ),
        ],
      );
    }

    if (heroID != null) {
      child = Hero(tag: "cover$heroID", child: child);
    }

    child = AnimatedTapRegion(
      borderRadius: 8,
      onTap:
          onTap ??
          () {
            _openComicPage(
              context: context,
              id: comic.id,
              sourceKey: comic.sourceKey,
              cover: comic.cover,
              title: comic.title,
              heroID: heroID,
            );
          },
      child: child,
    );

    if (withTitle) {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          child,
          const SizedBox(height: 4),
          SizedBox(
            width: 92,
            child: Center(
              child: Text(
                comic.title.replaceAll('\n', ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      );
    }

    return child;
  }
}
