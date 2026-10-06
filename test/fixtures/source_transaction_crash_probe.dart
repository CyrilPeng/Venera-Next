// The parent owns args[0] and terminates this exact VM. No finally cleanup runs.
import 'dart:convert';
import 'dart:io';
import 'package:venera_next/features/comic_source/source_transaction_journal.dart';
import 'package:venera_next/features/comic_source/source_data_storage.dart';

void main(List<String> args) async {
  final root = args[0];
  final kind = args[1];
  final phase = args[2];
  void rendezvous() {
    final marker = File('$root/ready.tmp');
    marker.writeAsStringSync(
      jsonEncode({'pid': pid, 'phase': phase}),
      flush: true,
    );
    marker.renameSync('$root/ready.json');
    stdin.readLineSync();
    throw StateError('Probe resumed instead of being terminated');
  }

  if (phase.startsWith('recover-')) {
    await SourceTransactionJournal.recover(
      root,
      observer: (event) {
        if ((phase == 'recover-written' &&
                event.startsWith('recovery-written:')) ||
            (phase == 'recover-cleanup' && event == 'cleanup-files')) {
          rendezvous();
        }
      },
    );
    throw StateError('Recovery did not reach its interruption boundary');
  }
  final journal = await SourceTransactionJournal.begin(
    dataPath: root,
    script: File('$root/comic_source/one.js'),
    before: kind == 'install' ? null : utf8.encode('old script'),
    after: kind == 'uninstall' ? null : utf8.encode('new script'),
    observer: (event) {
      if (phase == 'recorded' && event == 'recorded') rendezvous();
    },
  );
  journal.bindKey('one');
  if (kind != 'uninstall') {
    await journal.writeScript();
    if (phase == 'script') rendezvous();
  }
  final after = jsonEncode({
    'settings': {
      'searchSources': kind == 'uninstall' ? [] : ['new'],
      'comicSourceOrigins': kind == 'uninstall' ? {} : {'one': 'new'},
      'theme': 'dark',
    },
    'searchHistory': ['keep'],
  });
  journal.recordSettings(
    {'appdata.json': after, 'syncdata.json': after},
    {
      'fields': {
        'searchSources': {
          'before': ['old'],
          'after': kind == 'uninstall' ? [] : ['new'],
        },
      },
      'origin': {
        'key': 'one',
        'before': {'one': 'old'},
        'after': kind == 'uninstall' ? {} : {'one': 'new'},
      },
    },
  );
  if (phase == 'settingsIntent') rendezvous();
  for (final name in ['appdata.json', 'syncdata.json']) {
    final primary = File('$root/$name');
    final temporary = File('${primary.path}.tmp');
    if (phase == 'settingsPartial' && name == 'appdata.json') {
      await temporary.writeAsString(after.substring(0, 12), flush: true);
      rendezvous();
    }
    await temporary.writeAsString(after, flush: true);
    await primary.copy('${primary.path}.bak');
    await temporary.rename(primary.path);
  }
  if (phase == 'settings') rendezvous();
  if (kind == 'uninstall') {
    await journal.writeScript();
  } else {
    journal.recordData(root, 'one', '{"token":"first"}');
    if (phase == 'dataIntent') rendezvous();
    await const SourceDataStorage().write(root, 'one', '{"token":"first"}');
    if (phase == 'dataApplied') rendezvous();
    journal.recordData(root, 'one', '{"token":"second"}');
    if (phase == 'laterDataIntent') rendezvous();
    await const SourceDataStorage().write(root, 'one', '{"token":"second"}');
  }
  journal.commit();
  if (phase == 'committed') rendezvous();
  await journal.cleanup();
  await journal.close();
  throw ArgumentError('Unknown interruption boundary');
}
