import 'package:flutter/material.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/foundation/translations.dart';

import 'favorite_folder.dart';

/// Shared folder navigation for browsing, membership and destination picking.
/// Expansion is presentation-only; searching never changes stored hierarchy.
class FavoriteFolderBrowser extends StatefulWidget {
  const FavoriteFolderBrowser({
    super.key,
    required this.tree,
    required this.onSelected,
    this.selected = const {},
    this.disabled = const {},
    this.hidden = const {},
    this.enabled = true,
    this.checkboxes = false,
    this.countFor,
    this.trailingBuilder,
    this.headers = const [],
    this.footers = const [],
    this.padding = EdgeInsets.zero,
    this.shrinkWrap = false,
  });

  final FavoriteFolderTree tree;
  final ValueChanged<String> onSelected;
  final Set<String> selected;
  final Set<String> disabled;
  final Set<String> hidden;
  final bool enabled;
  final bool checkboxes;
  final int Function(String)? countFor;
  final Widget Function(String)? trailingBuilder;
  final List<Widget> headers;
  final List<Widget> footers;
  final EdgeInsetsGeometry padding;
  final bool shrinkWrap;

  @override
  State<FavoriteFolderBrowser> createState() => _FavoriteFolderBrowserState();
}

class _FavoriteFolderBrowserState extends State<FavoriteFolderBrowser> {
  final _search = TextEditingController();
  final _expanded = <String>{};
  String _query = '';

  @override
  void initState() {
    super.initState();
    _revealSelection();
  }

  void _revealSelection() {
    for (final name in widget.selected) {
      final parent = widget.tree.named(name)?.parentId;
      if (parent != null) _expanded.add(parent);
    }
  }

  @override
  void didUpdateWidget(FavoriteFolderBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.selected.containsAll(widget.selected) ||
        widget.selected.any(
          (name) =>
              oldWidget.tree.named(name)?.parentId !=
              widget.tree.named(name)?.parentId,
        )) {
      _revealSelection();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = <FavoriteFolder>[];
    final tree = widget.tree;
    for (final root in tree.roots) {
      final children = tree
          .childrenOf(root.id)
          .where((folder) => !widget.hidden.contains(folder.name))
          .toList();
      if (widget.hidden.contains(root.name) && children.isEmpty) continue;
      final matches = children
          .where(
            (child) => tree.label(child.name).toLowerCase().contains(_query),
          )
          .toList();
      if (_query.isNotEmpty &&
          !root.name.toLowerCase().contains(_query) &&
          matches.isEmpty) {
        continue;
      }
      rows.add(root);
      if (_query.isNotEmpty) {
        rows.addAll(matches);
      } else if (_expanded.contains(root.id)) {
        rows.addAll(children);
      }
    }
    return CustomScrollView(
      primary: false,
      shrinkWrap: widget.shrinkWrap,
      slivers: [
        SliverPadding(
          padding: widget.padding,
          sliver: SliverMainAxisGroup(
            slivers: [
              SliverList.list(children: widget.headers),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: TextField(
                    key: const ValueKey('favorite-folder-search'),
                    controller: _search,
                    enabled: widget.enabled,
                    decoration: InputDecoration(
                      labelText: 'Search local folders'.tl,
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear'.tl,
                              icon: const Icon(Icons.close),
                              onPressed: () => setState(() {
                                _search.clear();
                                _query = '';
                              }),
                            ),
                    ),
                    onChanged: (value) =>
                        setState(() => _query = value.trim().toLowerCase()),
                  ),
                ),
              ),
              if (rows.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('No folders found'.tl),
                  ),
                ),
              SliverList.builder(
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final folder = rows[index];
                  final children = tree.childrenOf(folder.id);
                  final expanded =
                      _query.isNotEmpty || _expanded.contains(folder.id);
                  final enabled =
                      widget.enabled && !widget.disabled.contains(folder.name);
                  final child = folder.parentId != null;
                  final count = widget.countFor?.call(folder.name);
                  final title = Text(folder.name, softWrap: true);
                  final subtitle = child && _query.isNotEmpty
                      ? Text(tree.label(folder.name))
                      : children.isEmpty
                      ? null
                      : Text('@a subfolders'.tlParams({'a': children.length}));
                  final trailing =
                      widget.trailingBuilder?.call(folder.name) ??
                      (count == null
                          ? null
                          : Tooltip(
                              message: 'Comics directly in this folder'.tl,
                              child: Chip(
                                label: Text('$count'),
                                visualDensity: VisualDensity.compact,
                              ),
                            ));
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final stackedCount =
                          count != null &&
                          widget.trailingBuilder == null &&
                          constraints.maxWidth < 320 &&
                          MediaQuery.textScalerOf(context).scale(16) > 24;
                      final secondary = stackedCount
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ?subtitle,
                                Text('@a comics'.tlParams({'a': count})),
                              ],
                            )
                          : subtitle;
                      return Row(
                        key: ValueKey('favorite-folder-${folder.id}'),
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (child) const SizedBox(width: 24),
                          SizedBox(
                            width: 48,
                            child: children.isEmpty
                                ? const ExcludeSemantics(
                                    child: Icon(Icons.folder_outlined),
                                  )
                                : Semantics(
                                    label: folder.name,
                                    expanded: expanded,
                                    child: IconButton(
                                      tooltip:
                                          (expanded
                                                  ? 'Collapse folder'
                                                  : 'Expand folder')
                                              .tl,
                                      icon: Icon(
                                        expanded
                                            ? Icons.expand_more
                                            : Icons.chevron_right,
                                      ),
                                      onPressed:
                                          !widget.enabled || _query.isNotEmpty
                                          ? null
                                          : () => setState(() {
                                              if (!_expanded.add(folder.id)) {
                                                _expanded.remove(folder.id);
                                              }
                                            }),
                                    ),
                                  ),
                          ),
                          Expanded(
                            child: widget.checkboxes
                                ? CheckboxListTile(
                                    title: title,
                                    subtitle: secondary,
                                    value: widget.selected.contains(
                                      folder.name,
                                    ),
                                    onChanged: enabled
                                        ? (_) => widget.onSelected(folder.name)
                                        : null,
                                  )
                                : ListTile(
                                    title: title,
                                    subtitle: secondary,
                                    trailing: stackedCount ? null : trailing,
                                    selected: widget.selected.contains(
                                      folder.name,
                                    ),
                                    enabled: enabled,
                                    onTap: enabled
                                        ? () => widget.onSelected(folder.name)
                                        : null,
                                    contentPadding: const EdgeInsets.only(
                                      left: 4,
                                      right: 12,
                                    ),
                                  ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
              SliverList.list(children: widget.footers),
            ],
          ),
        ),
      ],
    );
  }
}

