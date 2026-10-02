import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/follow_updates/follow_updates.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/log.dart';

FollowUpdatesRuntime createFollowUpdatesRuntime(DataSyncController sync) =>
    FollowUpdatesRuntime(
      folder: () => appdata.settings['followUpdatesFolder'] as String?,
      isChecking: () => FollowUpdateJob.isChecking,
      waitForDownload: sync.waitForDownload,
      createTask: (folder) => FollowUpdateJob(folder, false),
      onError: (error, stack) => Log.error('Check Updates', error, stack),
      observeChanges: (changed) {
        sync.addListener(changed);
        registerFollowUpdatesChangeListener(changed);
        return () {
          registerFollowUpdatesChangeListener(null);
          sync.removeListener(changed);
        };
      },
    );
