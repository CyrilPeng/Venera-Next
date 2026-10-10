import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/features/follow_updates/follow_updates_manager.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/favorites/favorites_api.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';

import 'bootstrap_core.dart';
import 'core_bootstrap.dart';
import 'data_sync.dart';
import 'headless_arguments.dart';
import 'headless_bindings.dart';
import 'headless_source_update_command.dart';
import 'headless_source_updates.dart';
import 'headless_sync_command.dart';
import 'headless_subscription_command.dart';
import 'headless_output.dart';
import 'headless_shutdown.dart';

Future<void> runHeadlessMode(List<String> args) async {
  final parsed = parseHeadlessArguments(args);
  if (parsed.error) {
    cliPrint({'status': 'error', 'message': parsed.errorMessage});
    exit(1);
  }
  final request = parsed.data;
  WidgetsFlutterBinding.ensureInitialized();
  if (args.contains('--ignore-disheadless-log')) {
    Log.isMuted = true;
  }
  if (Platform.isLinux || Platform.isMacOS) {
    Directory.current = Platform.environment['HOME']!;
  }
  // Need to initialize the app for some features to work
  configureHeadlessBindings();
  final sync = createApplicationDataSync();
  final core = createCoreBootstrap(onDataChanged: sync.onDataChanged);
  var initialized = false;
  var commandExitCode = 0;
  SourceUpdateService? sourceUpdates;
  try {
    await core.start();
    initialized = true;
    switch (request.command) {
      case HeadlessCommand.webdav:
        commandExitCode = await runHeadlessSyncCommand(
          request.subcommand,
          isConfigured: sync.hasConfiguration,
          upload: sync.uploadData,
          download: sync.downloadData,
          emit: cliPrint,
        );
        break;
      case HeadlessCommand.updateScript:
        final updates = sourceUpdates = SourceUpdateService(
          manager: ComicSourceManager.current,
        );
        commandExitCode = await runHeadlessSourceUpdateCommand(
          checkUpdates: () => checkSourceUpdatesForCli(updates),
          emit: cliPrint,
        );
        break;
      case HeadlessCommand.updateSubscribe:
        commandExitCode = await runHeadlessSubscriptionCommand(
          folder: GlobalPreferenceStore(
            appdata.settings,
          ).read(FavoritePreferences.followUpdatesFolder),
          selected: request.comic,
          updateSelected: _updateSelectedSubscription,
          updateAll: (folder) => updateFolder(folder, true).map(
            (progress) => HeadlessSubscriptionProgress(
              total: progress.total,
              current: progress.current,
              updated: progress.updated,
              errors: progress.errors,
              comic: progress.comic == null
                  ? null
                  : _subscriptionComicJson(progress.comic!),
              errorMessage: progress.errorMessage,
            ),
          ),
          readUpdatedComics: (folder) async =>
              jsonDecode(await getUpdatedComicsAsJson(folder)),
          emit: cliPrint,
          reportError: (error, stack) =>
              Log.error('Headless subscription', error, stack),
        );
        break;
    }
  } catch (error, stack) {
    commandExitCode = 1;
    Log.error(
      initialized ? 'Headless command' : 'Headless startup',
      error,
      stack,
    );
    cliPrint({
      'status': 'error',
      'message': initialized
          ? 'Command failed: $error'
          : 'Core initialization failed: $error',
    });
  } finally {
    final closed = await finishHeadlessRuntime(
      prepareCore: () async {
        final failures = <({String store, Object error, StackTrace stack})>[];
        for (final resource in <CoreStartupCleanup>[
          (name: 'source updates', close: () => sourceUpdates?.closeAndWait()),
          (name: 'core producers', close: core.prepareForClose),
        ]) {
          try {
            await resource.close();
          } catch (error, stack) {
            failures.add((store: resource.name, error: error, stack: stack));
          }
        }
        if (failures.isNotEmpty) throw CoreShutdownFailure(failures);
      },
      closeCore: core.close,
      disposeBindings: () {
        sync.dispose();
        configureComicSourceDataSavedHandler(null);
      },
      flushPersistence: () async {
        // Closing an unacquired service drains without persisting defaults.
        await sync.closeAndWait();
      },
      emit: cliPrint,
      reportError: (error, stack) =>
          Log.error('Headless shutdown', error, stack),
    );
    if (!closed) commandExitCode = 1;
  }

  // Exit after command execution
  exit(commandExitCode);
}

Future<HeadlessSubscriptionProgress?> _updateSelectedSubscription(
  String folder,
  HeadlessComicSelector selected,
) async {
  final comic = LocalFavoritesManager()
      .getComicsWithUpdatesInfo(folder)
      .where(
        (comic) =>
            comic.id == selected.id &&
            comic.type.sourceKey == selected.sourceKey,
      )
      .firstOrNull;
  if (comic == null) return null;
  final result = await updateComic(comic, folder);
  final error =
      result.errorMessage ??
      (result.cancelled ? 'Subscription update cancelled.' : null);
  return HeadlessSubscriptionProgress(
    total: 1,
    current: 1,
    updated: result.updated ? 1 : 0,
    errors: error != null ? 1 : 0,
    comic: _subscriptionComicJson(comic),
    errorMessage: error,
  );
}

Map<String, dynamic> _subscriptionComicJson(FavoriteItemWithUpdateInfo comic) =>
    {
      'id': comic.id,
      'name': comic.name,
      'coverUrl': comic.coverPath,
      'author': comic.author,
      'type': comic.type.sourceKey,
      'updateTime': comic.updateTime,
      'tags': comic.tags,
    };
