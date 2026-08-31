import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/bangumi/bangumi.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  late FakeBangumiGateway gateway;
  late BangumiService service;
  var saveCount = 0;

  setUp(() {
    appdata.settings['bangumiAccessToken'] = '';
    appdata.settings['bangumiUsername'] = '';
    appdata.settings['bangumiAutoSyncEnabled'] = true;
    appdata.settings['bangumiBindings'] = <String, dynamic>{};
    gateway = FakeBangumiGateway();
    service = BangumiService.forTesting(
      gatewayFactory: (_) => gateway,
      saveSettings: () async => saveCount++,
    );
    saveCount = 0;
  });

  test('connect verifies then saves token and username', () async {
    gateway.user = const BangumiUser('alice', 'Alice');

    final user = await service.connect('  token  ');

    expect(user, const BangumiUser('alice', 'Alice'));
    expect(appdata.settings['bangumiAccessToken'], 'token');
    expect(appdata.settings['bangumiUsername'], 'alice');
    expect(gateway.currentUserCalls, 1);
    expect(saveCount, 1);
    expect(service.isConnected, isTrue);
  });

  test('failed connect does not replace an existing connection', () async {
    appdata.settings['bangumiAccessToken'] = 'old-token';
    appdata.settings['bangumiUsername'] = 'old-user';
    gateway.currentUserError = StateError('invalid token');

    await expectLater(service.connect('new-token'), throwsStateError);

    expect(appdata.settings['bangumiAccessToken'], 'old-token');
    expect(appdata.settings['bangumiUsername'], 'old-user');
    expect(saveCount, 0);
  });

  test('connect restores an existing connection when saving fails', () async {
    appdata.settings['bangumiAccessToken'] = 'old-token';
    appdata.settings['bangumiUsername'] = 'old-user';
    final savingService = BangumiService.forTesting(
      gatewayFactory: (_) => gateway,
      saveSettings: () async => throw StateError('save failed'),
    );

    await expectLater(savingService.connect('new-token'), throwsStateError);

    expect(appdata.settings['bangumiAccessToken'], 'old-token');
    expect(appdata.settings['bangumiUsername'], 'old-user');
  });

  test('disconnect clears connection but retains bindings', () async {
    appdata.settings['bangumiAccessToken'] = 'token';
    appdata.settings['bangumiUsername'] = 'alice';
    final key = bangumiBindingKey('source', 'comic');
    appdata.settings['bangumiBindings'] = {key: binding().toJson()};

    await service.disconnect();

    expect(appdata.settings['bangumiAccessToken'], '');
    expect(appdata.settings['bangumiUsername'], '');
    expect(service.bindingFor('source', 'comic'), isNotNull);
    expect(saveCount, 1);
  });

  test('disconnect restores the connection when saving fails', () async {
    appdata.settings['bangumiAccessToken'] = 'token';
    appdata.settings['bangumiUsername'] = 'alice';
    final savingService = BangumiService.forTesting(
      gatewayFactory: (_) => gateway,
      saveSettings: () async => throw StateError('save failed'),
    );

    await expectLater(savingService.disconnect(), throwsStateError);

    expect(appdata.settings['bangumiAccessToken'], 'token');
    expect(appdata.settings['bangumiUsername'], 'alice');
  });

  test(
    'search and subject lookup delegate through the current connection',
    () async {
      appdata.settings['bangumiAccessToken'] = 'token';
      appdata.settings['bangumiUsername'] = 'alice';
      gateway.searchResults = [subject()];
      gateway.subjects[42] = subject();

      final results = await service.searchSubjects('keyword');
      final result = await service.getSubject(42);

      expect(results, hasLength(1));
      expect(results.single.id, 42);
      expect(result.id, 42);
      expect(gateway.searchKeywords, ['keyword']);
      expect(gateway.subjectCalls, [42]);
    },
  );

  test('connect rejects an empty username without changing settings', () async {
    appdata.settings['bangumiAccessToken'] = 'old-token';
    appdata.settings['bangumiUsername'] = 'old-user';

    for (final username in ['', '   ']) {
      gateway.user = BangumiUser(username, 'Alice');

      await expectLater(service.connect('new-token'), throwsStateError);

      expect(appdata.settings['bangumiAccessToken'], 'old-token');
      expect(appdata.settings['bangumiUsername'], 'old-user');
      expect(saveCount, 0);
    }
  });

  test('bind patches only higher reliable episode progress', () async {
    connectSettings();
    gateway.collection = collection(epStatus: 10, rate: 7);

    final result = await service.bind(
      sourceKey: 'source',
      comicId: 'comic',
      subject: subject(),
      mode: BangumiProgressMode.episode,
      reliableLocalProgress: const BangumiProgress(
        BangumiProgressField.episode,
        12,
      ),
    );

    expect(gateway.patchFields, [
      {'ep_status': 12},
    ]);
    expect(result.lastRemoteEpisode, 12);
    expect(result.lastRemoteVolume, 3);
    expect(result.rating, 7);
    expect(result.collectionStatus, BangumiCollectionStatus.reading);
    expect(service.bindingFor('source', 'comic'), result);
  });

  test('bind rejects an invalid subject before making a remote call', () async {
    connectSettings();
    const invalidSubject = BangumiSubject(
      id: 0,
      title: 'Title',
      originalTitle: 'Original',
      coverUrl: 'cover',
      totalEpisodes: 24,
      totalVolumes: 4,
    );

    await expectLater(
      service.bind(
        sourceKey: 'source',
        comicId: 'comic',
        subject: invalidSubject,
        mode: BangumiProgressMode.episode,
      ),
      throwsArgumentError,
    );

    expect(gateway.collectionCalls, isEmpty);
    expect(gateway.createFields, isEmpty);
    expect(gateway.patchFields, isEmpty);
    expect(saveCount, 0);
  });

  test(
    'bind rejects negative subject totals before making a remote call',
    () async {
      connectSettings();
      const invalidSubject = BangumiSubject(
        id: 42,
        title: 'Title',
        originalTitle: 'Original',
        coverUrl: 'cover',
        totalEpisodes: -1,
        totalVolumes: 4,
      );

      await expectLater(
        service.bind(
          sourceKey: 'source',
          comicId: 'comic',
          subject: invalidSubject,
          mode: BangumiProgressMode.episode,
        ),
        throwsArgumentError,
      );

      expect(gateway.collectionCalls, isEmpty);
      expect(gateway.createFields, isEmpty);
      expect(gateway.patchFields, isEmpty);
      expect(saveCount, 0);
    },
  );

  test('bind rejects an invalid remote collection without saving', () async {
    connectSettings();
    gateway.collection = collection(epStatus: -1);

    await expectLater(
      service.bind(
        sourceKey: 'source',
        comicId: 'comic',
        subject: subject(),
        mode: BangumiProgressMode.episode,
      ),
      throwsStateError,
    );

    expect(service.bindingFor('source', 'comic'), isNull);
    expect(gateway.patchFields, isEmpty);
    expect(saveCount, 0);
  });

  test('bind retains a higher remote episode progress', () async {
    connectSettings();
    gateway.collection = collection(epStatus: 20);

    final result = await service.bind(
      sourceKey: 'source',
      comicId: 'comic',
      subject: subject(),
      mode: BangumiProgressMode.episode,
      reliableLocalProgress: const BangumiProgress(
        BangumiProgressField.episode,
        12,
      ),
    );

    expect(gateway.patchFields, isEmpty);
    expect(result.lastRemoteEpisode, 20);
  });

  test('bind ignores mismatched and non-positive local progress', () async {
    connectSettings();
    gateway.collection = collection(epStatus: 10, volStatus: 3);

    final mismatched = await service.bind(
      sourceKey: 'source',
      comicId: 'mismatched',
      subject: subject(),
      mode: BangumiProgressMode.volume,
      reliableLocalProgress: const BangumiProgress(
        BangumiProgressField.episode,
        20,
      ),
    );
    final nonPositive = await service.bind(
      sourceKey: 'source',
      comicId: 'non-positive',
      subject: subject(),
      mode: BangumiProgressMode.episode,
      reliableLocalProgress: const BangumiProgress(
        BangumiProgressField.episode,
        0,
      ),
    );

    expect(gateway.patchFields, isEmpty);
    expect(mismatched.lastRemoteVolume, 3);
    expect(nonPositive.lastRemoteEpisode, 10);
  });

  test(
    'bind creates a collection with reliable progress when absent',
    () async {
      connectSettings();

      final result = await service.bind(
        sourceKey: 'source',
        comicId: 'comic',
        subject: subject(),
        mode: BangumiProgressMode.episode,
        reliableLocalProgress: const BangumiProgress(
          BangumiProgressField.episode,
          12,
        ),
      );

      expect(gateway.createFields, hasLength(1));
      expect(gateway.createFields.single.$1, 42);
      expect(gateway.createFields.single.$2, <String, dynamic>{
        'type': 3,
        'ep_status': 12,
      });
      expect(result.lastRemoteEpisode, 12);
    },
  );

  test('bind creates a default collection without reliable progress', () async {
    connectSettings();

    await service.bind(
      sourceKey: 'source',
      comicId: 'comic',
      subject: subject(),
      mode: BangumiProgressMode.episode,
    );

    expect(gateway.createFields, hasLength(1));
    expect(gateway.createFields.single.$1, 42);
    expect(gateway.createFields.single.$2, <String, dynamic>{'type': 1});
  });

  test(
    'bind reports remote success when persisting a creation fails',
    () async {
      connectSettings();
      final savingService = BangumiService.forTesting(
        gatewayFactory: (_) => gateway,
        saveSettings: () async => throw StateError('save failed'),
      );

      await expectLater(
        savingService.bind(
          sourceKey: 'source',
          comicId: 'comic',
          subject: subject(),
          mode: BangumiProgressMode.episode,
        ),
        throwsA(
          isA<BangumiLocalPersistenceException>().having(
            (error) => error.remoteSucceeded,
            'remoteSucceeded',
            isTrue,
          ),
        ),
      );

      expect(gateway.createFields, hasLength(1));
      expect(savingService.bindingFor('source', 'comic'), isNotNull);
    },
  );

  test('bind does not persist when the remote operation fails', () async {
    connectSettings();
    gateway.collection = collection(epStatus: 10);
    gateway.patchError = StateError('remote failed');

    await expectLater(
      service.bind(
        sourceKey: 'source',
        comicId: 'comic',
        subject: subject(),
        mode: BangumiProgressMode.episode,
        reliableLocalProgress: const BangumiProgress(
          BangumiProgressField.episode,
          12,
        ),
      ),
      throwsStateError,
    );

    expect(service.bindingFor('source', 'comic'), isNull);
  });

  test('refresh updates all remote fields in its local binding', () async {
    connectSettings();
    setBinding(binding(lastRemoteEpisode: 1, lastRemoteVolume: 1, rating: 1));
    gateway.collection = collection(
      epStatus: 12,
      volStatus: 4,
      rate: 9,
      type: 4,
    );

    final result = await service.refresh('source', 'comic');

    expect(result, isNotNull);
    expect(result!.epStatus, 12);
    expect(result.volStatus, 4);
    expect(result.rate, 9);
    expect(result.status, BangumiCollectionStatus.onHold);
    final updated = service.bindingFor('source', 'comic')!;
    expect(updated.lastRemoteEpisode, 12);
    expect(updated.lastRemoteVolume, 4);
    expect(updated.rating, 9);
    expect(updated.collectionStatus, BangumiCollectionStatus.onHold);
    expect(saveCount, 1);
  });

  test(
    'refresh restores the binding when saving its remote state fails',
    () async {
      connectSettings();
      final original = binding(
        lastRemoteEpisode: 1,
        lastRemoteVolume: 1,
        rating: 1,
      );
      setBinding(original);
      gateway.collection = collection(epStatus: 12, volStatus: 4, rate: 9);
      final savingService = BangumiService.forTesting(
        gatewayFactory: (_) => gateway,
        saveSettings: () async => throw StateError('save failed'),
      );

      await expectLater(
        savingService.refresh('source', 'comic'),
        throwsStateError,
      );

      expect(savingService.bindingFor('source', 'comic'), original);
    },
  );

  test(
    'refresh rejects an invalid remote collection without overwriting',
    () async {
      connectSettings();
      final original = binding();
      setBinding(original);
      gateway.collection = collection(rate: 11);

      await expectLater(service.refresh('source', 'comic'), throwsStateError);

      expect(service.bindingFor('source', 'comic'), original);
      expect(saveCount, 0);
    },
  );

  test('refresh rejects an invalid remote collection status', () async {
    connectSettings();
    final original = binding();
    setBinding(original);
    gateway.collection = collection(type: 0);

    await expectLater(service.refresh('source', 'comic'), throwsStateError);

    expect(service.bindingFor('source', 'comic'), original);
    expect(saveCount, 0);
  });

  test(
    'manual progress decrease requires confirmation before patching',
    () async {
      connectSettings();
      setBinding(binding());
      gateway.collection = collection(epStatus: 12, rate: 6);

      await expectLater(
        service.updateManual(
          sourceKey: 'source',
          comicId: 'comic',
          field: BangumiProgressField.episode,
          progress: 10,
          rating: 8,
          allowDecrease: false,
        ),
        throwsA(
          isA<BangumiProgressDecreaseRequired>()
              .having((error) => error.remote, 'remote', 12)
              .having((error) => error.proposed, 'proposed', 10),
        ),
      );

      expect(gateway.patchFields, isEmpty);
    },
  );

  test('manual confirmed decrease patches progress and rating', () async {
    connectSettings();
    setBinding(binding());
    gateway.collection = collection(epStatus: 12, volStatus: 5, rate: 6);

    await service.updateManual(
      sourceKey: 'source',
      comicId: 'comic',
      field: BangumiProgressField.episode,
      progress: 10,
      rating: 8,
      collectionStatus: BangumiCollectionStatus.dropped,
      allowDecrease: true,
    );

    expect(gateway.patchFields, [
      {'ep_status': 10, 'rate': 8, 'type': 5},
    ]);
    final updated = service.bindingFor('source', 'comic')!;
    expect(updated.lastRemoteEpisode, 10);
    expect(updated.lastRemoteVolume, 5);
    expect(updated.rating, 8);
    expect(updated.collectionStatus, BangumiCollectionStatus.dropped);
  });

  test('manual reports remote success when persisting a patch fails', () async {
    connectSettings();
    setBinding(binding(lastRemoteEpisode: 1, lastRemoteVolume: 1, rating: 1));
    gateway.collection = collection(epStatus: 12, volStatus: 5, rate: 6);
    final savingService = BangumiService.forTesting(
      gatewayFactory: (_) => gateway,
      saveSettings: () async => throw StateError('save failed'),
    );

    await expectLater(
      savingService.updateManual(
        sourceKey: 'source',
        comicId: 'comic',
        field: BangumiProgressField.episode,
        progress: 13,
        rating: 8,
        allowDecrease: false,
      ),
      throwsA(
        isA<BangumiLocalPersistenceException>().having(
          (error) => error.remoteSucceeded,
          'remoteSucceeded',
          isTrue,
        ),
      ),
    );

    expect(gateway.patchFields, [
      {'ep_status': 13, 'rate': 8},
    ]);
    final updated = savingService.bindingFor('source', 'comic')!;
    expect(updated.lastRemoteEpisode, 13);
    expect(updated.lastRemoteVolume, 5);
    expect(updated.rating, 8);
  });

  test(
    'manual rejects an invalid remote collection without patching',
    () async {
      connectSettings();
      final original = binding();
      setBinding(original);
      gateway.collection = collection(volStatus: -1);

      await expectLater(
        service.updateManual(
          sourceKey: 'source',
          comicId: 'comic',
          field: BangumiProgressField.episode,
          progress: 13,
          rating: 8,
          allowDecrease: false,
        ),
        throwsStateError,
      );

      expect(gateway.patchFields, isEmpty);
      expect(service.bindingFor('source', 'comic'), original);
      expect(saveCount, 0);
    },
  );

  test('manual rating-only updates only its changed field', () async {
    connectSettings();
    setBinding(binding());
    gateway.collection = collection(epStatus: 12, rate: 6);

    await service.updateManual(
      sourceKey: 'source',
      comicId: 'comic',
      field: BangumiProgressField.episode,
      progress: 12,
      rating: 8,
      allowDecrease: false,
    );

    expect(gateway.patchFields, [
      {'rate': 8},
    ]);
  });

  test('manual status-only update patches and caches the status', () async {
    connectSettings();
    setBinding(binding(collectionStatus: BangumiCollectionStatus.reading));
    gateway.collection = collection(
      epStatus: 12,
      volStatus: 5,
      rate: 6,
      type: 3,
    );

    await service.updateManual(
      sourceKey: 'source',
      comicId: 'comic',
      field: null,
      progress: null,
      rating: null,
      collectionStatus: BangumiCollectionStatus.onHold,
      allowDecrease: false,
    );

    expect(gateway.patchFields, [
      {'type': 4},
    ]);
    final updated = service.bindingFor('source', 'comic')!;
    expect(updated.collectionStatus, BangumiCollectionStatus.onHold);
    expect(updated.lastRemoteEpisode, 12);
    expect(updated.lastRemoteVolume, 5);
    expect(updated.rating, 6);
  });

  test('manual status compares against fresh remote state', () async {
    connectSettings();
    setBinding(binding(collectionStatus: BangumiCollectionStatus.wish));
    gateway.collection = collection(type: 5);

    await service.updateManual(
      sourceKey: 'source',
      comicId: 'comic',
      field: null,
      progress: null,
      rating: null,
      collectionStatus: BangumiCollectionStatus.dropped,
      allowDecrease: false,
    );

    expect(gateway.patchFields, isEmpty);
    expect(
      service.bindingFor('source', 'comic')!.collectionStatus,
      BangumiCollectionStatus.dropped,
    );
  });

  test('manual rating-only update keeps pending automatic progress', () async {
    connectSettings();
    setBinding(binding(lastRemoteEpisode: 5));
    final implicitData = <String, dynamic>{};
    final automatic = BangumiService.forTesting(
      gatewayFactory: (_) => gateway,
      implicitData: implicitData,
    );
    gateway.collection = collection(epStatus: 5, rate: 6);
    gateway.patchError = const BangumiApiException(503, 'offline');
    await automatic.onChapterCompleted(
      sourceKey: 'source',
      comicId: 'comic',
      chapterTitle: '第 10 话',
    );
    gateway.patchError = null;
    gateway.patchFields.clear();

    await automatic.updateManual(
      sourceKey: 'source',
      comicId: 'comic',
      field: null,
      progress: null,
      rating: 8,
      allowDecrease: false,
    );

    expect(gateway.patchFields, [
      {'rate': 8},
    ]);
    expect(automatic.hasPendingProgress('source', 'comic'), isTrue);
  });

  test(
    'manual update omits unchanged fields and validates input ranges',
    () async {
      connectSettings();
      setBinding(binding(lastRemoteEpisode: 1, lastRemoteVolume: 2, rating: 3));
      gateway.collection = collection(epStatus: 12, volStatus: 5, rate: 8);

      await service.updateManual(
        sourceKey: 'source',
        comicId: 'comic',
        field: BangumiProgressField.episode,
        progress: 12,
        rating: 8,
        allowDecrease: false,
      );
      await expectLater(
        service.updateManual(
          sourceKey: 'source',
          comicId: 'comic',
          field: BangumiProgressField.episode,
          progress: -1,
          rating: 8,
          allowDecrease: false,
        ),
        throwsArgumentError,
      );
      await expectLater(
        service.updateManual(
          sourceKey: 'source',
          comicId: 'comic',
          field: BangumiProgressField.episode,
          progress: 12,
          rating: 11,
          allowDecrease: false,
        ),
        throwsArgumentError,
      );

      expect(gateway.patchFields, isEmpty);
      final updated = service.bindingFor('source', 'comic')!;
      expect(updated.lastRemoteEpisode, 12);
      expect(updated.lastRemoteVolume, 5);
      expect(updated.rating, 8);
      expect(saveCount, 1);
    },
  );

  test(
    'updateMode replaces the outer bindings map and unbind stays local',
    () async {
      setBinding(binding());
      final previousBindings = appdata.settings['bangumiBindings'];

      await service.updateMode('source', 'comic', BangumiProgressMode.volume);

      expect(
        appdata.settings['bangumiBindings'],
        isNot(same(previousBindings)),
      );
      expect(
        service.bindingFor('source', 'comic')!.progressMode,
        BangumiProgressMode.volume,
      );
      await service.unbind('source', 'comic');
      expect(service.bindingFor('source', 'comic'), isNull);
      expect(gateway.createFields, isEmpty);
      expect(gateway.patchFields, isEmpty);
    },
  );

  test('updateMode rejects an unbound comic', () async {
    await expectLater(
      service.updateMode('source', 'comic', BangumiProgressMode.volume),
      throwsStateError,
    );
  });

  test('updateMode restores the original binding when saving fails', () async {
    final original = binding();
    setBinding(original);
    final savingService = BangumiService.forTesting(
      gatewayFactory: (_) => gateway,
      saveSettings: () async => throw StateError('save failed'),
    );

    await expectLater(
      savingService.updateMode('source', 'comic', BangumiProgressMode.volume),
      throwsStateError,
    );

    expect(savingService.bindingFor('source', 'comic'), original);
  });

  test('unbind waits for a pending refresh of the same binding', () async {
    connectSettings();
    setBinding(binding());
    gateway.collection = collection(epStatus: 13, volStatus: 5, rate: 8);
    gateway.getCollectionBlocker = Completer<void>();

    final refresh = service.refresh('source', 'comic');
    await pumpEventQueue();
    expect(gateway.collectionCalls, hasLength(1));
    var unbindCompleted = false;
    final unbind = service
        .unbind('source', 'comic')
        .then((_) => unbindCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(unbindCompleted, isFalse);

    gateway.getCollectionBlocker!.complete();
    await refresh;
    await unbind;

    expect(service.bindingFor('source', 'comic'), isNull);
  });

  test(
    'updateMode waits for refresh before changing the same binding',
    () async {
      connectSettings();
      setBinding(binding());
      gateway.collection = collection(epStatus: 13, volStatus: 5, rate: 8);
      gateway.getCollectionBlocker = Completer<void>();

      final refresh = service.refresh('source', 'comic');
      await pumpEventQueue();
      expect(gateway.collectionCalls, hasLength(1));
      var updateCompleted = false;
      final update = service
          .updateMode('source', 'comic', BangumiProgressMode.volume)
          .then((_) => updateCompleted = true);
      await Future<void>.delayed(Duration.zero);
      expect(updateCompleted, isFalse);

      gateway.getCollectionBlocker!.complete();
      await refresh;
      await update;

      expect(
        service.bindingFor('source', 'comic')!.progressMode,
        BangumiProgressMode.volume,
      );
    },
  );

  test(
    'a failed binding save does not overwrite a later binding update',
    () async {
      final bindingA = binding();
      final bindingB = bindingForComic('comic-b');
      setBindings([bindingA, bindingB]);
      final firstSaveEntered = Completer<void>();
      final allowFirstSaveToFail = Completer<void>();
      final secondSaveEntered = Completer<void>();
      var saveCalls = 0;
      final savingService = BangumiService.forTesting(
        gatewayFactory: (_) => gateway,
        saveSettings: () async {
          saveCalls++;
          if (saveCalls == 1) {
            firstSaveEntered.complete();
            await allowFirstSaveToFail.future;
            throw StateError('first save failed');
          }
          secondSaveEntered.complete();
        },
      );

      final updateA = savingService.updateMode(
        'source',
        'comic',
        BangumiProgressMode.volume,
      );
      await firstSaveEntered.future;
      final updateB = savingService.updateMode(
        'source',
        'comic-b',
        BangumiProgressMode.volume,
      );
      await Future<void>.delayed(Duration.zero);
      final secondSaveStartedEarly = secondSaveEntered.isCompleted;

      allowFirstSaveToFail.complete();
      await expectLater(updateA, throwsStateError);
      await updateB;

      expect(secondSaveStartedEarly, isFalse);
      expect(savingService.bindingFor('source', 'comic'), bindingA);
      expect(
        savingService.bindingFor('source', 'comic-b')!.progressMode,
        BangumiProgressMode.volume,
      );
    },
  );

  test('a failed unbind does not discard a later binding update', () async {
    final bindingA = binding();
    final bindingB = bindingForComic('comic-b');
    setBindings([bindingA, bindingB]);
    final firstSaveEntered = Completer<void>();
    final allowFirstSaveToFail = Completer<void>();
    final secondSaveEntered = Completer<void>();
    var saveCalls = 0;
    final savingService = BangumiService.forTesting(
      gatewayFactory: (_) => gateway,
      saveSettings: () async {
        saveCalls++;
        if (saveCalls == 1) {
          firstSaveEntered.complete();
          await allowFirstSaveToFail.future;
          throw StateError('first save failed');
        }
        secondSaveEntered.complete();
      },
    );

    final unbindA = savingService.unbind('source', 'comic');
    await firstSaveEntered.future;
    final updateB = savingService.updateMode(
      'source',
      'comic-b',
      BangumiProgressMode.volume,
    );
    await Future<void>.delayed(Duration.zero);
    final secondSaveStartedEarly = secondSaveEntered.isCompleted;

    allowFirstSaveToFail.complete();
    await expectLater(unbindA, throwsStateError);
    await updateB;

    expect(secondSaveStartedEarly, isFalse);
    expect(savingService.bindingFor('source', 'comic'), bindingA);
    expect(
      savingService.bindingFor('source', 'comic-b')!.progressMode,
      BangumiProgressMode.volume,
    );
  });

  test('a corrupted binding returns null instead of throwing', () {
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): 'not a binding',
    };

    expect(() => service.bindingFor('source', 'comic'), returnsNormally);
    expect(service.bindingFor('source', 'comic'), isNull);
  });

  test('an incomplete or mismatched binding returns null', () {
    final key = bangumiBindingKey('source', 'comic');
    appdata.settings['bangumiBindings'] = {key: {}};
    expect(service.bindingFor('source', 'comic'), isNull);

    appdata.settings['bangumiBindings'] = {
      key: {...binding().toJson(), 'sourceKey': 'another-source'},
    };
    expect(service.bindingFor('source', 'comic'), isNull);

    appdata.settings['bangumiBindings'] = {
      key: {...binding().toJson(), 'subjectId': 0},
    };
    expect(service.bindingFor('source', 'comic'), isNull);
  });

  test('a binding with invalid progress, totals, or rating returns null', () {
    final key = bangumiBindingKey('source', 'comic');
    for (final invalidFields in [
      {'totalEpisodes': -1},
      {'lastRemoteEpisode': -1},
      {'rating': 11},
    ]) {
      appdata.settings['bangumiBindings'] = {
        key: {...binding().toJson(), ...invalidFields},
      };

      expect(service.bindingFor('source', 'comic'), isNull);
    }
  });

  group('automatic chapter progress upload', () {
    late Map<String, dynamic> implicitData;
    late List<RecordingTimer> timers;
    late DateTime now;
    var implicitWrites = 0;

    BangumiService automaticService() => BangumiService.forTesting(
      gatewayFactory: (_) => gateway,
      saveSettings: () async => saveCount++,
      implicitData: implicitData,
      writeImplicitData: () => implicitWrites++,
      now: () => now,
      timerFactory: (duration, callback) {
        final timer = RecordingTimer(duration, callback);
        timers.add(timer);
        return timer;
      },
    );

    setUp(() {
      implicitData = <String, dynamic>{};
      timers = [];
      now = DateTime.utc(2026, 8, 30, 12);
      implicitWrites = 0;
    });

    test(
      'does not call the network when automatic upload is disabled',
      () async {
        connectSettings();
        appdata.settings['bangumiAutoSyncEnabled'] = false;
        setBinding(binding());

        await automaticService().onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );

        expect(gateway.collectionCalls, isEmpty);
        expect(gateway.patchFields, isEmpty);
      },
    );

    test('does not call the network when disconnected or unbound', () async {
      final automatic = automaticService();
      await automatic.onChapterCompleted(
        sourceKey: 'source',
        comicId: 'comic',
        chapterTitle: '第 12 话',
      );

      connectSettings();
      await automatic.onChapterCompleted(
        sourceKey: 'source',
        comicId: 'comic',
        chapterTitle: '第 12 话',
      );

      expect(gateway.collectionCalls, isEmpty);
      expect(gateway.patchFields, isEmpty);
    });

    test(
      'uploads the parser-selected episode, volume, and auto fields',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 1, volStatus: 1);
        final automatic = automaticService();

        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );
        await automatic.updateMode(
          'source',
          'comic',
          BangumiProgressMode.volume,
        );
        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 3 卷',
        );
        await automatic.updateMode('source', 'comic', BangumiProgressMode.auto);
        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 13 话',
        );

        expect(gateway.patchFields, [
          {'ep_status': 12},
          {'vol_status': 3},
          {'ep_status': 13},
        ]);
      },
    );

    test(
      'skips ambiguous and unreliable chapter titles without a request',
      () async {
        connectSettings();
        setBinding(binding().copyWith(progressMode: BangumiProgressMode.auto));
        final automatic = automaticService();

        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 3 卷 第 12 话',
        );
        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12.5 话',
        );
        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '番外',
        );

        expect(gateway.collectionCalls, isEmpty);
        expect(gateway.patchFields, isEmpty);
      },
    );

    test(
      'fetches latest collection and never patches lower or equal progress',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 12);
        final automatic = automaticService();

        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 11 话',
        );
        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );

        expect(gateway.collectionCalls, hasLength(2));
        expect(gateway.patchFields, isEmpty);
        expect(automatic.bindingFor('source', 'comic')!.lastRemoteEpisode, 12);
      },
    );

    test(
      'patches higher progress with only the required status change',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 11, type: 1);

        final automatic = automaticService();
        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );

        expect(gateway.patchFields.single, {'ep_status': 12, 'type': 3});
        expect(
          automatic.bindingFor('source', 'comic')!.collectionStatus,
          BangumiCollectionStatus.reading,
        );
      },
    );

    for (final collectionType in [1, 4, 5]) {
      test(
        'advancing collection type $collectionType changes it to reading',
        () async {
          connectSettings();
          setBinding(binding());
          gateway.collection = collection(epStatus: 11, type: collectionType);

          await automaticService().onChapterCompleted(
            sourceKey: 'source',
            comicId: 'comic',
            chapterTitle: '第 12 话',
          );

          expect(gateway.patchFields.single, {'ep_status': 12, 'type': 3});
        },
      );
    }

    test(
      'marks a known total complete and leaves completed type unchanged',
      () async {
        connectSettings();
        setBinding(binding(totalEpisodes: 12));
        gateway.collection = collection(epStatus: 11, type: 3);
        final automatic = automaticService();

        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );
        gateway.collection = collection(epStatus: 12, type: 2);
        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 13 话',
        );

        expect(gateway.patchFields, [
          {'ep_status': 12, 'type': 2},
          {'ep_status': 13},
        ]);
        expect(
          automatic.bindingFor('source', 'comic')!.collectionStatus,
          BangumiCollectionStatus.completed,
        );
      },
    );

    test(
      'retryable automatic failures are swallowed and queued locally',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 1);
        gateway.patchError = const BangumiApiException(503, 'unavailable');

        await automaticService().onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );

        final pending = implicitData['bangumiPendingProgress'] as Map;
        expect(pending[bangumiBindingKey('source', 'comic')]['ep_status'], {
          'field': 'ep_status',
          'subjectId': 42,
          'username': 'alice',
          'value': 12,
          'attempts': 0,
          'nextAttemptAt': now
              .add(const Duration(minutes: 5))
              .millisecondsSinceEpoch,
        });
        expect(implicitWrites, 1);
      },
    );

    test(
      'pending progress is discarded after a synced subject replacement',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 1);
        gateway.patchError = const BangumiApiException(503, 'offline');
        final automatic = automaticService();

        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );
        gateway.patchError = null;
        gateway.collectionCalls.clear();
        gateway.patchFields.clear();
        setBinding(binding().copyWith(subjectId: 99));

        await automatic.retryPending();

        expect(gateway.collectionCalls, isEmpty);
        expect(gateway.patchFields, isEmpty);
        expect(implicitData['bangumiPendingProgress'], isEmpty);
      },
    );

    test(
      'pending progress is discarded after a synced account replacement',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 1);
        gateway.patchError = const BangumiApiException(503, 'offline');
        final automatic = automaticService();

        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );
        gateway.patchError = null;
        gateway.collectionCalls.clear();
        gateway.patchFields.clear();
        appdata.settings['bangumiUsername'] = 'bob';

        await automatic.retryPending();

        expect(gateway.collectionCalls, isEmpty);
        expect(gateway.patchFields, isEmpty);
        expect(implicitData['bangumiPendingProgress'], isEmpty);
      },
    );

    test(
      'an in-flight upload cannot overwrite a synced binding replacement',
      () async {
        connectSettings();
        final original = binding(lastRemoteEpisode: 1);
        final synced = original.copyWith(subjectId: 99, lastRemoteEpisode: 20);
        setBinding(original);
        gateway.collection = collection(epStatus: 1);
        gateway.getCollectionBlocker = Completer<void>();
        final automatic = automaticService();

        final upload = automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );
        await pumpEventQueue();
        setBinding(synced);
        gateway.getCollectionBlocker!.complete();
        await upload;

        expect(automatic.bindingFor('source', 'comic'), synced);
        expect(implicitData['bangumiPendingProgress'], isNull);
      },
    );

    test(
      'non-retryable automatic failures do not create a pending item',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 1);
        gateway.patchError = const BangumiApiException(400, 'bad request');

        await automaticService().onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );

        expect(implicitData['bangumiPendingProgress'], isNull);
        expect(implicitWrites, 0);
      },
    );

    test(
      'compresses retryable failures to the largest value and increases backoff',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 1);
        gateway.patchError = const BangumiApiException(null, 'offline');
        final automatic = automaticService();

        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );
        now = now.add(const Duration(minutes: 5));
        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 15 话',
        );

        final pending = implicitData['bangumiPendingProgress'] as Map;
        expect(pending[bangumiBindingKey('source', 'comic')]['ep_status'], {
          'field': 'ep_status',
          'subjectId': 42,
          'username': 'alice',
          'value': 15,
          'attempts': 1,
          'nextAttemptAt': now
              .add(const Duration(minutes: 10))
              .millisecondsSinceEpoch,
        });
      },
    );

    test(
      'retains a four-times-failed item without scheduling another timer',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 1);
        gateway.patchError = const BangumiApiException(503, 'unavailable');
        final automatic = automaticService();

        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );
        for (var attempt = 0; attempt < 4; attempt++) {
          now = now.add(const Duration(minutes: 40));
          await automatic.onChapterCompleted(
            sourceKey: 'source',
            comicId: 'comic',
            chapterTitle: '第 12 话',
          );
        }

        final pending = implicitData['bangumiPendingProgress'] as Map;
        expect(
          (pending[bangumiBindingKey('source', 'comic')]['ep_status']
              as Map)['attempts'],
          4,
        );
        expect(timers.where((timer) => timer.isActive), isEmpty);
      },
    );

    test(
      'initialization replays ready pending progress and clears it on success',
      () async {
        connectSettings();
        setBinding(binding(lastRemoteEpisode: 1));
        gateway.collection = collection(epStatus: 1);
        implicitData['bangumiPendingProgress'] = {
          bangumiBindingKey('source', 'comic'): {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 1,
            'nextAttemptAt': now.millisecondsSinceEpoch,
          },
        };
        final automatic = automaticService();

        await automatic.initialize();

        expect(gateway.patchFields.single, {'ep_status': 12});
        expect(implicitData['bangumiPendingProgress'], isEmpty);
        expect(automatic.bindingFor('source', 'comic')!.lastRemoteEpisode, 12);
      },
    );

    test(
      'next completion retries its pending item before uploading newer progress',
      () async {
        connectSettings();
        setBinding(binding(lastRemoteEpisode: 1));
        gateway.collection = collection(epStatus: 1);
        implicitData['bangumiPendingProgress'] = {
          bangumiBindingKey('source', 'comic'): {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 1,
            'nextAttemptAt': now
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch,
          },
        };
        final automatic = automaticService();

        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 13 话',
        );

        expect(gateway.patchFields, [
          {'ep_status': 12},
          {'ep_status': 13},
        ]);
        expect(implicitData['bangumiPendingProgress'], isEmpty);
      },
    );

    test(
      'mode changes and unbinding clear no-longer-applicable pending items',
      () async {
        setBinding(binding());
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 1,
            'nextAttemptAt': now.millisecondsSinceEpoch,
          },
        };
        final automatic = automaticService();

        await automatic.updateMode(
          'source',
          'comic',
          BangumiProgressMode.volume,
        );
        expect(implicitData['bangumiPendingProgress'], isEmpty);

        implicitData['bangumiPendingProgress'] = {
          key: {
            'field': 'vol_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 3,
            'attempts': 1,
            'nextAttemptAt': now.millisecondsSinceEpoch,
          },
        };
        await automatic.unbind('source', 'comic');
        expect(implicitData['bangumiPendingProgress'], isEmpty);
      },
    );

    test('dispose cancels the service retry timer', () async {
      connectSettings();
      setBinding(binding());
      implicitData['bangumiPendingProgress'] = {
        bangumiBindingKey('source', 'comic'): {
          'field': 'ep_status',
          'subjectId': 42,
          'username': 'alice',
          'value': 12,
          'attempts': 1,
          'nextAttemptAt': now
              .add(const Duration(minutes: 5))
              .millisecondsSinceEpoch,
        },
      };
      final automatic = automaticService();

      await automatic.initialize();
      automatic.dispose();

      expect(timers.single.cancelled, isTrue);
    });

    test(
      'connection lifecycle schedules pending work only while connected',
      () async {
        setBinding(binding());
        implicitData['bangumiPendingProgress'] = {
          bangumiBindingKey('source', 'comic'): {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 1,
            'nextAttemptAt': now
                .add(const Duration(minutes: 5))
                .millisecondsSinceEpoch,
          },
        };
        final automatic = automaticService();

        await automatic.initialize();
        expect(timers, isEmpty);

        await automatic.connect('token');
        expect(timers, hasLength(1));
        expect(timers.single.isActive, isTrue);

        await automatic.disconnect();
        expect(timers.single.cancelled, isTrue);
      },
    );

    test('observed synced auto switch restarts the pending timer', () async {
      connectSettings();
      setBinding(binding());
      gateway.collection = collection(epStatus: 1);
      gateway.patchError = const BangumiApiException(503, 'offline');
      final automatic = BangumiService.forTesting(
        gatewayFactory: (_) => gateway,
        implicitData: implicitData,
        writeImplicitData: () => implicitWrites++,
        now: () => now,
        timerFactory: (duration, callback) {
          final timer = RecordingTimer(duration, callback);
          timers.add(timer);
          return timer;
        },
        observeSettings: true,
      );
      addTearDown(automatic.dispose);

      await automatic.onChapterCompleted(
        sourceKey: 'source',
        comicId: 'comic',
        chapterTitle: '第 12 话',
      );
      expect(timers.where((timer) => timer.isActive), hasLength(1));

      appdata.settings['bangumiAutoSyncEnabled'] = false;
      await pumpEventQueue();
      expect(timers.where((timer) => timer.isActive), isEmpty);

      gateway.patchError = null;
      appdata.settings['bangumiAutoSyncEnabled'] = true;
      await pumpEventQueue();
      expect(timers.where((timer) => timer.isActive), hasLength(1));
    });

    test(
      'automatic switch blocks initialization and timer retries but not explicit retry',
      () async {
        connectSettings();
        setBinding(binding(lastRemoteEpisode: 1));
        gateway.collection = collection(epStatus: 1);
        appdata.settings['bangumiAutoSyncEnabled'] = false;
        implicitData['bangumiPendingProgress'] = {
          bangumiBindingKey('source', 'comic'): {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 0,
            'nextAttemptAt': now.millisecondsSinceEpoch,
          },
        };
        final automatic = automaticService();

        await automatic.initialize();
        expect(gateway.collectionCalls, isEmpty);
        expect(timers, isEmpty);
        await automatic.retryPending();
        expect(gateway.patchFields, [
          {'ep_status': 12},
        ]);
      },
    );

    test(
      'remote success clears pending even when binding persistence fails',
      () async {
        connectSettings();
        setBinding(binding(lastRemoteEpisode: 1));
        gateway.collection = collection(epStatus: 1);
        implicitData['bangumiPendingProgress'] = {
          bangumiBindingKey('source', 'comic'): {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 0,
            'nextAttemptAt': now.millisecondsSinceEpoch,
          },
        };
        final failing = BangumiService.forTesting(
          gatewayFactory: (_) => gateway,
          saveSettings: () async => throw StateError('disk full'),
          implicitData: implicitData,
          writeImplicitData: () => implicitWrites++,
          now: () => now,
          timerFactory: (duration, callback) =>
              RecordingTimer(duration, callback),
        );

        await failing.retryPending();

        expect(implicitData['bangumiPendingProgress'], isEmpty);
      },
    );

    test(
      'initial failure starts at zero and four retry failures use 10/20/40 delays',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 1);
        gateway.patchError = const BangumiApiException(503, 'unavailable');
        final automatic = automaticService();

        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );
        expect(
          ((implicitData['bangumiPendingProgress'] as Map).values.single
              as Map)['ep_status'],
          {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 0,
            'nextAttemptAt': now
                .add(const Duration(minutes: 5))
                .millisecondsSinceEpoch,
          },
        );
        for (final delay in [10, 20, 40, 40]) {
          now = now.add(Duration(minutes: delay));
          await automatic.initialize();
        }
        expect(
          (((implicitData['bangumiPendingProgress'] as Map).values.single
                  as Map)['ep_status']
              as Map)['attempts'],
          4,
        );
        expect(timers.where((timer) => timer.isActive), isEmpty);
      },
    );

    test(
      'bind clears stale pending only after it persists its binding',
      () async {
        connectSettings();
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 0,
            'nextAttemptAt': now.millisecondsSinceEpoch,
          },
        };

        await automaticService().bind(
          sourceKey: 'source',
          comicId: 'comic',
          subject: subject(),
          mode: BangumiProgressMode.episode,
        );
        expect(implicitData['bangumiPendingProgress'], isEmpty);
      },
    );

    test('incompatible pending mode is cleaned before retrying', () async {
      connectSettings();
      setBinding(binding().copyWith(progressMode: BangumiProgressMode.volume));
      final key = bangumiBindingKey('source', 'comic');
      implicitData['bangumiPendingProgress'] = {
        key: {
          'field': 'ep_status',
          'subjectId': 42,
          'username': 'alice',
          'value': 12,
          'attempts': 0,
          'nextAttemptAt': now.millisecondsSinceEpoch,
        },
      };

      await automaticService().initialize();

      expect(implicitData['bangumiPendingProgress'], isEmpty);
      expect(gateway.collectionCalls, isEmpty);
    });

    test(
      'manual confirmed progress clears matching automatic pending after remote success',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 12, rate: 6);
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 15,
            'attempts': 0,
            'nextAttemptAt': now.millisecondsSinceEpoch,
          },
        };

        await automaticService().updateManual(
          sourceKey: 'source',
          comicId: 'comic',
          field: BangumiProgressField.episode,
          progress: 10,
          rating: 6,
          allowDecrease: true,
        );

        expect(implicitData['bangumiPendingProgress'], isEmpty);
      },
    );

    test('deterministic retry errors discard the due pending item', () async {
      connectSettings();
      setBinding(binding());
      final key = bangumiBindingKey('source', 'comic');
      implicitData['bangumiPendingProgress'] = {
        key: {
          'field': 'ep_status',
          'subjectId': 42,
          'username': 'alice',
          'value': 12,
          'attempts': 0,
          'nextAttemptAt': now.millisecondsSinceEpoch,
        },
      };

      await automaticService().initialize();

      expect(implicitData['bangumiPendingProgress'], isEmpty);
      expect(timers.where((timer) => timer.isActive), isEmpty);
    });

    test(
      'an unparseable chapter still replays a due pending progress',
      () async {
        connectSettings();
        setBinding(binding().copyWith(progressMode: BangumiProgressMode.auto));
        gateway.collection = collection(epStatus: 1);
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'ep_status': {
              'field': 'ep_status',
              'subjectId': 42,
              'username': 'alice',
              'value': 12,
              'attempts': 0,
              'nextAttemptAt': now.millisecondsSinceEpoch,
            },
          },
        };

        await automaticService().onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '番外',
        );

        expect(gateway.patchFields, [
          {'ep_status': 12},
        ]);
        expect(implicitData['bangumiPendingProgress'], isEmpty);
      },
    );

    test(
      'auto mode preserves either pending field while explicit mode keeps only its field',
      () async {
        setBinding(
          binding().copyWith(progressMode: BangumiProgressMode.episode),
        );
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 0,
            'nextAttemptAt': now.millisecondsSinceEpoch,
          },
        };
        final automatic = automaticService();

        await automatic.updateMode('source', 'comic', BangumiProgressMode.auto);
        expect(implicitData['bangumiPendingProgress'], isNotEmpty);
        await automatic.updateMode(
          'source',
          'comic',
          BangumiProgressMode.volume,
        );
        expect(implicitData['bangumiPendingProgress'], isEmpty);
      },
    );

    test(
      'retry queued behind mode change rereads the binding before sending',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 1);
        gateway.getCollectionBlocker = Completer<void>();
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 0,
            'nextAttemptAt': now.millisecondsSinceEpoch,
          },
        };
        final automatic = automaticService();

        final refresh = automatic.refresh('source', 'comic');
        await pumpEventQueue();
        expect(gateway.collectionCalls, hasLength(1));
        final modeChange = automatic.updateMode(
          'source',
          'comic',
          BangumiProgressMode.volume,
        );
        final retry = automatic.retryPending();
        gateway.getCollectionBlocker!.complete();
        await Future.wait([refresh, modeChange, retry]);

        expect(gateway.collectionCalls, hasLength(1));
        expect(gateway.patchFields, isEmpty);
        expect(implicitData['bangumiPendingProgress'], isEmpty);
      },
    );

    test(
      'retry queued behind unbind rereads the binding before sending',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 1);
        gateway.getCollectionBlocker = Completer<void>();
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 0,
            'nextAttemptAt': now.millisecondsSinceEpoch,
          },
        };
        final automatic = automaticService();

        final refresh = automatic.refresh('source', 'comic');
        await pumpEventQueue();
        expect(gateway.collectionCalls, hasLength(1));
        final unbind = automatic.unbind('source', 'comic');
        final retry = automatic.retryPending();
        gateway.getCollectionBlocker!.complete();
        await Future.wait([refresh, unbind, retry]);

        expect(gateway.collectionCalls, hasLength(1));
        expect(gateway.patchFields, isEmpty);
        expect(implicitData['bangumiPendingProgress'], isEmpty);
      },
    );

    test(
      'queued automatic upload observes a disabled switch after the binding lock',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection();
        gateway.getCollectionBlocker = Completer<void>();
        final automatic = automaticService();
        final refresh = automatic.refresh('source', 'comic');
        await pumpEventQueue();
        final upload = automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );
        appdata.settings['bangumiAutoSyncEnabled'] = false;
        gateway.getCollectionBlocker!.complete();
        await Future.wait([refresh, upload]);

        expect(gateway.collectionCalls, hasLength(1));
        expect(gateway.patchFields, isEmpty);
      },
    );

    test(
      'queued explicit retry observes disconnect after the binding lock',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection();
        gateway.getCollectionBlocker = Completer<void>();
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 0,
            'nextAttemptAt': now.millisecondsSinceEpoch,
          },
        };
        final automatic = automaticService();
        final refresh = automatic.refresh('source', 'comic');
        final retry = automatic.retryPending();
        var disconnected = false;
        final disconnect = automatic.disconnect().then(
          (_) => disconnected = true,
        );
        await pumpEventQueue();
        expect(disconnected, isFalse);
        gateway.getCollectionBlocker!.complete();
        await Future.wait([refresh, disconnect, retry]);

        expect(gateway.collectionCalls, hasLength(1));
        expect(gateway.patchFields, isEmpty);
        expect(implicitData['bangumiPendingProgress'], isNotEmpty);
      },
    );

    test(
      'retry queued behind a compatible mode change keeps the pending field',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(volStatus: 1);
        gateway.getCollectionBlocker = Completer<void>();
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'field': 'vol_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 3,
            'attempts': 0,
            'nextAttemptAt': now.millisecondsSinceEpoch,
          },
        };
        final automatic = automaticService();
        final refresh = automatic.refresh('source', 'comic');
        await pumpEventQueue();
        final mode = automatic.updateMode(
          'source',
          'comic',
          BangumiProgressMode.volume,
        );
        final retry = automatic.retryPending();
        gateway.getCollectionBlocker!.complete();
        await Future.wait([refresh, mode, retry]);

        expect(gateway.collectionCalls, hasLength(2));
        expect(gateway.patchFields, [
          {'vol_status': 3},
        ]);
      },
    );

    test(
      'queued initialize observes disabled automatic sync after the binding lock',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection();
        gateway.getCollectionBlocker = Completer<void>();
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 0,
            'nextAttemptAt': now.millisecondsSinceEpoch,
          },
        };
        final automatic = automaticService();
        final refresh = automatic.refresh('source', 'comic');
        await pumpEventQueue();
        final initialize = automatic.initialize();
        appdata.settings['bangumiAutoSyncEnabled'] = false;
        gateway.getCollectionBlocker!.complete();
        await Future.wait([refresh, initialize]);

        expect(gateway.collectionCalls, hasLength(1));
        expect(gateway.patchFields, isEmpty);
        expect(implicitData['bangumiPendingProgress'], isNotEmpty);
      },
    );

    test(
      'queued initialize rereads a retry backoff before sending again',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 1);
        gateway.patchError = const BangumiApiException(503, 'unavailable');
        gateway.getCollectionBlocker = Completer<void>();
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 0,
            'nextAttemptAt': now.millisecondsSinceEpoch,
          },
        };
        final automatic = automaticService();
        final refresh = automatic.refresh('source', 'comic');
        final completion = automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 13 话',
        );
        await pumpEventQueue();
        final initialize = automatic.initialize();
        gateway.getCollectionBlocker!.complete();
        await Future.wait([refresh, completion, initialize]);

        expect(gateway.collectionCalls, hasLength(2));
        expect(gateway.patchFields, hasLength(1));
        final pending =
            (implicitData['bangumiPendingProgress'] as Map)[key] as Map;
        expect((pending['ep_status'] as Map)['attempts'], 1);
        expect(
          timers.where((timer) => timer.isActive).single.duration,
          const Duration(minutes: 10),
        );
      },
    );

    test(
      'initialization removes pending entries without a valid binding',
      () async {
        connectSettings();
        final key = bangumiBindingKey('source', 'comic');
        for (final rawBinding in [null, <String, dynamic>{}]) {
          appdata.settings['bangumiBindings'] = rawBinding == null
              ? <String, dynamic>{}
              : <String, dynamic>{key: rawBinding};
          implicitData['bangumiPendingProgress'] = {
            key: {
              'field': 'ep_status',
              'subjectId': 42,
              'username': 'alice',
              'value': 12,
              'attempts': 1,
              'nextAttemptAt': now.millisecondsSinceEpoch,
            },
          };
          timers.clear();

          await automaticService().initialize();

          expect(implicitData['bangumiPendingProgress'], isEmpty);
          expect(timers, isEmpty);
        }
      },
    );

    test(
      'initialization removes pending entries with a mismatched binding key',
      () async {
        connectSettings();
        final key = bangumiBindingKey('source', 'comic');
        appdata.settings['bangumiBindings'] = {
          key: binding().copyWith(comicId: 'another-comic').toJson(),
        };
        implicitData['bangumiPendingProgress'] = {
          key: {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 0,
            'nextAttemptAt': now.millisecondsSinceEpoch,
          },
        };

        await automaticService().initialize();

        expect(gateway.collectionCalls, isEmpty);
        expect(gateway.patchFields, isEmpty);
        expect(implicitData['bangumiPendingProgress'], isEmpty);
      },
    );

    test(
      'auto mode retains independent episode and volume pending entries',
      () async {
        connectSettings();
        setBinding(binding().copyWith(progressMode: BangumiProgressMode.auto));
        gateway.collection = collection(epStatus: 1, volStatus: 1);
        gateway.patchError = const BangumiApiException(503, 'offline');
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'vol_status': {
              'field': 'vol_status',
              'subjectId': 42,
              'username': 'alice',
              'value': 3,
              'attempts': 0,
              'nextAttemptAt': now.millisecondsSinceEpoch,
            },
          },
        };

        await automaticService().onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );

        expect((implicitData['bangumiPendingProgress'] as Map)[key], {
          'ep_status': {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 0,
            'nextAttemptAt': now
                .add(const Duration(minutes: 5))
                .millisecondsSinceEpoch,
          },
          'vol_status': {
            'field': 'vol_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 3,
            'attempts': 1,
            'nextAttemptAt': now
                .add(const Duration(minutes: 10))
                .millisecondsSinceEpoch,
          },
        });
      },
    );

    test(
      'explicit retry surfaces retryable and deterministic API errors',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 1);
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 0,
            'nextAttemptAt': now.millisecondsSinceEpoch,
          },
        };
        gateway.patchError = const BangumiApiException(503, 'offline');
        final automatic = automaticService();

        await expectLater(
          automatic.retryPending(),
          throwsA(isA<BangumiApiException>()),
        );
        gateway.patchError = const BangumiApiException(400, 'invalid');
        await expectLater(
          automatic.retryPending(),
          throwsA(isA<BangumiApiException>()),
        );
        expect(implicitData['bangumiPendingProgress'], isEmpty);
      },
    );

    test(
      'authentication failure pauses startup replay before another binding',
      () async {
        connectSettings();
        final first = binding();
        final second = binding().copyWith(
          sourceKey: 'source-two',
          comicId: 'comic-two',
          subjectId: 2,
        );
        setBindings([first, second]);
        gateway.collection = collection(epStatus: 1);
        gateway.patchError = const BangumiApiException(401, 'expired token');
        final firstKey = bangumiBindingKey(first.sourceKey, first.comicId);
        final secondKey = bangumiBindingKey(second.sourceKey, second.comicId);
        implicitData['bangumiPendingProgress'] = {
          firstKey: {
            'ep_status': {
              'field': 'ep_status',
              'subjectId': 42,
              'username': 'alice',
              'value': 12,
              'attempts': 0,
              'nextAttemptAt': now.millisecondsSinceEpoch,
            },
          },
          secondKey: {
            'ep_status': {
              'field': 'ep_status',
              'subjectId': 2,
              'username': 'alice',
              'value': 8,
              'attempts': 0,
              'nextAttemptAt': now.millisecondsSinceEpoch,
            },
          },
        };

        await automaticService().initialize();

        expect(gateway.collectionCalls, [('alice', first.subjectId)]);
        expect(gateway.patchFields, [
          {'ep_status': 12},
        ]);
        expect(
          implicitData['bangumiPendingProgress'],
          containsPair(firstKey, isNotNull),
        );
        expect(
          implicitData['bangumiPendingProgress'],
          containsPair(secondKey, isNotNull),
        );
        expect(timers.where((timer) => timer.isActive), isEmpty);
      },
    );

    test(
      'authentication failure queues the current automatic progress',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 1);
        gateway.patchError = const BangumiApiException(403, 'forbidden');
        final key = bangumiBindingKey('source', 'comic');

        await automaticService().onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );

        expect((implicitData['bangumiPendingProgress'] as Map)[key], {
          'ep_status': {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 0,
            'nextAttemptAt': now
                .add(const Duration(minutes: 5))
                .millisecondsSinceEpoch,
          },
        });
        expect(timers.where((timer) => timer.isActive), isEmpty);
      },
    );

    test(
      'authentication pause merges later automatic progress without another request',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 1);
        gateway.patchError = const BangumiApiException(401, 'expired token');
        final key = bangumiBindingKey('source', 'comic');
        final automatic = automaticService();

        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );
        expect(automatic.isAuthenticationPaused, isTrue);
        gateway.patchError = null;
        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 13 话',
        );

        expect(gateway.collectionCalls, [('alice', 42)]);
        expect(gateway.patchFields, [
          {'ep_status': 12},
        ]);
        expect(
          (((implicitData['bangumiPendingProgress'] as Map)[key]
                  as Map)['ep_status']
              as Map)['value'],
          13,
        );
        expect(timers.where((timer) => timer.isActive), isEmpty);
        await automatic.disconnect();
        expect(automatic.isAuthenticationPaused, isFalse);
      },
    );

    test(
      'synced credentials resume an authentication-paused completion',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 1);
        gateway.patchError = const BangumiApiException(401, 'expired token');
        final automatic = automaticService();

        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );
        gateway.patchError = null;
        appdata.settings['bangumiAccessToken'] = 'synced-token';
        appdata.settings['bangumiUsername'] = 'bob';
        await automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 13 话',
        );

        expect(automatic.isAuthenticationPaused, isFalse);
        expect(gateway.collectionCalls, [('alice', 42), ('bob', 42)]);
        expect(gateway.patchFields, [
          {'ep_status': 12},
          {'ep_status': 13},
        ]);
      },
    );

    test('observed synced credentials clear an authentication pause', () async {
      connectSettings();
      setBinding(binding());
      gateway.collection = collection(epStatus: 1);
      gateway.patchError = const BangumiApiException(401, 'expired token');
      final automatic = BangumiService.forTesting(
        gatewayFactory: (_) => gateway,
        implicitData: implicitData,
        writeImplicitData: () => implicitWrites++,
        now: () => now,
        timerFactory: (duration, callback) {
          final timer = RecordingTimer(duration, callback);
          timers.add(timer);
          return timer;
        },
        observeSettings: true,
      );
      addTearDown(automatic.dispose);

      await automatic.onChapterCompleted(
        sourceKey: 'source',
        comicId: 'comic',
        chapterTitle: '第 12 话',
      );
      expect(automatic.isAuthenticationPaused, isTrue);

      gateway.patchError = null;
      appdata.settings['bangumiAccessToken'] = 'synced-token';
      appdata.settings['bangumiUsername'] = 'bob';
      await pumpEventQueue();

      expect(automatic.isAuthenticationPaused, isFalse);
      expect(implicitData['bangumiPendingProgress'], isEmpty);
      expect(gateway.collectionCalls, [('alice', 42)]);
    });

    test(
      'stale authentication failure cannot pause synced credentials',
      () async {
        connectSettings();
        setBinding(binding());
        final oldGateway = FakeBangumiGateway()
          ..collection = collection(epStatus: 1)
          ..getCollectionBlocker = Completer<void>()
          ..getCollectionError = const BangumiApiException(
            401,
            'expired token',
          );
        final newGateway = FakeBangumiGateway()
          ..collection = collection(epStatus: 1);
        final automatic = BangumiService.forTesting(
          gatewayFactory: (token) =>
              token == 'synced-token' ? newGateway : oldGateway,
          implicitData: implicitData,
          writeImplicitData: () => implicitWrites++,
          now: () => now,
          timerFactory: (duration, callback) {
            final timer = RecordingTimer(duration, callback);
            timers.add(timer);
            return timer;
          },
          observeSettings: true,
        );
        addTearDown(automatic.dispose);

        final upload = automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );
        await pumpEventQueue();
        appdata.settings['bangumiAccessToken'] = 'synced-token';
        await pumpEventQueue();
        oldGateway.getCollectionBlocker!.complete();
        await upload;
        await pumpEventQueue();

        expect(automatic.isAuthenticationPaused, isFalse);
        await automatic.retryPending();
        expect(newGateway.collectionCalls, [('alice', 42)]);
        expect(newGateway.patchFields, [
          {'ep_status': 12},
        ]);
      },
    );

    test(
      'a successful explicit retry resumes due work and schedules future work',
      () async {
        connectSettings();
        final first = binding();
        final second = binding().copyWith(
          sourceKey: 'source-two',
          comicId: 'comic-two',
          subjectId: 2,
        );
        final future = binding().copyWith(
          sourceKey: 'source-three',
          comicId: 'comic-three',
          subjectId: 3,
        );
        setBindings([first, second, future]);
        gateway.collection = collection(epStatus: 1);
        gateway.patchError = const BangumiApiException(403, 'expired token');
        final secondKey = bangumiBindingKey(second.sourceKey, second.comicId);
        final futureKey = bangumiBindingKey(future.sourceKey, future.comicId);
        final automatic = automaticService();

        await automatic.onChapterCompleted(
          sourceKey: first.sourceKey,
          comicId: first.comicId,
          chapterTitle: '第 12 话',
        );
        implicitData['bangumiPendingProgress'] = {
          ...(implicitData['bangumiPendingProgress'] as Map),
          secondKey: {
            'ep_status': {
              'field': 'ep_status',
              'subjectId': 2,
              'username': 'alice',
              'value': 13,
              'attempts': 0,
              'nextAttemptAt': now.millisecondsSinceEpoch,
            },
          },
          futureKey: {
            'ep_status': {
              'field': 'ep_status',
              'subjectId': 3,
              'username': 'alice',
              'value': 6,
              'attempts': 0,
              'nextAttemptAt': now
                  .add(const Duration(minutes: 5))
                  .millisecondsSinceEpoch,
            },
          },
        };
        gateway.patchFields.clear();
        gateway.patchError = null;

        await automatic.retryPending();

        expect(gateway.patchFields, [
          {'ep_status': 12},
          {'ep_status': 13},
        ]);
        expect((implicitData['bangumiPendingProgress'] as Map), {
          futureKey: {
            'ep_status': {
              'field': 'ep_status',
              'subjectId': 3,
              'username': 'alice',
              'value': 6,
              'attempts': 0,
              'nextAttemptAt': now
                  .add(const Duration(minutes: 5))
                  .millisecondsSinceEpoch,
            },
          },
        });
        expect(timers.where((timer) => timer.isActive), hasLength(1));
        expect(
          timers.where((timer) => timer.isActive).single.duration,
          const Duration(minutes: 5),
        );
      },
    );

    test(
      'a remotely successful explicit retry resumes timers when local persistence fails',
      () async {
        connectSettings();
        final first = binding();
        final future = binding().copyWith(
          sourceKey: 'source-two',
          comicId: 'comic-two',
          subjectId: 2,
        );
        setBindings([first, future]);
        gateway.collection = collection(epStatus: 1);
        gateway.patchError = const BangumiApiException(401, 'expired token');
        final futureKey = bangumiBindingKey(future.sourceKey, future.comicId);
        var failSave = false;
        final automatic = BangumiService.forTesting(
          gatewayFactory: (_) => gateway,
          saveSettings: () async {
            if (failSave) throw StateError('save failed');
          },
          implicitData: implicitData,
          writeImplicitData: () => implicitWrites++,
          now: () => now,
          timerFactory: (duration, callback) {
            final timer = RecordingTimer(duration, callback);
            timers.add(timer);
            return timer;
          },
        );

        await automatic.onChapterCompleted(
          sourceKey: first.sourceKey,
          comicId: first.comicId,
          chapterTitle: '第 12 话',
        );
        implicitData['bangumiPendingProgress'] = {
          ...(implicitData['bangumiPendingProgress'] as Map),
          futureKey: {
            'ep_status': {
              'field': 'ep_status',
              'subjectId': 2,
              'username': 'alice',
              'value': 6,
              'attempts': 0,
              'nextAttemptAt': now
                  .add(const Duration(minutes: 5))
                  .millisecondsSinceEpoch,
            },
          },
        };
        gateway.patchFields.clear();
        gateway.patchError = null;
        failSave = true;

        await automatic.retryPending();

        expect(gateway.patchFields, [
          {'ep_status': 12},
        ]);
        expect((implicitData['bangumiPendingProgress'] as Map), {
          futureKey: {
            'ep_status': {
              'field': 'ep_status',
              'subjectId': 2,
              'username': 'alice',
              'value': 6,
              'attempts': 0,
              'nextAttemptAt': now
                  .add(const Duration(minutes: 5))
                  .millisecondsSinceEpoch,
            },
          },
        });
        expect(timers.where((timer) => timer.isActive), hasLength(1));
      },
    );

    test(
      'a successful reconnect resumes an authentication-paused queue',
      () async {
        final oldGateway = FakeBangumiGateway()
          ..collection = collection(epStatus: 1)
          ..patchError = const BangumiApiException(401, 'expired token');
        final newGateway = FakeBangumiGateway()
          ..user = const BangumiUser('alice', 'Alice')
          ..collection = collection(epStatus: 1);
        connectSettings();
        setBinding(binding());
        final switching = BangumiService.forTesting(
          gatewayFactory: (token) =>
              token == 'new-token' ? newGateway : oldGateway,
          saveSettings: () async => saveCount++,
          implicitData: implicitData,
          writeImplicitData: () => implicitWrites++,
          now: () => now,
          timerFactory: (duration, callback) {
            final timer = RecordingTimer(duration, callback);
            timers.add(timer);
            return timer;
          },
        );

        await switching.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );
        await switching.connect('new-token');
        await switching.retryPending();

        expect(newGateway.patchFields, [
          {'ep_status': 12},
        ]);
        expect(implicitData['bangumiPendingProgress'], isEmpty);
      },
    );

    test(
      'startup retries an exhausted pending item despite its future backoff',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 1);
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'ep_status': {
              'field': 'ep_status',
              'subjectId': 42,
              'username': 'alice',
              'value': 12,
              'attempts': 4,
              'nextAttemptAt': now
                  .add(const Duration(minutes: 40))
                  .millisecondsSinceEpoch,
            },
          },
        };

        await automaticService().initialize();

        expect(gateway.patchFields, [
          {'ep_status': 12},
        ]);
        expect(implicitData['bangumiPendingProgress'], isEmpty);
      },
    );

    test(
      'startup retries each exhausted field only once for an auto binding',
      () async {
        connectSettings();
        setBinding(binding().copyWith(progressMode: BangumiProgressMode.auto));
        gateway.collection = collection(epStatus: 1, volStatus: 1);
        gateway.patchError = const BangumiApiException(503, 'offline');
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'ep_status': {
              'field': 'ep_status',
              'subjectId': 42,
              'username': 'alice',
              'value': 12,
              'attempts': 4,
              'nextAttemptAt': now
                  .add(const Duration(minutes: 40))
                  .millisecondsSinceEpoch,
            },
            'vol_status': {
              'field': 'vol_status',
              'subjectId': 42,
              'username': 'alice',
              'value': 3,
              'attempts': 4,
              'nextAttemptAt': now
                  .add(const Duration(minutes: 40))
                  .millisecondsSinceEpoch,
            },
          },
        };

        await automaticService().initialize();

        expect(gateway.patchFields, [
          {'ep_status': 12},
          {'vol_status': 3},
        ]);
        final pending =
            (implicitData['bangumiPendingProgress'] as Map)[key] as Map;
        expect((pending['ep_status'] as Map)['attempts'], 5);
        expect((pending['vol_status'] as Map)['attempts'], 5);
      },
    );

    test(
      'startup keeps a non-exhausted pending item in its future backoff',
      () async {
        connectSettings();
        setBinding(binding());
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'ep_status': {
              'field': 'ep_status',
              'subjectId': 42,
              'username': 'alice',
              'value': 12,
              'attempts': 3,
              'nextAttemptAt': now
                  .add(const Duration(minutes: 40))
                  .millisecondsSinceEpoch,
            },
          },
        };

        await automaticService().initialize();

        expect(gateway.collectionCalls, isEmpty);
        expect((implicitData['bangumiPendingProgress'] as Map)[key], isNotNull);
      },
    );

    test(
      'startup cleans invalid canonical siblings without dropping a valid item',
      () async {
        connectSettings();
        setBinding(binding());
        final key = bangumiBindingKey('source', 'comic');
        final valid = {
          'field': 'ep_status',
          'subjectId': 42,
          'username': 'alice',
          'value': 12,
          'attempts': 0,
          'nextAttemptAt': now
              .add(const Duration(minutes: 5))
              .millisecondsSinceEpoch,
        };
        implicitData['bangumiPendingProgress'] = {
          key: {
            'ep_status': valid,
            'vol_status': {
              'field': 'ep_status',
              'subjectId': 42,
              'username': 'alice',
              'value': 3,
              'attempts': 0,
              'nextAttemptAt': now.millisecondsSinceEpoch,
            },
          },
        };

        await automaticService().initialize();

        expect(gateway.collectionCalls, isEmpty);
        expect((implicitData['bangumiPendingProgress'] as Map)[key], {
          'ep_status': valid,
        });
        expect(implicitWrites, greaterThanOrEqualTo(1));
      },
    );

    test(
      'a timer skips exhausted work when another pending item becomes due',
      () async {
        connectSettings();
        final exhausted = binding();
        final due = binding().copyWith(
          sourceKey: 'source-two',
          comicId: 'comic-two',
          subjectId: 2,
        );
        setBindings([exhausted, due]);
        final exhaustedKey = bangumiBindingKey(
          exhausted.sourceKey,
          exhausted.comicId,
        );
        final dueKey = bangumiBindingKey(due.sourceKey, due.comicId);
        implicitData['bangumiPendingProgress'] = {
          exhaustedKey: {
            'ep_status': {
              'field': 'ep_status',
              'subjectId': 42,
              'username': 'alice',
              'value': 12,
              'attempts': 3,
              'nextAttemptAt': now
                  .add(const Duration(minutes: 5))
                  .millisecondsSinceEpoch,
            },
          },
        };
        final automatic = automaticService();
        await automatic.initialize();
        implicitData['bangumiPendingProgress'] = {
          ...(implicitData['bangumiPendingProgress'] as Map),
          exhaustedKey: {
            'ep_status': {
              'field': 'ep_status',
              'subjectId': 42,
              'username': 'alice',
              'value': 12,
              'attempts': 4,
              'nextAttemptAt': now.millisecondsSinceEpoch,
            },
          },
          dueKey: {
            'ep_status': {
              'field': 'ep_status',
              'subjectId': 2,
              'username': 'alice',
              'value': 8,
              'attempts': 0,
              'nextAttemptAt': now.millisecondsSinceEpoch,
            },
          },
        };
        gateway.collection = collection(epStatus: 1);

        timers.single.fire();
        await pumpEventQueue();

        expect(gateway.collectionCalls, [('alice', due.subjectId)]);
        expect(gateway.patchFields, [
          {'ep_status': 8},
        ]);
        expect(
          (implicitData['bangumiPendingProgress'] as Map).containsKey(
            exhaustedKey,
          ),
          isTrue,
        );
      },
    );

    test(
      'queue writes discard invalid canonical siblings instead of repairing them',
      () async {
        connectSettings();
        setBinding(binding().copyWith(progressMode: BangumiProgressMode.auto));
        gateway.collection = collection(epStatus: 1);
        gateway.patchError = const BangumiApiException(503, 'offline');
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'vol_status': {
              'field': 'ep_status',
              'subjectId': 42,
              'username': 'alice',
              'value': 99,
              'attempts': 0,
              'nextAttemptAt': now.millisecondsSinceEpoch,
            },
          },
        };

        await automaticService().onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );

        expect((implicitData['bangumiPendingProgress'] as Map)[key], {
          'ep_status': {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 0,
            'nextAttemptAt': now
                .add(const Duration(minutes: 5))
                .millisecondsSinceEpoch,
          },
        });
      },
    );

    test('field removal discards invalid canonical siblings', () async {
      connectSettings();
      setBinding(binding());
      gateway.collection = collection(epStatus: 1, volStatus: 3, rate: 6);
      final key = bangumiBindingKey('source', 'comic');
      final validEpisode = {
        'field': 'ep_status',
        'subjectId': 42,
        'username': 'alice',
        'value': 12,
        'attempts': 0,
        'nextAttemptAt': now.millisecondsSinceEpoch,
      };
      implicitData['bangumiPendingProgress'] = {
        key: {
          'ep_status': validEpisode,
          'vol_status': {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 99,
            'attempts': 0,
            'nextAttemptAt': now.millisecondsSinceEpoch,
          },
        },
      };

      await automaticService().updateManual(
        sourceKey: 'source',
        comicId: 'comic',
        field: BangumiProgressField.volume,
        progress: 3,
        rating: 6,
        allowDecrease: true,
      );

      expect((implicitData['bangumiPendingProgress'] as Map)[key], {
        'ep_status': validEpisode,
      });
    });

    test('legacy pending without target identity is discarded', () async {
      connectSettings();
      setBinding(binding());
      final key = bangumiBindingKey('source', 'comic');
      implicitData['bangumiPendingProgress'] = {
        key: {
          'field': 'ep_status',
          'value': 12,
          'attempts': 0,
          'nextAttemptAt': now
              .add(const Duration(minutes: 5))
              .millisecondsSinceEpoch,
        },
      };

      await automaticService().initialize();

      expect(implicitData['bangumiPendingProgress'], isEmpty);
      expect(gateway.collectionCalls, isEmpty);
      expect(implicitWrites, greaterThanOrEqualTo(1));
    });

    test('fired retry timer uploads an expired pending item', () async {
      connectSettings();
      setBinding(binding(lastRemoteEpisode: 1));
      gateway.collection = collection(epStatus: 1);
      final key = bangumiBindingKey('source', 'comic');
      implicitData['bangumiPendingProgress'] = {
        key: {
          'field': 'ep_status',
          'subjectId': 42,
          'username': 'alice',
          'value': 12,
          'attempts': 0,
          'nextAttemptAt': now
              .add(const Duration(minutes: 5))
              .millisecondsSinceEpoch,
        },
      };
      final automatic = automaticService();
      await automatic.initialize();
      now = now.add(const Duration(minutes: 5));

      timers.single.fire();
      await pumpEventQueue();

      expect(gateway.patchFields, [
        {'ep_status': 12},
      ]);
      expect(implicitData['bangumiPendingProgress'], isEmpty);
    });

    test(
      'failed connection save cancels then restores the pending retry timer',
      () async {
        connectSettings();
        setBinding(binding());
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 0,
            'nextAttemptAt': now
                .add(const Duration(minutes: 5))
                .millisecondsSinceEpoch,
          },
        };
        final saveBlocker = Completer<void>();
        final saving = BangumiService.forTesting(
          gatewayFactory: (_) => gateway,
          saveSettings: () async {
            await saveBlocker.future;
            throw StateError('save failed');
          },
          implicitData: implicitData,
          writeImplicitData: () => implicitWrites++,
          now: () => now,
          timerFactory: (duration, callback) {
            final timer = RecordingTimer(duration, callback);
            timers.add(timer);
            return timer;
          },
        );
        await saving.initialize();
        final connect = saving.connect('new-token');
        await pumpEventQueue();
        expect(timers.single.cancelled, isTrue);

        saveBlocker.complete();
        await expectLater(connect, throwsStateError);
        expect(timers.where((timer) => timer.isActive), hasLength(1));
      },
    );

    test('connect waits for a blocked old-account automatic upload', () async {
      final oldGateway = FakeBangumiGateway()
        ..collection = collection(epStatus: 1)
        ..getCollectionBlocker = Completer<void>();
      final newGateway = FakeBangumiGateway()
        ..user = const BangumiUser('new-user', 'New');
      connectSettings();
      setBinding(binding());
      final switching = BangumiService.forTesting(
        gatewayFactory: (token) =>
            token == 'new-token' ? newGateway : oldGateway,
        implicitData: implicitData,
        writeImplicitData: () => implicitWrites++,
        now: () => now,
        timerFactory: (duration, callback) =>
            RecordingTimer(duration, callback),
      );

      final upload = switching.onChapterCompleted(
        sourceKey: 'source',
        comicId: 'comic',
        chapterTitle: '第 12 话',
      );
      await pumpEventQueue();
      expect(oldGateway.collectionCalls, hasLength(1));
      var connected = false;
      final connect = switching
          .connect('new-token')
          .then((_) => connected = true);
      await pumpEventQueue();
      expect(connected, isFalse);
      oldGateway.getCollectionBlocker!.complete();
      await Future.wait([upload, connect]);

      expect(oldGateway.patchFields, [
        {'ep_status': 12},
      ]);
      expect(newGateway.collectionCalls, isEmpty);
      expect(newGateway.patchFields, isEmpty);
      expect(newGateway.currentUserCalls, 1);
      expect(appdata.settings['bangumiUsername'], 'new-user');
    });

    test(
      'disconnect waits for a blocked old-account upload before clearing credentials',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 1);
        gateway.getCollectionBlocker = Completer<void>();
        final automatic = automaticService();
        final upload = automatic.onChapterCompleted(
          sourceKey: 'source',
          comicId: 'comic',
          chapterTitle: '第 12 话',
        );
        await pumpEventQueue();
        var disconnected = false;
        final disconnect = automatic.disconnect().then(
          (_) => disconnected = true,
        );
        await pumpEventQueue();
        expect(disconnected, isFalse);
        gateway.getCollectionBlocker!.complete();
        await Future.wait([upload, disconnect]);

        expect(gateway.patchFields, [
          {'ep_status': 12},
        ]);
        expect(appdata.settings['bangumiAccessToken'], '');
      },
    );

    test(
      'fired retry timers back off through four failed attempts then stop',
      () async {
        connectSettings();
        setBinding(binding());
        gateway.collection = collection(epStatus: 1);
        gateway.patchError = const BangumiApiException(503, 'offline');
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 0,
            'nextAttemptAt': now
                .add(const Duration(minutes: 5))
                .millisecondsSinceEpoch,
          },
        };
        final automatic = automaticService();
        await automatic.initialize();

        for (final delay in [5, 10, 20, 40]) {
          now = now.add(Duration(minutes: delay));
          final active = timers.where((timer) => timer.isActive).single;
          active.fire();
          await pumpEventQueue();
        }

        expect(
          (((implicitData['bangumiPendingProgress'] as Map)[key]
                  as Map)['ep_status']
              as Map)['attempts'],
          4,
        );
        expect(timers.where((timer) => timer.isActive), isEmpty);
      },
    );

    test(
      'cancelled disconnect and dispose timers cannot make network calls when fired',
      () async {
        connectSettings();
        setBinding(binding());
        final key = bangumiBindingKey('source', 'comic');
        implicitData['bangumiPendingProgress'] = {
          key: {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 12,
            'attempts': 0,
            'nextAttemptAt': now
                .add(const Duration(minutes: 5))
                .millisecondsSinceEpoch,
          },
        };
        final automatic = automaticService();
        await automatic.initialize();
        final disconnectTimer = timers.single;
        await automatic.disconnect();
        disconnectTimer.fire();
        automatic.dispose();

        expect(gateway.collectionCalls, isEmpty);
        expect(gateway.patchFields, isEmpty);
      },
    );

    test('unbind immediately removes malformed pending entries', () async {
      final key = bangumiBindingKey('source', 'comic');
      setBinding(binding());
      implicitData['bangumiPendingProgress'] = {
        key: {'field': 'invalid'},
      };

      await automaticService().unbind('source', 'comic');

      expect(implicitData['bangumiPendingProgress'], isEmpty);
      expect(implicitWrites, 1);
    });

    test('startup cleans malformed pending entries in one write', () async {
      connectSettings();
      implicitData['bangumiPendingProgress'] = {
        for (var index = 0; index < 50; index++) 'broken-$index': 'invalid',
      };

      await automaticService().initialize();

      expect(implicitData['bangumiPendingProgress'], isEmpty);
      expect(implicitWrites, 1);
      expect(timers, isEmpty);
    });

    test('failed disconnect save restores the pending retry timer', () async {
      connectSettings();
      setBinding(binding());
      final key = bangumiBindingKey('source', 'comic');
      implicitData['bangumiPendingProgress'] = {
        key: {
          'field': 'ep_status',
          'subjectId': 42,
          'username': 'alice',
          'value': 12,
          'attempts': 0,
          'nextAttemptAt': now
              .add(const Duration(minutes: 5))
              .millisecondsSinceEpoch,
        },
      };
      final saveBlocker = Completer<void>();
      final saving = BangumiService.forTesting(
        gatewayFactory: (_) => gateway,
        saveSettings: () async {
          await saveBlocker.future;
          throw StateError('save failed');
        },
        implicitData: implicitData,
        writeImplicitData: () => implicitWrites++,
        now: () => now,
        timerFactory: (duration, callback) {
          final timer = RecordingTimer(duration, callback);
          timers.add(timer);
          return timer;
        },
      );
      await saving.initialize();
      final disconnect = saving.disconnect();
      await pumpEventQueue();
      expect(timers.single.cancelled, isTrue);

      saveBlocker.complete();
      await expectLater(disconnect, throwsStateError);
      expect(appdata.settings['bangumiAccessToken'], 'token');
      expect(timers.where((timer) => timer.isActive), hasLength(1));
    });
  });
}

