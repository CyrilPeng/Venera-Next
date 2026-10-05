// A separate Dart VM killed by the parent test at real journal checkpoints.
// Every filesystem mutation is confined to the test-owned root argument.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:venera_next/features/sync/app_data_import_journal.dart';

const _resources = <String>{
  'history.db',
  'local_favorite.db',
  'cookie.db',
  'comic_source',
  'appdata.json',
  'appdata.json.bak',
  'appdata.json.tmp',
  'syncdata.json',
  'syncdata.json.bak',
  'syncdata.json.tmp',
};

Future<void> main(List<String> args) async {
  final root = p.normalize(p.absolute(args[0]));
  final command = args[1];
  final crashAt = args.length > 2 ? args[2] : '';
  if (!['apply', 'recover', 'acknowledge'].contains(command)) {
    throw ArgumentError('Unknown import crash probe command');
  }

  void rendezvous(String phase, {String? resource, required String id}) {
    if (crashAt != phase && crashAt != '$phase:$resource') return;
    final marker = File(p.join(root, 'ready.tmp'));
    marker.writeAsStringSync(
      jsonEncode({'pid': pid, 'phase': phase, 'resource': resource, 'id': id}),
      flush: true,
    );
    marker.renameSync(p.join(root, 'ready.json'));
    // Block synchronously so no queued cleanup, finally, or later journal event
    // runs before the parent terminates this exact OS process.
    stdin.readLineSync();
    throw StateError('Crash probe resumed instead of being terminated');
  }

  final dataPath = p.join(root, 'data');
  final incomingPath = p.join(root, 'incoming');
  final journal = AppDataImportJournal.open(
    dataPath,
    observer: (event) =>
        rendezvous(event.phase, resource: event.resource, id: event.id),
  );
  try {
    if (command == 'apply') {
      final transaction = await journal.prepare(
        resources: _resources,
        syncOperationId: 'crash-probe-sync-operation',
      );
      for (final name in ['history.db', 'local_favorite.db', 'cookie.db']) {
        await transaction.replaceFile(name, File(p.join(incomingPath, name)));
      }
      await transaction.replaceDirectory(
        'comic_source',
        Directory(p.join(incomingPath, 'comic_source')),
      );
      for (final name in ['appdata.json', 'syncdata.json']) {
        for (final suffix in ['', '.bak', '.tmp']) {
          await transaction.markChanging('$name$suffix');
        }
        // Exercise the same primary/backup/temporary file boundaries used by
        // metadata persistence, without importing Flutter into the Dart VM.
        final primary = File(p.join(dataPath, name));
        final temporary = File('${primary.path}.tmp');
        await temporary.writeAsBytes(
          await File(p.join(incomingPath, name)).readAsBytes(),
          flush: true,
        );
        await primary.copy('${primary.path}.bak');
        await primary.delete();
        await temporary.rename(primary.path);
        rendezvous('metadataWritten', resource: name, id: transaction.id);
      }
      await transaction.markApplied(123456789);
      await transaction.cleanup();
    } else if (command == 'acknowledge') {
      await journal.acknowledge(crashAt);
    }
    final receipts = await journal.recoverPending();
    stdout.writeln(
      jsonEncode([
        for (final receipt in receipts)
          {
            'id': receipt.id,
            'syncOperationId': receipt.syncOperationId,
            'state': receipt.commitState.name,
            'committedAt': receipt.committedAt,
          },
      ]),
    );
  } finally {
    journal.close();
  }
}
