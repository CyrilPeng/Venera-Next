import 'follow_updates_runtime.dart';
import 'follow_updates_scope.dart';

import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/comic_details/comic_details.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';
import 'package:venera_next/features/follow_updates/follow_updates_manager.dart';

class FollowUpdatesWidget extends StatefulWidget {
  const FollowUpdatesWidget({super.key});

  @override
  State<FollowUpdatesWidget> createState() => _FollowUpdatesWidgetState();
}

class _FollowUpdatesWidgetState extends State<FollowUpdatesWidget> {
  FollowUpdatesRuntime? _runtime;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final runtime = FollowUpdatesScope.of(context);
    if (identical(runtime, _runtime)) return;
    _runtime?.changes.removeListener(updateCount);
    _runtime = runtime;
    runtime.changes.addListener(updateCount);
    updatePreviewData();
  }

  int _count = 0;

  List<FavoriteItemWithUpdateInfo> previewComics = [];

  String? get folder => appdata.settings["followUpdatesFolder"];

  void updatePreviewData() {
    if (folder == null) {
      _count = 0;
      previewComics = [];
      return;
    }
    if (!LocalFavoritesManager().folderNames.contains(folder)) {
      _count = 0;
      previewComics = [];
      appdata.settings["followUpdatesFolder"] = null;
      LocalFavoritesManager().refreshUpdateIds();
      Future.microtask(() {
        appdata.saveData();
      });
    } else {
      _count = LocalFavoritesManager().countUpdates(folder!);
      previewComics = getFollowUpdatesPreviewComics(folder!);
    }
  }

  void updateCount() {
    setState(() {
      updatePreviewData();
    });
  }

  @override
  void dispose() {
    _runtime?.changes.removeListener(updateCount);
    super.dispose();
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
            context.to(() => FollowUpdatesPage());
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    Center(child: Text('Follow Updates'.tl, style: ts.s18)),
                    if (_count > 0)
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '@c updates'.tlParams({'c': _count}),
                          style: ts.s12,
                        ),
                      ),
                    const Spacer(),
                    const Icon(Icons.arrow_right),
                  ],
                ),
              ).paddingHorizontal(16),
              if (previewComics.isNotEmpty)
                SizedBox(
                  height: 136,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: previewComics.length,
                    itemBuilder: (context, index) {
                      final comic = previewComics[index];
                      final heroID = comic.id.hashCode;
                      return SimpleComicTile(
                        comic: comic,
                        heroID: heroID,
                        onTap: () {
                          context.to(
                            () => ComicPage(
                              id: comic.id,
                              sourceKey: comic.type.sourceKey,
                              cover: comic.cover,
                              title: comic.title,
                              heroID: heroID,
                            ),
                          );
                        },
                      ).paddingHorizontal(8).paddingVertical(2);
                    },
                  ),
                ).paddingHorizontal(8).paddingBottom(16),
            ],
          ),
        ),
      ),
    );
  }
}

class FollowUpdatesPage extends StatefulWidget {
  const FollowUpdatesPage({super.key});

  @override
  State<FollowUpdatesPage> createState() => _FollowUpdatesPageState();
}

