import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera_next/components/keyword_match_preview.dart';
import 'package:venera_next/components/keyword_rule_labels.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/keyword_filter.dart';
import 'package:venera_next/foundation/translations.dart';

import 'comic_tile.dart';

class KeywordHiddenNotice extends StatelessWidget {
  const KeywordHiddenNotice({
    super.key,
    required this.count,
    required this.comics,
  });
  final int count;
  final List<Comic> Function() comics;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        'Hidden by keyword filters: @a comics'.tlParams({'a': count}),
      ),
      subtitle: Text('View reasons'.tl),
      trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
      onTap: () {
        final work = context
            .getInheritedWidgetOfExactType<SettingsSaveScope>()
            ?.work;
        showDialog<void>(
          context: context,
          animationStyle: MediaQuery.disableAnimationsOf(context)
              ? AnimationStyle.noAnimation
              : null,
          builder: (_) {
            final dialog = _KeywordHiddenDialog(comics: comics);
            return work == null
                ? dialog
                : SettingsSaveScope(work: work, child: dialog);
          },
        );
      },
    ),
  );
}

class _KeywordHiddenDialog extends StatefulWidget {
  const _KeywordHiddenDialog({required this.comics});
  final List<Comic> Function() comics;

  @override
  State<_KeywordHiddenDialog> createState() => _KeywordHiddenDialogState();
}

class _KeywordHiddenDialogState extends State<_KeywordHiddenDialog> {
  bool _showCovers = false;

  @override
  void initState() {
    super.initState();
    appdata.settings.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filter = KeywordFilter.fromSettings(appdata.settings);
    final editRule = comicKeywordRuleEditor;
    final hidden = <(Comic, KeywordMatch)>[];
    for (final comic in widget.comics()) {
      final match = filter.comicMatch(
        title: comic.title,
        subtitle: comic.subtitle,
        description: comic.description,
        tags: comic.tags ?? const [],
      );
      if (match != null) hidden.add((comic, match));
    }
    return ContentDialog(
      title: 'Keyword filter reasons'.tl,
      content: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(
                  _showCovers
                      ? 'Covers are shown. Tap a cover to open its details.'.tl
                      : 'Only comics in this list are checked. Images stay hidden.'
                            .tl,
                ),
                TextButton.icon(
                  key: const ValueKey('keyword-reasons-toggle-covers'),
                  onPressed: () => setState(() => _showCovers = !_showCovers),
                  icon: Icon(
                    _showCovers
                        ? Icons.image_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  label: Text(
                    _showCovers ? 'Hide covers'.tl : 'Show covers'.tl,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: 560,
              height: hidden.isEmpty
                  ? 80
                  : math.min(400, MediaQuery.sizeOf(context).height * 0.5),
              child: hidden.isEmpty
                  ? Center(
                      child: Text(
                        'No comics in this list are hidden by keywords.'.tl,
                      ),
                    )
                  : ListView.separated(
                      key: const ValueKey('keyword-reasons-list'),
                      itemCount: hidden.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final (comic, match) = hidden[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (_showCovers)
                                Padding(
                                  padding: const EdgeInsetsDirectional.only(
                                    end: 12,
                                  ),
                                  child: _ReasonCover(comic: comic),
                                ),
                              Expanded(
                                child: _ReasonText(
                                  comic: comic,
                                  match: match,
                                  editRule: editRule,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: Text('Close'.tl),
        ),
      ],
    );
  }
}

class _ReasonText extends StatelessWidget {
  const _ReasonText({
    required this.comic,
    required this.match,
    required this.editRule,
  });

  final Comic comic;
  final KeywordMatch match;
  final ComicKeywordRuleEditor? editRule;

  @override
  Widget build(BuildContext context) {
    final onEdit = editRule == null
        ? null
        : () => editRule!(context, match.rule);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onEdit,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (match.field == KeywordMatchField.title)
                KeywordMatchPreview(match: match)
              else
                Text(
                  comic.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              const SizedBox(height: 8),
              Text('Matched in @a'.tlParams({'a': match.field.label})),
              if (match.field != KeywordMatchField.title)
                KeywordMatchPreview(match: match),
              Text(
                'Keyword: @a'.tlParams({
                  'a': match.rule.keyword.isEmpty
                      ? 'Empty keyword'.tl
                      : match.rule.keyword,
                }),
              ),
              Text(keywordRuleSummary(match.rule)),
            ],
          ),
        ),
        if (editRule != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => editRule!(context, match.rule),
              icon: const Icon(Icons.edit_outlined),
              label: Text('Edit rule'.tl),
            ),
          ),
      ],
    );
  }
}

class _ReasonCover extends StatelessWidget {
  const _ReasonCover({required this.comic});

  final Comic comic;

  static const double _width = 56;
  static const double _height = 78;

  @override
  Widget build(BuildContext context) {
    final image = comicTileImageProvider(comic);
    return Tooltip(
      message: 'Details'.tl,
      child: Semantics(
        button: true,
        label: '${'Details'.tl}: ${comic.title}',
        child: InkWell(
          key: ValueKey('keyword-reasons-cover:${comic.sourceKey}:${comic.id}'),
          onTap: () => openComicPage(
            context: context,
            id: comic.id,
            sourceKey: comic.sourceKey,
            cover: comic.cover,
            title: comic.title,
          ),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: _width,
            height: _height,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: image == null
                ? const _NoCoverPlaceholder()
                : ComicTile(
                    comic: comic,
                  ).buildImage(context, image: image, onError: (_, _) {}),
          ),
        ),
      ),
    );
  }
}

class _NoCoverPlaceholder extends StatelessWidget {
  const _NoCoverPlaceholder();

  @override
  Widget build(BuildContext context) => Center(
    key: const ValueKey('keyword-reasons-no-cover'),
    child: Tooltip(
      message: 'No cover'.tl,
      child: Icon(
        Icons.image_outlined,
        color: Theme.of(context).colorScheme.onSecondaryContainer,
        semanticLabel: 'No cover'.tl,
      ),
    ),
  );
}
