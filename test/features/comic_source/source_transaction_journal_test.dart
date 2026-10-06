import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/comic_source/source_mutation_failure.dart';
import 'package:venera_next/features/comic_source/source_transaction_journal.dart';

void main() {
  late Directory root;
  late File script;
  late File data;
  SourceTransactionJournal? owner;
  final oldScript = utf8.encode('old script');
  final newScript = utf8.encode('new script');
  final delta = <String, dynamic>{
    'fields': {
      'searchSources': {
        'before': ['old'],
        'after': ['new'],
      },
    },
    'origin': {
      'key': 'one',
      'before': {'one': 'old'},
      'after': {'one': 'new'},
    },
  };
  String document({
    bool after = false,
    String theme = 'dark',
    bool otherOrigin = false,
  }) => jsonEncode({
    'settings': {
      'searchSources': [after ? 'new' : 'old'],
      'theme': theme,
      'comicSourceOrigins': {
        'one': after ? 'new' : 'old',
        if (otherOrigin) 'other': 'later',
      },
    },
    'searchHistory': ['keep'],
  });
  setUp(() {
    root = Directory.systemTemp.createTempSync('source-transaction-');
    Directory('${root.path}/comic_source').createSync();
    script = File('${root.path}/comic_source/one.js')
      ..writeAsBytesSync(oldScript);
    data = File('${root.path}/comic_source/one.data')
      ..writeAsStringSync('{"token":"old"}');
  });
  tearDown(() async {
    await owner?.close();
    owner = null;
    await root.delete(recursive: true);
  });
  Future<SourceTransactionJournal> begin() async =>
      owner = await SourceTransactionJournal.begin(
        dataPath: root.path,
        script: script,
        before: oldScript,
        after: newScript,
      );
  Future<void> recover() async {
    await owner?.close();
    owner = null;
    await SourceTransactionJournal.recover(root.path);
  }

  void changeSettings(SourceTransactionJournal journal) {
    final primary = File('${root.path}/appdata.json')
      ..writeAsStringSync(document());
    final sync = File('${root.path}/syncdata.json')
      ..writeAsStringSync(document());
    journal.bindKey('one');
    journal.recordSettings({
      'appdata.json': document(after: true),
      'syncdata.json': document(after: true),
    }, delta);
    primary.copySync('${primary.path}.bak');
    sync.copySync('${sync.path}.bak');
    primary.writeAsStringSync(document(after: true));
    sync.writeAsStringSync(document(after: true));
  }

  Map<String, dynamic> settings(String name) =>
      (jsonDecode(File('${root.path}/$name').readAsStringSync())
              as Map<String, dynamic>)['settings']
          as Map<String, dynamic>;

  test(
    'uncommitted script and both configuration files recover together',
    () async {
      final journal = await begin();
      await script.writeAsBytes(newScript);
      changeSettings(journal);
      await recover();
      expect(await script.readAsBytes(), oldScript);
      for (final path in ['appdata.json', 'syncdata.json']) {
        expect(settings(path)['searchSources'], ['old']);
        expect(settings(path)['comicSourceOrigins'], {'one': 'old'});
        expect(File('${root.path}/$path.bak').existsSync(), isFalse);
      }
      await SourceTransactionJournal.recover(root.path);
    },
  );

  test(
    'configuration rollback preserves later unrelated edits and origins',
    () async {
      final journal = await begin();
      await script.writeAsBytes(newScript);
      changeSettings(journal);
      await File(
        '${root.path}/appdata.json',
      ).writeAsString(document(after: true, theme: 'light', otherOrigin: true));
      await recover();
      expect(settings('appdata.json')['theme'], 'light');
      expect(settings('appdata.json')['comicSourceOrigins'], {
        'one': 'old',
        'other': 'later',
      });
      expect(settings('appdata.json')['searchSources'], ['old']);
    },
  );

  test('applying resumes the latest registered data snapshot', () async {
    final journal = await begin();
    changeSettings(journal);
    await script.writeAsBytes(newScript);
    journal.recordData(root.path, 'one', '{"token":"first"}');
    await data.writeAsString('{"token":"first"}');
    journal.recordData(root.path, 'one', '{"token":"second"}');
    await recover();
    expect(await script.readAsBytes(), newScript);
    expect(await data.readAsString(), '{"token":"second"}');
    expect(settings('appdata.json')['searchSources'], ['new']);
  });

  test(
    'explicit abort restores an earlier applied intermediate data value',
    () async {
      final journal = await begin();
      changeSettings(journal);
      await script.writeAsBytes(newScript);
      journal.recordData(root.path, 'one', '{"token":"first"}');
      await data.writeAsString('{"token":"first"}');
      journal.recordData(root.path, 'one', '{"token":"second"}');
      journal.decideRollback();
      await recover();
      expect(await script.readAsBytes(), oldScript);
      expect(await data.readAsString(), '{"token":"old"}');
      expect(settings('syncdata.json')['searchSources'], ['old']);
    },
  );

  test('committed cleanup never rewrites later live files', () async {
    final journal = await begin();
    changeSettings(journal);
    journal.recordData(root.path, 'one', '{"token":"new"}');
    journal.commit();
    await script.writeAsString('later script');
    await data.writeAsString('{"token":"later"}');
    await File(
      '${root.path}/appdata.json',
    ).writeAsString(document(theme: 'later'));
    await recover();
    expect(await script.readAsString(), 'later script');
    expect(await data.readAsString(), '{"token":"later"}');
    expect(settings('appdata.json')['theme'], 'later');
  });

  test(
    'conflict does not prevent independent rollback and remains retryable',
    () async {
      final journal = await begin();
      changeSettings(journal);
      await script.writeAsBytes(newScript);
      final newer = jsonDecode(document(after: true)) as Map<String, dynamic>;
      (newer['settings'] as Map)['searchSources'] = ['external'];
      await File('${root.path}/appdata.json').writeAsString(jsonEncode(newer));
      await expectLater(recover(), throwsA(isA<SourceMutationFailure>()));
      expect(await script.readAsBytes(), oldScript);
      expect(settings('appdata.json')['searchSources'], ['external']);
      expect(settings('appdata.json')['comicSourceOrigins'], {'one': 'old'});
      expect(settings('syncdata.json')['searchSources'], ['old']);
      await File('${root.path}/appdata.json').writeAsString(document());
      await SourceTransactionJournal.recover(root.path);
    },
  );

  test('partial settings backup and temporary contents recover', () async {
    final journal = await begin();
    final primary = File('${root.path}/appdata.json')
      ..writeAsStringSync(document());
    final backup = File('${primary.path}.bak')
      ..writeAsStringSync('older backup');
    final temporary = File('${primary.path}.tmp')
      ..writeAsStringSync('preexisting staging');
    journal.recordSettings({'appdata.json': document(after: true)}, delta);
    backup.writeAsStringSync(document().substring(0, 10));
    temporary.writeAsStringSync(document(after: true).substring(0, 10));
    await recover();
    expect(backup.readAsStringSync(), 'older backup');
    expect(temporary.readAsStringSync(), 'preexisting staging');
    expect(primary.readAsStringSync(), document());
  });

  test(
    'unknown transaction siblings are retained after restoring effects',
    () async {
      final journal = await begin();
      await script.writeAsBytes(newScript);
      final other = File('${journal.directory.path}/user-note')
        ..writeAsStringSync('keep');
      await expectLater(recover(), throwsA(isA<SourceMutationFailure>()));
      expect(await script.readAsBytes(), oldScript);
      expect(other.readAsStringSync(), 'keep');
      await script.writeAsString('later');
      await other.delete();
      await SourceTransactionJournal.recover(root.path);
      expect(await script.readAsString(), 'later');
    },
  );

  test('live owner prevents another opener and recovery', () async {
    await begin();
    await expectLater(
      SourceTransactionJournal.recover(root.path),
      throwsStateError,
    );
    await expectLater(
      SourceTransactionJournal.begin(
        dataPath: root.path,
        script: script,
        before: oldScript,
        after: newScript,
      ),
      throwsStateError,
    );
    await recover();
  });

  for (final explicitNull in [false, true]) {
    test('rollback preserves field presence: null=$explicitNull', () async {
      final journal = await begin();
      final primary = File('${root.path}/appdata.json');
      final previous = {
        'settings': {
          'theme': 'dark',
          if (explicitNull) 'searchSources': null,
          if (explicitNull) 'comicSourceOrigins': null,
        },
      };
      primary.writeAsStringSync(jsonEncode(previous));
      journal.recordSettings({'appdata.json': document(after: true)}, delta);
      primary.writeAsStringSync(
        document(after: true, theme: 'later', otherOrigin: true),
      );
      await recover();
      final restored = settings('appdata.json');
      expect(restored.containsKey('searchSources'), explicitNull);
      expect(restored['searchSources'], isNull);
      expect(restored['comicSourceOrigins'], {'other': 'later'});
      expect(restored['theme'], 'later');
    });
  }

  test('rollback removes an exclusively created configuration file', () async {
    final journal = await begin();
    journal.recordSettings({'appdata.json': document(after: true)}, delta);
    final primary = File('${root.path}/appdata.json')
      ..writeAsStringSync(document(after: true));
    await recover();
    expect(primary.existsSync(), isFalse);
  });

  test(
    'sync filtering and different backup values use their own snapshots',
    () async {
      final journal = await begin();
      final primary = File('${root.path}/appdata.json')
        ..writeAsStringSync(document());
      final backup = File('${primary.path}.bak')
        ..writeAsStringSync(document(theme: 'older'));
      final filtered = jsonEncode({
        'settings': {'theme': 'dark'},
      });
      final sync = File('${root.path}/syncdata.json')
        ..writeAsStringSync(filtered);
      journal.recordSettings({
        'appdata.json': document(after: true),
        'syncdata.json': filtered,
      }, delta);
      primary.copySync(backup.path);
      primary.writeAsStringSync(document(after: true));
      sync.writeAsStringSync(
        jsonEncode({
          'settings': {'theme': 'later'},
        }),
      );
      await recover();
      expect(backup.readAsStringSync(), document(theme: 'older'));
      expect(settings('syncdata.json'), {'theme': 'later'});
    },
  );

  test(
    'forward recovery preserves unrelated edits and rejects newer data',
    () async {
      final journal = await begin();
      changeSettings(journal);
      journal.recordData(root.path, 'one', '{"token":"new"}');
      File(
        '${root.path}/appdata.json',
      ).writeAsStringSync(document(theme: 'later', otherOrigin: true));
      data.writeAsStringSync('{"token":"external"}');
      await expectLater(recover(), throwsA(isA<SourceMutationFailure>()));
      expect(settings('appdata.json')['theme'], 'later');
      expect(settings('appdata.json')['searchSources'], ['new']);
      expect(settings('appdata.json')['comicSourceOrigins'], {
        'one': 'new',
        'other': 'later',
      });
      expect(data.readAsStringSync(), '{"token":"external"}');
      data.writeAsStringSync('{"token":"old"}');
      await SourceTransactionJournal.recover(root.path);
      expect(data.readAsStringSync(), '{"token":"new"}');
    },
  );

  test('unknown origin scalar is preserved as a conflict', () async {
    final journal = await begin();
    changeSettings(journal);
    final document = settings('appdata.json')
      ..['comicSourceOrigins'] = 'external';
    File(
      '${root.path}/appdata.json',
    ).writeAsStringSync(jsonEncode({'settings': document}));
    await expectLater(recover(), throwsA(isA<SourceMutationFailure>()));
    expect(settings('appdata.json')['comicSourceOrigins'], 'external');
    expect(settings('appdata.json')['searchSources'], ['old']);
  });

  test(
    'transfer refuses pending effects and only cleans committed evidence',
    () async {
      final journal = await begin();
      await journal.writeScript();
      await journal.close();
      owner = null;
      await expectLater(
        SourceTransactionJournal.checkReadyForTransfer(root.path),
        throwsStateError,
      );
      expect(await script.readAsBytes(), newScript);
      await SourceTransactionJournal.recover(root.path);
      final committed = await begin();
      committed.commit();
      final residue = committed.directory;
      await committed.close();
      owner = null;
      script.writeAsStringSync('later');
      await SourceTransactionJournal.checkReadyForTransfer(root.path);
      expect(residue.existsSync(), isFalse);
      expect(script.readAsStringSync(), 'later');
    },
  );

  test('new mutation is rejected while old recovery remains pending', () async {
    await begin();
    await owner!.close();
    owner = null;
    await expectLater(
      SourceTransactionJournal.begin(
        dataPath: root.path,
        script: script,
        before: oldScript,
        after: newScript,
      ),
      throwsStateError,
    );
    await SourceTransactionJournal.recover(root.path);
  });

  test('closed transaction cannot delete its former script', () async {
    final journal = owner = await SourceTransactionJournal.begin(
      dataPath: root.path,
      script: script,
      before: oldScript,
      after: null,
    );
    await journal.close();
    owner = null;
    await expectLater(journal.writeScript(), throwsStateError);
    await expectLater(journal.cleanup(), throwsStateError);
    expect(script.readAsBytesSync(), oldScript);
    await SourceTransactionJournal.recover(root.path);
  });

  test('corrupt record is retained without changing script bytes', () async {
    await begin();
    await script.writeAsBytes(newScript);
    await owner!.close();
    owner = null;
    final db = sqlite3.open(
      '${root.path}/.source-transactions/transactions.sqlite',
    );
    db.execute("UPDATE mutations SET digest = 'invalid'");
    db.dispose();
    await expectLater(
      SourceTransactionJournal.recover(root.path),
      throwsA(isA<SourceMutationFailure>()),
    );
    expect(await script.readAsBytes(), newScript);
  });

  test('recovery rechecks the target after writing its staging file', () async {
    final journal = await begin();
    await journal.writeScript();
    await journal.close();
    owner = null;
    await expectLater(
      SourceTransactionJournal.recover(
        root.path,
        observer: (phase) {
          if (phase.startsWith('recovery-written:') &&
              phase.endsWith('one.js')) {
            script.writeAsStringSync('external edit during recovery');
          }
        },
      ),
      throwsA(isA<SourceMutationFailure>()),
    );
    expect(script.readAsStringSync(), 'external edit during recovery');
    script.writeAsBytesSync(newScript);
    await SourceTransactionJournal.recover(root.path);
    expect(script.readAsBytesSync(), oldScript);
  });

  test(
    'recovery resumes after interruption following an individual file',
    () async {
      final journal = await begin();
      changeSettings(journal);
      await script.writeAsBytes(newScript);
      await journal.close();
      owner = null;
      await expectLater(
        SourceTransactionJournal.recover(
          root.path,
          observer: (phase) {
            if (phase.startsWith('restored:')) {
              throw StateError('interrupted recovery');
            }
          },
        ),
        throwsA(isA<SourceMutationFailure>()),
      );
      await SourceTransactionJournal.recover(root.path);
      expect(await script.readAsBytes(), oldScript);
      expect(settings('appdata.json')['searchSources'], ['old']);
    },
  );
}
