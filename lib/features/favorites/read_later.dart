import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';

import 'favorites_manager.dart';

class ReadLaterButton extends StatelessWidget {
  const ReadLaterButton({super.key, required this.comic, this.onChanged});

  final FavoriteItem comic;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final manager = LocalFavoritesManager();
    return ListenableBuilder(
      listenable: Listenable.merge([manager, appdata.settings]),
      builder: (context, _) {
        final included = manager.isInReadLater(comic.id, comic.type);
        final label = included ? 'Remove from read later'.tl : 'Read later'.tl;
        return Tooltip(
          message: label,
          child: TextButton.icon(
            onPressed: () async {
              try {
                await manager.setReadLater(
                  comic,
                  included: !included,
                  folderName: 'Read later'.tl,
                );
                if (context.mounted) {
                  onChanged?.call();
                  context.showMessage(
                    message: included
                        ? 'Removed from read later'.tl
                        : 'Added to read later'.tl,
                  );
                }
              } catch (error) {
                if (context.mounted) {
                  context.showMessage(message: error.toString());
                }
              }
            },
            icon: Icon(
              included ? Icons.bookmark_added : Icons.watch_later_outlined,
            ),
            label: Text(label),
          ),
        );
      },
    );
  }
}

class ReadLaterSummary extends StatelessWidget {
  const ReadLaterSummary({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = LocalFavoritesManager();
    return ListenableBuilder(
      listenable: Listenable.merge([manager, appdata.settings]),
      builder: (context, _) {
        final comics = manager.getReadLaterComics(limit: 10);
        final folder = manager.readLaterFolder;
        final count = folder == null ? 0 : manager.count(folder);
        return SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
                width: 0.6,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.watch_later_outlined),
                  title: Text('${'Read later'.tl} · $count'),
                  trailing: folder == null
                      ? null
                      : const Icon(Icons.chevron_right),
                  onTap: folder == null
                      ? null
                      : () => context.to(() => const ReadLaterPage()),
                ),
                if (comics.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text(
                      'Save comics here with Read later on the details page.'
                          .tl,
                    ),
                  )
                else
                  SizedBox(
                    height: 152,
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      scrollDirection: Axis.horizontal,
                      itemCount: comics.length,
                      itemBuilder: (context, index) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: SimpleComicTile(
                          comic: comics[index],
                          // Keep hero tags separate from the adjacent history card.
                          heroID: Object.hash(
                            'readLater',
                            comics[index].id,
                            comics[index].type,
                          ),
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class ReadLaterPage extends StatelessWidget {
  const ReadLaterPage({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = LocalFavoritesManager();
    return Scaffold(
      body: ListenableBuilder(
        listenable: Listenable.merge([manager, appdata.settings]),
        builder: (context, _) {
          final comics = manager.getReadLaterComics();
          return CustomScrollView(
            slivers: [
              SliverAppbar(title: Text('Read later'.tl)),
              if (comics.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Save comics here with Read later on the details page.'
                            .tl,
                      ),
                    ),
                  ),
                )
              else
                SliverGridComics(
                  comics: comics,
                  useFavoriteDisplaySettings: true,
                  menuBuilder: (comic) => [
                    MenuEntry(
                      text: 'Remove from read later'.tl,
                      icon: Icons.bookmark_remove_outlined,
                      onClick: () async {
                        try {
                          await manager.setReadLater(
                            comic as FavoriteItem,
                            included: false,
                            folderName: 'Read later'.tl,
                          );
                        } catch (error) {
                          if (context.mounted) {
                            context.showMessage(message: error.toString());
                          }
                        }
                      },
                    ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}