void connectSettings() {
  appdata.settings['bangumiAccessToken'] = 'token';
  appdata.settings['bangumiUsername'] = 'alice';
}

void setBinding(BangumiBinding binding) {
  appdata.settings['bangumiBindings'] = {
    bangumiBindingKey(binding.sourceKey, binding.comicId): binding.toJson(),
  };
}

void setBindings(Iterable<BangumiBinding> bindings) {
  appdata.settings['bangumiBindings'] = {
    for (final binding in bindings)
      bangumiBindingKey(binding.sourceKey, binding.comicId): binding.toJson(),
  };
}

BangumiSubject subject() => const BangumiSubject(
  id: 42,
  title: 'Title',
  originalTitle: 'Original',
  coverUrl: 'cover',
  totalEpisodes: 24,
  totalVolumes: 4,
);

BangumiCollection collection({
  int epStatus = 0,
  int volStatus = 3,
  int rate = 0,
  int type = 3,
}) => BangumiCollection(
  type: type,
  rate: rate,
  epStatus: epStatus,
  volStatus: volStatus,
);

BangumiBinding binding({
  int lastRemoteEpisode = 12,
  int lastRemoteVolume = 3,
  int rating = 6,
  BangumiCollectionStatus? collectionStatus = BangumiCollectionStatus.reading,
  int totalEpisodes = 24,
  int totalVolumes = 4,
}) => BangumiBinding(
  sourceKey: 'source',
  comicId: 'comic',
  subjectId: 42,
  subjectTitle: 'Title',
  subjectOriginalTitle: 'Original',
  coverUrl: 'cover',
  progressMode: BangumiProgressMode.episode,
  collectionStatus: collectionStatus,
  totalEpisodes: totalEpisodes,
  totalVolumes: totalVolumes,
  lastRemoteEpisode: lastRemoteEpisode,
  lastRemoteVolume: lastRemoteVolume,
  rating: rating,
);

