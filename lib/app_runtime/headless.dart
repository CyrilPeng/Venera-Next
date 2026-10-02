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
import 'headless_bindings.dart';
import 'headless_sync_command.dart';
import 'headless_output.dart';

Future<void> runHeadlessMode(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.contains('--ignore-disheadless-log')) {
    Log.isMuted = true;
  }
  if (Platform.isLinux || Platform.isMacOS) {
    Directory.current = Platform.environment['HOME']!;
  }
  // The first arg is '--headless', so we look at the next ones.
  var commandIndex = args.indexOf('--headless') + 1;
  if (commandIndex >= args.length) {
    cliPrint({
      'status': 'error',
      'message': 'No command provided for headless mode.',
    });
    exit(1);
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

  var command = args[commandIndex];
  var subCommand = (commandIndex + 1 < args.length)
      ? args[commandIndex + 1]
      : null;

  var commandExitCode = 0;
  switch (command) {
    case 'webdav':
      commandExitCode = await runHeadlessSyncCommand(
        subCommand,
        isConfigured: sync.hasConfiguration,
        upload: sync.uploadData,
        download: sync.downloadData,
        emit: cliPrint,
      );
      break;
    case 'updatescript':
      if (subCommand == 'all') {
        cliPrint({
          'status': 'running',
          'message': 'Checking for comic source script updates...',
        });
        await SourceUpdateService.instance.checkUpdates();
        var updates = ComicSourceManager().availableUpdates;
        if (updates.isEmpty) {
          cliPrint({'status': 'success', 'message': 'No updates found.'});
        } else {
          var total = updates.length;
          var current = 0;
          var errors = 0;
          var updated = 0;
          cliPrint({
            'status': 'running',
            'message': 'Updating all comic source scripts...',
            'data': {'total': total, 'current': 0, 'updated': 0, 'errors': 0},
          });
          for (var key in updates.keys) {
            var source = ComicSource.find(key);
            if (source != null) {
              current++;
              var data = {
                'current': current,
                'total': total,
                'source': {
                  'key': source.key,
                  'name': source.name,
                  'version': source.version,
                  'url': source.url,
                },
              };
              try {
                await SourceUpdateService.instance.update(source);
                updated++;
                cliPrint({
                  'status': 'running',
                  'message': 'Progress',
                  'data': data,
                });
              } catch (e) {
                errors++;
                cliPrint({
                  'status': 'running',
                  'message': 'ProgressError',
                  'data': {...data, 'error': e.toString()},
                });
              }
            }
          }
          cliPrint({
            'status': 'success',
            'message': 'All scripts updated.',
            'data': {'total': total, 'updated': updated, 'errors': errors},
          });
        }
      } else {
        cliPrint({
          'status': 'error',
          'message': 'Invalid updatescript command. Use "all".',
        });
        exit(1);
      }
      break;
    case 'updatesubscribe':
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
        exit(1);
      }

      var updateIndex = args.indexOf('--update-comic-by-id-type');
      if (updateIndex != -1) {
        var id = args[updateIndex + 1];
        var type = args[updateIndex + 2];
        var comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
        var comic = comics.firstWhere(
          (c) => c.id == id && c.type.sourceKey == type,
        );

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
        cliPrint({
          'status': errors > 0 ? 'error' : 'success',
          'message': 'Updated comics list.',
          'data': jsonDecode(json),
        });
      }
      break;
    default:
      cliPrint({'status': 'error', 'message': 'Unknown command: $command'});
      exit(1);
  }

  sync.dispose();
  configureComicSourceDataSavedHandler(null);

  // Exit after command execution
  exit(commandExitCode);
}
