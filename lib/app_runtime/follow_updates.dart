import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/follow_updates/follow_updates_api.dart';
import 'package:venera_next/features/follow_updates/follow_updates_manager.dart';
import 'package:venera_next/features/sync/data_sync_controller.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/log.dart';

/// Freeze foreground jobs and the mounted background scheduler together.
/// Join both attempts before releasing either owner after preparation failure.
Future<void Function()> prepareApplicationFollowUpdatesForExit(
  FollowUpdatesRuntime runtime,
) async {
  void Function()? releaseRuntime;
  void Function()? releaseJobs;
  var released = false;
  void release() {
    if (released) return;
    released = true;
    try {
      // Restarted background checks must see an accepting foreground gate.
      releaseJobs?.call();
    } finally {
      releaseRuntime?.call();
    }
  }

  try {
    await Future.wait<void>([
      Future<void>.sync(() async {
        releaseRuntime = await runtime.prepareForExit();
      }),
      Future<void>.sync(() async {
        releaseJobs = await FollowUpdateJob.prepareForExit();
      }),
    ]);
    return release;
  } catch (_) {
    release();
    rethrow;
  }
}

FollowUpdatesRuntime createFollowUpdatesRuntime(DataSyncController sync) =>
    FollowUpdatesRuntime(
      folder: () => GlobalPreferenceStore(
        appdata.settings,
      ).read(FavoritePreferences.followUpdatesFolder),
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