class FavoriteFolderSelect extends StatelessWidget {
  const FavoriteFolderSelect({
    super.key,
    required this.tree,
    required this.current,
    required this.onChanged,
    this.allowRoot = false,
    this.rootsOnly = false,
    this.disabled = const {},
    this.nullLabel,
    this.menuOwnerContext,
  });
  final FavoriteFolderTree tree;
  final String? current;
  final ValueChanged<String?>? onChanged;
  final bool allowRoot;
  final bool rootsOnly;
  final Set<String> disabled;
  final String? nullLabel;
  final BuildContext? menuOwnerContext;

  @override
  Widget build(BuildContext context) {
    final choices = rootsOnly ? FavoriteFolderTree(tree.roots) : tree;
    final names = [
      if (allowRoot) '',
      ...choices.flattened.map((folder) => folder.name),
    ];
    return Select(
      menuOwnerContext: menuOwnerContext,
      current: current ?? (allowRoot ? '' : null),
      values: names,
      labels: {
        if (allowRoot) '': nullLabel ?? 'First-level folder'.tl,
        for (final name in names)
          if (name.isNotEmpty) name: choices.label(name),
      },
      minWidth: 112,
      onTap: onChanged == null
          ? null
          : (index) {
              final name = names[index];
              if (!disabled.contains(name)) {
                onChanged!(name.isEmpty ? null : name);
              }
            },
      menuBuilder: (context, select) => FavoriteFolderBrowser(
        tree: choices,
        selected: {?current},
        disabled: disabled,
        onSelected: select,
        headers: [
          if (allowRoot)
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: Text(nullLabel ?? 'First-level folder'.tl),
              selected: current == null,
              onTap: () => select(''),
            ),
        ],
      ),
    );
  }
}
