import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/features/follow_updates/follow_updates.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/favorites/favorites.dart';

import 'bootstrap_core.dart';
import 'data_sync.dart';
import 'headless_arguments.dart';
import 'headless_bindings.dart';
import 'headless_source_update_command.dart';
import 'headless_sync_command.dart';
import 'headless_output.dart';

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
  try {
    await createCoreBootstrap(onDataChanged: sync.onDataChanged).start();
  } catch (error, stack) {
    sync.dispose();
    configureComicSourceDataSavedHandler(null);
    Log.error('Headless startup', error, stack);
    cliPrint({
      'status': 'error',
      'message': 'Core initialization failed: $error',
    });
    exit(1);
  }

  var commandExitCode = 0;
  try {
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
        commandExitCode = await runHeadlessSourceUpdateCommand(
          checkUpdates: _checkSourceUpdatesForCli,
          emit: cliPrint,
        );
        break;
      case HeadlessCommand.updateSubscribe:
        cliPrint({
          'status': 'running',
          'message': 'Updating subscribed comics...',
        });
        var folder = appdata.settings["followUpdatesFolder"];
        if (folder == null) {
          cliPrint({
            'status': 'error',
            'message': 'Follow updates folder is not configured.',
          });
          commandExitCode = 1;
          break;
        }

        final selected = request.comic;
        if (selected != null) {
          var comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
          var comic = comics
              .where(
                (c) =>
                    c.id == selected.id &&
                    c.type.sourceKey == selected.sourceKey,
              )
              .firstOrNull;
          if (comic == null) {
            cliPrint({
              'status': 'error',
              'message': 'Subscribed comic not found.',
            });
            commandExitCode = 1;
            break;
          }

          var result = await updateComic(comic, folder);

          Map<String, dynamic> data = {
            'current': 1,
            'total': 1,
            'comic': {
              'id': comic.id,
              'name': comic.name,
              'coverUrl': comic.coverPath,
              'author': comic.author,
              'type': comic.type.sourceKey,
              'updateTime': comic.updateTime,
              'tags': comic.tags,
            },
          };

          var message = 'Progress';
          if (result.errorMessage != null) {
            message = 'ProgressError';
            data['error'] = result.errorMessage;
          }

          cliPrint({'status': 'running', 'message': message, 'data': data});

          cliPrint({
            'status': 'running',
            'message': 'Update check complete.',
            'data': {
              'total': 1,
              'updated': result.updated ? 1 : 0,
              'errors': result.errorMessage != null ? 1 : 0,
            },
          });

          await Future.delayed(const Duration(milliseconds: 500));
          var json = await getUpdatedComicsAsJson(folder);
          commandExitCode = result.errorMessage != null ? 1 : 0;
          cliPrint({
            'status': result.errorMessage != null ? 'error' : 'success',
            'message': 'Updated comics list.',
            'data': jsonDecode(json),
          });
        } else {
          int total = 0;
          int updated = 0;
          int errors = 0;
          await for (var progress in updateFolder(folder, true)) {
            total = progress.total;
            updated = progress.updated;
            errors = progress.errors;
            Map<String, dynamic> data = {
              'current': progress.current,
              'total': progress.total,
            };
            if (progress.comic != null) {
              data['comic'] = {
                'id': progress.comic!.id,
                'name': progress.comic!.name,
                'coverUrl': progress.comic!.coverPath,
                'author': progress.comic!.author,
                'type': progress.comic!.type.sourceKey,
                'updateTime': progress.comic!.updateTime,
                'tags': progress.comic!.tags,
              };
            }
            var message = 'Progress';
            if (progress.errorMessage != null) {
              message = 'ProgressError';
              data['error'] = progress.errorMessage;
            }
            cliPrint({'status': 'running', 'message': message, 'data': data});
          }
          cliPrint({
            'status': 'running',
            'message': 'Update check complete.',
            'data': {'total': total, 'updated': updated, 'errors': errors},
          });
          await Future.delayed(const Duration(milliseconds: 500));
          var json = await getUpdatedComicsAsJson(folder);
          commandExitCode = errors > 0 ? 1 : 0;
          cliPrint({
            'status': errors > 0 ? 'error' : 'success',
            'message': 'Updated comics list.',
            'data': jsonDecode(json),
          });
        }
        break;
    }
  } catch (error, stack) {
    Log.error('Headless command', error, stack);
    cliPrint({'status': 'error', 'message': 'Command failed: $error'});
    commandExitCode = 1;
  } finally {
    sync.dispose();
    configureComicSourceDataSavedHandler(null);
  }

  // Exit after command execution
  exit(commandExitCode);
}

Future<HeadlessSourceUpdateCheck> _checkSourceUpdatesForCli() async {
  final service = SourceUpdateService.instance;
  await service.checkUpdates();
  final keys = List<String>.of(ComicSourceManager().availableUpdates.keys);
  return HeadlessSourceUpdateCheck(
    failures: service.lastUpdateCheck?.failures ?? const [],
    updates: keys.map((key) {
      final source = ComicSource.find(key);
      return HeadlessSourceUpdate(
        key: key,
        name: source?.name ?? key,
        version: source?.version ?? '',
        url: source?.url ?? '',
        update: () async {
          if (source == null) {
            throw StateError('Comic source no longer exists: $key');
          }
          await service.update(source);
        },
      );
    }).toList(),
  );
}