BangumiBinding bindingForComic(String comicId) =>
    binding().copyWith(comicId: comicId);

class FakeBangumiGateway implements BangumiGateway {
  BangumiUser user = const BangumiUser('alice', 'Alice');
  List<BangumiSubject> searchResults = [];
  final Map<int, BangumiSubject> subjects = {};
  BangumiCollection? collection;
  Object? currentUserError;
  Object? createError;
  Object? patchError;
  Object? getCollectionError;
  Completer<void>? getCollectionBlocker;
  var currentUserCalls = 0;
  final searchKeywords = <String>[];
  final subjectCalls = <int>[];
  final collectionCalls = <(String, int)>[];
  final createFields = <(int, Map<String, dynamic>)>[];
  final patchFields = <Map<String, dynamic>>[];

  @override
  Future<BangumiUser> currentUser() async {
    currentUserCalls++;
    if (currentUserError != null) throw currentUserError!;
    return user;
  }

  @override
  Future<List<BangumiSubject>> searchSubjects(String keyword) async {
    searchKeywords.add(keyword);
    return searchResults;
  }

  @override
  Future<BangumiSubject> getSubject(int subjectId) async {
    subjectCalls.add(subjectId);
    return subjects[subjectId]!;
  }

  @override
  Future<BangumiCollection?> getCollection(
    String username,
    int subjectId,
  ) async {
    collectionCalls.add((username, subjectId));
    final blocker = getCollectionBlocker;
    if (blocker != null) {
      await blocker.future;
    }
    if (getCollectionError != null) throw getCollectionError!;
    return collection;
  }

