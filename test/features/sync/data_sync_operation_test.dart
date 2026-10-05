import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/features/sync/data_sync_operation.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';

void main() {
  test(
    'legacy version stays legacy while new operations carry recovery version three',
    () {
      final operation = _operation();
      expect(operation.version, 3);
      final legacy = operation.toJson()
        ..['version'] = 1
        ..remove('configurationChange')
        ..remove('previousConfiguration');
      final restored = DataSyncOperation.fromJson(legacy);
      expect(restored.version, 1);
      expect(restored.configurationChange, isFalse);
      expect(restored.toJson(), legacy);
    },
  );

  test(
    'configuration operation round trips an exact detached rollback checkpoint',
    () {
      final settings = <String, Object?>{
        'webdav': ['old', 'user', 'password'],
        'disableSyncFields': 'old',
      };
      final implicit = <String, dynamic>{
        'webdavSyncMode': 'scheduled',
        'webdavSyncPending': true,
        'webdavSyncLastAttempt': 55,
      };
      final preferences = SyncPreferenceStore(
        readSetting: (key) => settings[key],
        writeSetting: (key, value) => settings[key] = value,
        implicitData: () => implicit,
      );
      final original = preferences.capture();
      final json = _operation().toJson()
        ..['configurationChange'] = true
        ..['previousConfiguration'] = original.toJson();
      final operation = DataSyncOperation.fromJson(
        jsonDecode(jsonEncode(json)),
      );
      preferences.applyDraft(['new', 'u', 'p'], 'new');
      implicit['webdavSyncLastAttempt'] = 99;
      preferences.restore(operation.previousConfiguration!);
      expect(preferences.capture().toJson(), original.toJson());
      expect(
        operation
            .copyWith(followUpComplete: true)
            .previousConfiguration!
            .toJson(),
        original.toJson(),
      );
      expect(
        () => DataSyncOperation.fromJson({
          ...json,
          'previousConfiguration': null,
        }),
        throwsFormatException,
      );
    },
  );

  for (final direction in DataSyncDirection.values) {
    for (final state in DataSyncCommitState.values) {
      test(
        'JSON round trip retains $direction and $state without inferring completion',
        () {
          final operation = _operation(direction: direction, state: state);
          final decoded = DataSyncOperation.fromJson(
            jsonDecode(jsonEncode(operation.toJson())),
          );
          expect(decoded.toJson(), operation.toJson());
          expect(decoded.commitState, state);
          expect(decoded.followUpComplete, isFalse);
          expect(decoded.generation, 8);
        },
      );
    }
  }

  test(
    'operation owns its connection across construction, decode and serialization',
    () {
      final connection = ['https://example.test/dav', 'reader', 'secret'];
      final operation = _operation(connection: connection);
      connection[0] = 'https://different.test';
      expect(operation.connection.first, 'https://example.test/dav');
      expect(() => operation.connection[0] = 'changed', throwsUnsupportedError);
      final json = operation.toJson();
      (json['connection']! as List<String>)[1] = 'changed user';
      expect(operation.connection[1], 'reader');
      final input = operation.toJson();
      final restored = DataSyncOperation.fromJson(input);
      (input['connection']! as List<String>)[2] = 'changed password';
      expect(restored.connection[2], 'secret');
    },
  );

  test(
    'copyWith updates follow-up state while retaining operation and draft identity',
    () {
      final operation = _operation();
      final updated = operation.copyWith(
        commitState: DataSyncCommitState.applied,
        followUpComplete: true,
        recoveryPath: 'recovery/new',
      );
      expect(updated.toJson(), {
        ...operation.toJson(),
        'commitState': 'applied',
        'followUpComplete': true,
        'recoveryPath': 'recovery/new',
      });
      expect(operation.commitState, DataSyncCommitState.notApplied);
      expect(operation.followUpComplete, isFalse);
      expect(updated.copyWith().toJson(), updated.toJson());
      expect(
        updated.copyWith(followUpComplete: false).followUpComplete,
        isFalse,
      );
    },
  );

  test('missing required fields are corrupt records, including null input', () {
    final valid = _operation().toJson();
    for (final key in valid.keys.where(
      (key) => key != 'recoveryPath' && key != 'previousConfiguration',
    )) {
      final missing = Map<String, Object?>.of(valid)..remove(key);
      expect(
        () => DataSyncOperation.fromJson(missing),
        throwsFormatException,
        reason: key,
      );
    }
    for (final value in [
      null,
      true,
      1,
      'operation',
      [],
      {1: 'not a JSON key'},
    ]) {
      expect(() => DataSyncOperation.fromJson(value), throwsFormatException);
    }
  });

  test(
    'unsupported versions and malformed field types never become defaults',
    () {
      final invalid = <String, List<Object?>>{
        'version': [null, 0, 4, 1.0, '1', true],
        'configurationChange': [null, 0, 'false'],
        'id': [null, 4, '', '  '],
        'direction': [null, 0, 'both', 'UPLOAD'],
        'connection': [
          null,
          '',
          ['url'],
          ['url', 'user', 3],
          ['url', 'user', 'pass', 'extra'],
        ],
        'excludedFields': [null, false, []],
        'mode': [null, 0, 'automatic', ''],
        'intervalMinutes': [null, 0, -1, 30.0, '30'],
        'pendingBefore': [null, 0, 'false'],
        'generation': [null, -1, 8.0, '8'],
        'commitState': [null, false, 'committed', ''],
        'followUpComplete': [null, 1, 'true'],
        'recoveryPath': [false, 1, []],
      };
      for (final field in invalid.entries) {
        for (final value in field.value) {
          final data = _operation().toJson()..[field.key] = value;
          expect(
            () => DataSyncOperation.fromJson(data),
            throwsFormatException,
            reason: '${field.key}=$value',
          );
        }
      }
    },
  );

  test(
    'optional recovery path and empty disabled configuration remain explicit',
    () {
      final json = _operation().toJson()
        ..remove('recoveryPath')
        ..['connection'] = <String>[]
        ..['mode'] = 'manual'
        ..['generation'] = 0
        ..['futureMetadata'] = {'ignored': true};
      final operation = DataSyncOperation.fromJson(json);
      expect(operation.recoveryPath, isNull);
      expect(operation.connection, isEmpty);
      expect(operation.mode, 'manual');
      expect(operation.generation, 0);
      expect(operation.followUpComplete, isFalse);
    },
  );

  test(
    'pending operation preserves raw corruption and follows replaced implicit storage',
    () {
      var implicit = <String, dynamic>{'unrelated': 7};
      final store = SyncPreferenceStore(
        readSetting: (_) => null,
        writeSetting: (_, _) {},
        implicitData: () => implicit,
      );
      expect(store.pendingOperation, isNull);
      final json = _operation().toJson();
      store.pendingOperation = json;
      expect(implicit['webdavSyncOperation'], same(json));
      expect(store.pendingOperation, same(json));
      store.pendingOperation = 'corrupt';
      expect(
        () => DataSyncOperation.fromJson(store.pendingOperation),
        throwsFormatException,
      );
      implicit = {'webdavSyncOperation': false, 'unrelated': 9};
      expect(store.pendingOperation, isFalse);
      store.pendingOperation = null;
      expect(implicit, {'unrelated': 9});
    },
  );

  test(
    'configuration rollback snapshots detach nested raw values and retain operation ownership',
    () {
      final originalConnection = <Object?>[
        'https://old.test',
        <String, Object?>{
          'legacy': <String>['old'],
        },
        'password',
      ];
      final originalExcluded = <String, Object?>{
        'legacy': <Object?>[
          <String, Object?>{'value': 'old'},
        ],
      };
      final settings = <String, Object?>{
        'webdav': originalConnection,
        'disableSyncFields': originalExcluded,
      };
      final implicit = <String, dynamic>{
        'webdavSyncMode': 'scheduled',
        'webdavSyncPending': true,
        'unknown': 7,
      };
      final store = SyncPreferenceStore(
        readSetting: (key) => settings[key],
        writeSetting: (key, value) => settings[key] = value,
        implicitData: () => implicit,
      );
      final expected = jsonDecode(jsonEncode(settings));
      final checkpoint = store.capture();
      originalConnection[0] = 'changed';
      ((originalConnection[1] as Map)['legacy'] as List)[0] = 'changed';
      ((originalExcluded['legacy'] as List)[0] as Map)['value'] = 'changed';
      store.applyDraft(['https://new.test', 'user', 'password'], 'new');
      final operation = _operation().toJson();
      store.pendingOperation = operation;
      store.restore(checkpoint);
      expect(settings, expected);
      expect(
        store.pendingOperation,
        same(operation),
        reason: 'a draft rollback cannot erase an operation receipt',
      );
      expect(implicit['unknown'], 7);
      // Reusing the checkpoint must not expose its own nested references either.
      ((settings['webdav'] as List)[1] as Map)['legacy'] = [
        'mutated after restore',
      ];
      store.restore(checkpoint);
      expect(settings, expected);
    },
  );
}

DataSyncOperation _operation({
  DataSyncDirection direction = DataSyncDirection.upload,
  DataSyncCommitState state = DataSyncCommitState.notApplied,
  List<String>? connection,
}) => DataSyncOperation(
  id: 'operation-123',
  direction: direction,
  connection: connection ?? ['https://example.test/dav', 'reader', 'secret'],
  excludedFields: 'language,readerMode',
  mode: 'scheduled',
  intervalMinutes: 30,
  pendingBefore: true,
  generation: 8,
  commitState: state,
  followUpComplete: false,
  recoveryPath: 'recovery/operation-123',
);
