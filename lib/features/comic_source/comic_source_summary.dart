import 'package:flutter/material.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/translations.dart';

import 'comic_source_manager.dart';
import 'comic_source_page.dart';
import 'parser.dart';
import 'source.dart';

class ComicSourceSummary extends StatefulWidget {
  const ComicSourceSummary({super.key});

  @override
  State<ComicSourceSummary> createState() => _ComicSourceSummaryState();
}

class _ComicSourceSummaryState extends State<ComicSourceSummary> {
  late List<String> comicSources;

  void onComicSourceChange() {
    setState(() {
      comicSources = ComicSource.all().map((e) => e.name).toList();
    });
  }

  @override
  void initState() {
    comicSources = ComicSource.all().map((e) => e.name).toList();
    ComicSourceManager().addListener(onComicSourceChange);
    super.initState();
  }

  @override
  void dispose() {
    ComicSourceManager().removeListener(onComicSourceChange);
    super.dispose();
  }

  int get _availableUpdates {
    int c = 0;
    ComicSourceManager().availableUpdates.forEach((key, version) {
      var source = ComicSource.find(key);
      if (source != null) {
        if (compareSemVer(version, source.version)) {
          c++;
        }
      }
    });
    return c;
  }

  @override
  Widget build(BuildContext context) {
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
            context.to(() => const ComicSourcePage());
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    Center(child: Text('Comic Source'.tl, style: ts.s18)),
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        comicSources.length.toString(),
                        style: ts.s12,
                      ),
                    ),
                    const Spacer(),
                    const Icon(Icons.arrow_right),
                  ],
                ),
              ).paddingHorizontal(16),
              if (comicSources.isNotEmpty)
                SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    runSpacing: 8,
                    spacing: 8,
                    children: comicSources.map((e) {
                      return Container(
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
                        child: Text(e),
                      );
                    }).toList(),
                  ).paddingHorizontal(16).paddingBottom(16),
                ),
              if (_availableUpdates > 0)
                Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: context.colorScheme.outlineVariant,
                          width: 0.6,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.update,
                            color: context.colorScheme.primary,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            "@c updates".tlParams({'c': _availableUpdates}),
                            style: ts.withColor(context.colorScheme.primary),
                          ),
                        ],
                      ),
                    )
                    .toAlign(Alignment.centerLeft)
                    .paddingHorizontal(16)
                    .paddingBottom(8),
            ],
          ),
        ),
      ),
    );
  }
}
