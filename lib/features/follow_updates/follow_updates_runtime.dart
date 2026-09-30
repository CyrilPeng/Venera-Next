import 'package:flutter/foundation.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/log.dart';
import 'follow_updates_manager.dart';
import 'follow_updates_service.dart';

final followUpdatesChanges = ValueNotifier<int>(0);
void notifyFollowUpdatesChanged() => followUpdatesChanges.value++;

final followUpdatesService = FollowUpdatesService(
  folder: () => appdata.settings['followUpdatesFolder'] as String?,
  isChecking: () => FollowUpdateJob.isChecking,
  waitForDownload: () => DataSync().waitForDownload(),
  createTask: (folder) => FollowUpdateJob(folder, false),
  onUpdated: notifyFollowUpdatesChanged,
  onError: (error, stack) => Log.error('Check Updates', error, stack),
);

void startFollowUpdates() {
  if (followUpdatesService.isRunning) return;
  registerFollowUpdatesChangeListener(notifyFollowUpdatesChanged);
  DataSync().addListener(notifyFollowUpdatesChanged);
  followUpdatesService.start();
}

void stopFollowUpdates() {
  if (!followUpdatesService.isRunning) return;
  followUpdatesService.stop();
  registerFollowUpdatesChangeListener(null);
  DataSync().removeListener(notifyFollowUpdatesChanged);
}
