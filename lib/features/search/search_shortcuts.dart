import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';
import 'package:venera_next/routing/page_jump_target.dart';

import 'search_shortcut.dart';
import 'search_shortcut_manager.dart';

PageJumpTarget? resolveSearchShortcut(SearchShortcut shortcut) {
  return ComicSource.find(
    shortcut.sourceKey,
  )?.handleClickTagEvent?.call(shortcut.namespace, shortcut.value);
}

void openSearchShortcut(BuildContext context, SearchShortcut shortcut) {
  final target = resolveSearchShortcut(shortcut);
  if (target == null) {
    context.showMessage(message: 'Search shortcut unavailable'.tl);
    return;
  }
  target.jump(context);
}

void showSearchShortcutMenu({
  required MenuRouteController menus,
  bool Function()? isValid,
  required BuildContext context,
  required Offset location,
  required String copyText,
  SearchShortcut? shortcut,
}) {
  final manager = SearchShortcutManager.instance;
  final entries = <MenuEntry>[
    MenuEntry(
      icon: Icons.copy,
      text: 'Copy'.tl,
      onClick: () {
        Clipboard.setData(ClipboardData(text: copyText));
        context.showMessage(message: 'Copied'.tl);
      },
    ),
  ];
  if (shortcut != null) {
    final saved = manager.contains(shortcut);
    entries.add(
      MenuEntry(
        icon: saved ? Icons.bookmark_remove : Icons.bookmark_add,
        text: saved
            ? (shortcut.isAuthor
                  ? 'Unfavorite author'.tl
                  : 'Remove tag shortcut'.tl)
            : (shortcut.isAuthor
                  ? 'Favorite author'.tl
                  : 'Save tag shortcut'.tl),
        onClick: () async {
          try {
            await (saved ? manager.remove(shortcut) : manager.add(shortcut));
            if (context.mounted) {
              context.showMessage(
                message: saved
                    ? 'Search shortcut removed'.tl
                    : 'Search shortcut saved'.tl,
              );
            }
          } catch (error, stack) {
            Log.error('Search shortcut', error, stack);
            if (context.mounted) context.showMessage(message: error.toString());
          }
        },
      ),
    );
  }
  menus.show(context, location, entries, isValid: isValid);
}

class SearchShortcutsSliver extends StatefulWidget {
  const SearchShortcutsSliver({super.key});

  @override
  State<SearchShortcutsSliver> createState() => _SearchShortcutsSliverState();
}

class _SearchShortcutsSliverState extends State<SearchShortcutsSliver> {
  final manager = SearchShortcutManager.instance;

  @override
  void initState() {
    super.initState();
    manager.addListener(_update);
  }

  @override
  void dispose() {
    manager.removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = manager.all;
    if (shortcuts.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    final authors = shortcuts
        .where((shortcut) => shortcut.isAuthor)
        .toList(growable: false);
    final tags = shortcuts
        .where((shortcut) => !shortcut.isAuthor)
        .toList(growable: false);
    final children = <Widget>[
      const SizedBox(height: 16),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.bookmarks_outlined),
        title: Text('Search shortcuts'.tl),
      ),
      if (authors.isNotEmpty) ...[
        _buildSectionTitle('Favorite authors'.tl),
        for (final shortcut in authors) _buildItem(context, shortcut),
      ],
      if (tags.isNotEmpty) ...[
        _buildSectionTitle('Saved tag searches'.tl),
        for (final shortcut in tags) _buildItem(context, shortcut),
      ],
    ];
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) => children[index],
        childCount: children.length,
      ),
    ).sliverPaddingHorizontal(16);
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildItem(BuildContext context, SearchShortcut shortcut) {
    final source = ComicSource.find(shortcut.sourceKey);
    final sourceName = source?.name ?? shortcut.sourceKey;
    final subtitle = '$sourceName · ${shortcut.namespace}';

    return ContextMenuRegion(
      identity: shortcut.identity,
      builder: (itemContext, menus) {
        void showShortcutMenu([Offset? position]) {
          final renderBox = itemContext.findRenderObject() as RenderBox;
          final offset = renderBox.localToGlobal(Offset.zero);
          final location =
              position ??
              Offset(
                offset.dx + renderBox.size.width / 2 - 121,
                offset.dy + renderBox.size.height - 8,
              );
          showSearchShortcutMenu(
            menus: menus,
            context: itemContext,
            location: location,
            copyText: shortcut.value,
            shortcut: shortcut,
          );
        }

        return ClickInkWell(
          onTap: () => openSearchShortcut(itemContext, shortcut),
          onLongPress: () => showShortcutMenu(),
          onSecondaryTapUp: (details) =>
              showShortcutMenu(details.globalPosition),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              shortcut.isAuthor ? Icons.person_outline : Icons.label_outline,
            ),
            title: Text(
              shortcut.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      },
    );
  }
}
