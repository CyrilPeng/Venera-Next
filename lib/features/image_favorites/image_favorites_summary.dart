import 'package:flutter/material.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';

import 'image_favorites_page.dart';

class ImageFavoritesSummary extends StatefulWidget {
  const ImageFavoritesSummary({super.key});

  @override
  State<ImageFavoritesSummary> createState() => _ImageFavoritesSummaryState();
}

class _ImageFavoritesSummaryState extends State<ImageFavoritesSummary> {
  ImageFavoritesComputed? imageFavoritesCompute;

  int displayType = 0;

  void refreshImageFavorites() async {
    try {
      imageFavoritesCompute =
          await ImageFavoriteManager.computeImageFavorites();
      if (mounted) {
        setState(() {});
      }
    } catch (e, stackTrace) {
      Log.error("Unhandled Exception", e.toString(), stackTrace);
    }
  }

  @override
  void initState() {
    refreshImageFavorites();
    ImageFavoriteManager().addListener(refreshImageFavorites);
    super.initState();
  }

  @override
  void dispose() {
    ImageFavoriteManager().removeListener(refreshImageFavorites);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool hasData =
        imageFavoritesCompute != null && !imageFavoritesCompute!.isEmpty;
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClickInkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            context.to(() => const ImageFavoritesPage());
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    Center(child: Text('Image Favorites'.tl, style: ts.s18)),
                    if (hasData)
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          imageFavoritesCompute!.count.toString(),
                          style: ts.s12,
                        ),
                      ),
                    const Spacer(),
                    const Icon(Icons.arrow_right),
                  ],
                ),
              ).paddingHorizontal(16),
              if (hasData)
                Row(
                  children: [
                    const Spacer(),
                    buildTypeButton(0, "Tags".tl),
                    const Spacer(),
                    buildTypeButton(1, "Authors".tl),
                    const Spacer(),
                    buildTypeButton(2, "Comics".tl),
                    const Spacer(),
                  ],
                ),
              if (hasData) const SizedBox(height: 8),
              if (hasData)
                buildChart(switch (displayType) {
                  0 => imageFavoritesCompute!.tags,
                  1 => imageFavoritesCompute!.authors,
                  2 => imageFavoritesCompute!.comics,
                  _ => [],
                }).paddingHorizontal(16).paddingBottom(16),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildTypeButton(int type, String text) {
    const radius = 24.0;
    return ClickInkWell(
      borderRadius: BorderRadius.circular(radius),
      onTap: () async {
        setState(() {
          displayType = type;
        });
        await Future.delayed(const Duration(milliseconds: 20));
        var scrollController = ScrollState.of(context).controller;
        scrollController.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.ease,
        );
      },
      child: AnimatedContainer(
        width: 96,
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: displayType == type
              ? context.colorScheme.primaryContainer
              : null,
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(radius),
        ),
        duration: const Duration(milliseconds: 200),
        child: Center(child: Text(text, style: ts.s16)),
      ),
    );
  }

  Widget buildChart(List<TextWithCount> data) {
    if (data.isEmpty) {
      return const SizedBox();
    }
    var maxCount = data.map((e) => e.count).reduce((a, b) => a > b ? a : b);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: 164),
      child: SingleChildScrollView(
        child: Column(
          key: ValueKey(displayType),
          children: data.map((e) {
            return _ChartLine(
              text: e.text,
              count: e.count,
              maxCount: maxCount,
              enableTranslation: displayType != 2,
              onTap: (text) {
                context.to(() => ImageFavoritesPage(initialKeyword: text));
              },
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _ChartLine extends StatefulWidget {
  const _ChartLine({
    required this.text,
    required this.count,
    required this.maxCount,
    required this.enableTranslation,
    this.onTap,
  });

  final String text;

  final int count;

  final int maxCount;

  final bool enableTranslation;

  final void Function(String text)? onTap;

  @override
  State<_ChartLine> createState() => __ChartLineState();
}

class __ChartLineState extends State<_ChartLine>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 0,
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var text = widget.text;
    var enableTranslation =
        App.locale.countryCode == 'CN' && widget.enableTranslation;
    if (enableTranslation) {
      text = text.translateTagsToCN;
    }
    if (widget.enableTranslation && text.contains(':')) {
      text = text.split(':').last;
    }
    return Row(
      children: [
        ClickInkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () {
            widget.onTap?.call(widget.text);
          },
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis)
              .paddingHorizontal(4)
              .toAlign(Alignment.centerLeft)
              .fixWidth(context.width > 600 ? 120 : 80)
              .fixHeight(double.infinity),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constrains) {
              var width = constrains.maxWidth * widget.count / widget.maxCount;
              return AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return Container(
                    width: width * _controller.value,
                    height: 18,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      gradient: LinearGradient(
                        colors: context.isDarkMode
                            ? [Colors.blue.shade800, Colors.blue.shade500]
                            : [Colors.blue.shade300, Colors.blue.shade600],
                      ),
                    ),
                  ).toAlign(Alignment.centerLeft);
                },
              );
            },
          ),
        ),
        const SizedBox(width: 8),
        Text(
          widget.count.toString(),
          style: ts.s12,
        ).fixWidth(context.width > 600 ? 60 : 30),
      ],
    ).fixHeight(28);
  }
}