  @override
  Future<void> createCollection(
    int subjectId,
    Map<String, dynamic> fields,
  ) async {
    createFields.add((subjectId, Map.of(fields)));
    if (createError != null) throw createError!;
    collection = BangumiCollection(
      type: fields['type'] as int,
      rate: 0,
      epStatus: fields['ep_status'] as int? ?? 0,
      volStatus: fields['vol_status'] as int? ?? 0,
    );
  }

  @override
  Future<void> patchCollection(
    int subjectId,
    Map<String, dynamic> fields,
  ) async {
    patchFields.add(Map.of(fields));
    if (patchError != null) throw patchError!;
    final current = collection!;
    collection = BangumiCollection(
      type: fields['type'] as int? ?? current.type,
      rate: fields['rate'] as int? ?? current.rate,
      epStatus: fields['ep_status'] as int? ?? current.epStatus,
      volStatus: fields['vol_status'] as int? ?? current.volStatus,
    );
  }
}

class RecordingTimer implements Timer {
  RecordingTimer(this.duration, this.callback);

  final Duration duration;
  final void Function() callback;
  var cancelled = false;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => 0;

  @override
  void cancel() {
    cancelled = true;
  }

  void fire() {
    if (!cancelled) {
      cancelled = true;
      callback();
    }
  }
}