class _FollowUpdatesPageState extends State<FollowUpdatesPage> {
  int _folderChange = 0;
  FollowUpdateJob? _folderJob;
  FollowUpdatesRuntime? _runtime;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final runtime = FollowUpdatesScope.of(context);
    if (identical(runtime, _runtime)) return;
    _runtime?.changes.removeListener(updateComics);
    _runtime = runtime;
    runtime.changes.addListener(updateComics);
    updateComics();
  }

  String? get folder => appdata.settings["followUpdatesFolder"];

  var updatedComics = <FavoriteItemWithUpdateInfo>[];
  var allComics = <FavoriteItemWithUpdateInfo>[];

  /// Sort comics by update time in descending order with nulls at the end.
  void sortComics() {
    allComics.sort((a, b) {
      if (a.updateTime == null && b.updateTime == null) {
        return 0;
      } else if (a.updateTime == null) {
        return -1;
      } else if (b.updateTime == null) {
        return 1;
      }
      try {
        var aNums = a.updateTime!.split('-').map(int.parse).toList();
        var bNums = b.updateTime!.split('-').map(int.parse).toList();
        for (int i = 0; i < aNums.length; i++) {
          if (aNums[i] != bNums[i]) {
            return bNums[i] - aNums[i];
          }
        }
        return 0;
      } catch (_) {
        return 0;
      }
    });
  }

  @override
  void dispose() {
    _runtime?.changes.removeListener(updateComics);
    _folderChange++;
    _folderJob?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(title: Text('Follow Updates'.tl)),
          if (folder == null)
            buildNotConfigured(context)
          else
            buildConfigured(context),
          SliverPadding(padding: const EdgeInsets.only(top: 8)),
          buildUpdatedComics(),
          buildAllComics(),
        ],
      ),
    );
  }

  Widget buildNotConfigured(BuildContext context) {
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: Icon(Icons.info_outline),
              title: Text("Not Configured".tl),
            ),
            Text(
              "Choose a folder to follow updates.".tl,
              style: ts.s16,
            ).paddingHorizontal(16),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: showSelector,
              child: Text("Choose Folder".tl),
            ).paddingHorizontal(16).toAlign(Alignment.centerRight),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget buildConfigured(BuildContext context) {
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(leading: Icon(Icons.stars_outlined), title: Text(folder!)),
            Text(
              "Automatic update checking enabled.".tl,
              style: ts.s14,
            ).paddingHorizontal(16),
            Text(
              "The app will check for updates at most once a day.".tl,
              style: ts.s14,
            ).paddingHorizontal(16),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: showSelector,
                  child: Text("Change Folder".tl),
                ),
                FilledButton.tonal(
                  onPressed: checkNow,
                  child: Text("Check Now".tl),
                ),
                const SizedBox(width: 16),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget buildUpdatedComics() {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.update),
                const SizedBox(width: 8),
                Text("Updates".tl, style: ts.s18),
                const Spacer(),
                if (updatedComics.isNotEmpty)
                  IconButton(
                    icon: Icon(Icons.clear_all),
                    onPressed: () {
                      final manager = LocalFavoritesManager();
                      final generation = manager.connectionGeneration;
                      final items = updatedComics.toList();
                      final runtime = _runtime;
                      showAsyncConfirmDialog(
                        context: App.rootContext,
                        title: "Mark all as read".tl,
                        content: "Do you want to mark all as read?".tl,
                        onConfirm: () async {
                          await AppDataOperations.instance.access(() async {
                            if (manager.connectionGeneration != generation) {
                              throw StateError(
                                'Favorites database changed. Try again.',
                              );
                            }
                            for (var comic in items) {
                              await manager.markAsRead(
                                comic.id,
                                comic.type,
                                notify: false,
                              );
                            }
                            manager.notifyChanges();
                            await appdata.saveData();
                          });
                          runtime?.notifyChanged();
                        },
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
        if (updatedComics.isNotEmpty)
          SliverToBoxAdapter(
            child: Text(
              "The comic will be marked as no updates as soon as you read it."
                  .tl,
            ).paddingHorizontal(16).paddingVertical(4),
          ),
        if (updatedComics.isNotEmpty)
          SliverGridComics(comics: updatedComics)
        else
          SliverToBoxAdapter(
            child: Row(
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [Text("No updates found".tl, style: ts.s16)],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget buildAllComics() {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.list),
                const SizedBox(width: 8),
                Text("All Comics".tl, style: ts.s18),
              ],
            ),
          ),
        ),
        SliverGridComics(comics: allComics),
      ],
    );
  }

  void showSelector() {
    var folders = LocalFavoritesManager().folderNames;
    if (folders.isEmpty) {
      context.showMessage(message: "No folders available".tl);
      return;
    }
    String? selectedFolder;
    showDialog(
      context: App.rootContext,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Choose Folder".tl,
              content: Column(
                children: [
                  ListTile(
                    title: Text("Folder".tl),
                    trailing: Select(
                      minWidth: 120,
                      current: selectedFolder,
                      values: folders,
                      onTap: (i) {
                        setState(() {
                          selectedFolder = folders[i];
                        });
                      },
                    ),
                  ),
                ],
              ),
              actions: [
                if (appdata.settings["followUpdatesFolder"] != null)
                  TextButton(
                    onPressed: () {
                      disable();
                      context.pop();
                    },
                    child: Text("Disable".tl),
                  ),
                FilledButton(
                  onPressed: selectedFolder == null
                      ? null
                      : () {
                          context.pop();
                          setFolder(selectedFolder!);
                        },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> disable() async {
    _folderChange++;
    _folderJob?.cancel();
    _runtime!.cancelChecking();
    FollowUpdateJob.cancelActive();
    final manager = LocalFavoritesManager();
    try {
      await manager.setFollowUpdatesFolder(
        null,
        generation: manager.connectionGeneration,
      );
      if (mounted) _runtime!.notifyChanged();
    } catch (error, stack) {
      Log.error('Follow updates folder', error, stack);
      if (mounted) context.showMessage(message: error.toString());
    }
  }

  Future<void> setFolder(String folder) async {
    final revision = ++_folderChange;
    _folderJob?.cancel();
    final manager = LocalFavoritesManager();
    final generation = manager.connectionGeneration;
    _runtime!.cancelChecking();
    bool active() => mounted && revision == _folderChange;
    try {
      await AppDataOperations.instance.access(() async {
        if (!active()) return;
        if (manager.connectionGeneration != generation) {
          throw StateError('Favorites database changed. Try again.');
        }
        await manager.prepareTableForFollowUpdates(folder);
      });
      if (!mounted || !active()) return;
      if (manager.count(folder) > 0) {
        final job = _folderJob = FollowUpdateJob(folder, true);
        final loading = showLoadingDialog(
          context,
          withProgress: true,
          cancelButtonText: 'Cancel'.tl,
          onCancel: job.cancel,
          message: 'Updating comics...'.tl,
        );
        try {
          await for (var progress in job.progress) {
            loading.setProgress(progress.fraction);
          }
        } finally {
          loading.close();
        }
        if (job.isCancelled || !active()) return;
      }
      if (!active()) return;
      await manager.setFollowUpdatesFolder(folder, generation: generation);
      if (active()) updateComics();
    } catch (error, stack) {
      Log.error('Follow updates folder', error, stack);
      if (mounted && active()) context.showMessage(message: error.toString());
    }
  }

  void checkNow() async {
    _runtime!.cancelChecking();

    final job = FollowUpdateJob(folder!, true);

    var loadingController = showLoadingDialog(
      App.rootContext,
      withProgress: true,
      cancelButtonText: "Cancel".tl,
      onCancel: job.cancel,
      message: "Updating comics...".tl,
    );

    int updated = 0;

    try {
      await for (var progress in job.progress) {
        loadingController.setProgress(progress.fraction);
        updated = progress.updated;
      }
    } catch (error) {
      if (mounted) context.showMessage(message: error.toString());
    } finally {
      loadingController.close();
    }
    if (updated > 0 && mounted) {
      _runtime!.notifyChanged();
    }
  }

  void updateComics() {
    if (folder == null) {
      setState(() {
        allComics = [];
        updatedComics = [];
      });
      return;
    }
    setState(() {
      allComics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder!);
      sortComics();
      updatedComics = allComics.where((c) => c.hasNewUpdate).toList();
    });
  }
}
