import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/bangumi/bangumi.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  group('BangumiTitleProgressParser', () {
    test('parses a Chinese episode title in auto mode', () {
      expect(
        BangumiTitleProgressParser.parse('第 12 话', BangumiProgressMode.auto),
        const BangumiTitleParseResult.success(
          BangumiProgress(BangumiProgressField.episode, 12),
        ),
      );
    });

    test('parses full-width volume digits in auto mode', () {
      expect(
        BangumiTitleProgressParser.parse('第３卷', BangumiProgressMode.auto),
        const BangumiTitleParseResult.success(
          BangumiProgress(BangumiProgressField.volume, 3),
        ),
      );
    });

    test('uses volume mode for Vol. titles', () {
      expect(
        BangumiTitleProgressParser.parse('Vol. 8', BangumiProgressMode.volume),
        const BangumiTitleParseResult.success(
          BangumiProgress(BangumiProgressField.volume, 8),
        ),
      );
    });

    test('rejects multiple fallback numbers in Vol. titles', () {
      expect(
        BangumiTitleProgressParser.parse(
          'Vol. 8 extra 9',
          BangumiProgressMode.volume,
        ),
        const BangumiTitleParseResult.failure(
          BangumiTitleParseFailure.ambiguous,
        ),
      );
    });

    test('uses the requested field when a title contains both units', () {
      expect(
        BangumiTitleProgressParser.parse(
          '第 12 卷 第 63 话',
          BangumiProgressMode.episode,
        ),
        const BangumiTitleParseResult.success(
          BangumiProgress(BangumiProgressField.episode, 63),
        ),
      );
      expect(
        BangumiTitleProgressParser.parse(
          '第 12 卷 第 63 话',
          BangumiProgressMode.volume,
        ),
        const BangumiTitleParseResult.success(
          BangumiProgress(BangumiProgressField.volume, 12),
        ),
      );
    });

    test('rejects ambiguous auto titles', () {
      expect(
        BangumiTitleProgressParser.parse(
          '第 12 卷 第 63 话',
          BangumiProgressMode.auto,
        ),
        const BangumiTitleParseResult.failure(
          BangumiTitleParseFailure.ambiguous,
        ),
      );
    });

    test('rejects decimal and negative progress', () {
      expect(
        BangumiTitleProgressParser.parse('第 12.5 话', BangumiProgressMode.auto),
        const BangumiTitleParseResult.failure(BangumiTitleParseFailure.decimal),
      );
      expect(
        BangumiTitleProgressParser.parse('-3 话', BangumiProgressMode.auto),
        const BangumiTitleParseResult.failure(
          BangumiTitleParseFailure.negative,
        ),
      );
    });

    test('rejects titles without Arabic numbers', () {
      expect(
        BangumiTitleProgressParser.parse('番外', BangumiProgressMode.episode),
        const BangumiTitleParseResult.failure(
          BangumiTitleParseFailure.noNumber,
        ),
      );
      expect(
        BangumiTitleProgressParser.parse('第十二话', BangumiProgressMode.auto),
        const BangumiTitleParseResult.failure(
          BangumiTitleParseFailure.noNumber,
        ),
      );
    });

    test('rejects multiple values associated with the same unit', () {
      expect(
        BangumiTitleProgressParser.parse('12卷13', BangumiProgressMode.volume),
        const BangumiTitleParseResult.failure(
          BangumiTitleParseFailure.ambiguous,
        ),
      );
    });
  });

  test('BangumiTitleParseResult exposes its failure', () {
    const result = BangumiTitleParseResult.failure(
      BangumiTitleParseFailure.noNumber,
    );

    expect(result.failure, BangumiTitleParseFailure.noNumber);
  });

  test(
    'BangumiBinding round-trips through JSON and creates an escaped key',
    () {
      const binding = BangumiBinding(
        sourceKey: 'source',
        comicId: 'comic/1',
        subjectId: 42,
        subjectTitle: '标题',
        subjectOriginalTitle: 'Original',
        coverUrl: 'https://example.com/cover.jpg',
        progressMode: BangumiProgressMode.volume,
        totalEpisodes: 12,
        totalVolumes: 3,
        lastRemoteEpisode: 10,
        lastRemoteVolume: 2,
        rating: 8,
      );

      expect(BangumiBinding.fromJson(binding.toJson()), binding);
      expect(
        bangumiBindingKey(binding.sourceKey, binding.comicId),
        'source@comic%2F1',
      );
      expect(
        BangumiBinding.fromJson({
          ...binding.toJson(),
          'progressMode': 'future-mode',
        }).progressMode,
        BangumiProgressMode.auto,
      );
      expect(
        BangumiBinding.fromJson({
          ...binding.toJson(),
          'progressMode': 1,
        }).progressMode,
        BangumiProgressMode.auto,
      );
    },
  );

  test('Bangumi model JSON mappings use expected values and defaults', () {
    const user = BangumiUser('user', '昵称');
    expect(BangumiUser.fromJson(user.toJson()), user);

    final subject = BangumiSubject.fromJson({
      'id': 1,
      'name': 'Original',
      'name_cn': '中文',
      'images': {'common': 'cover'},
      'eps': 24,
      'volumes': 4,
      'platform': 'TV',
    });
    expect(subject.toJson(), {
      'id': 1,
      'title': '中文',
      'originalTitle': 'Original',
      'coverUrl': 'cover',
      'totalEpisodes': 24,
      'totalVolumes': 4,
      'platform': 'TV',
    });
    expect(BangumiCollection.fromJson({}).toJson(), {
      'type': 0,
      'rate': 0,
      'epStatus': 0,
      'volStatus': 0,
    });
    expect(
      BangumiSubject.fromJson({'id': 2, 'name': 'No platform'}).platform,
      isNull,
    );

    const localSubject = BangumiSubject(
      id: 3,
      title: '中文标题',
      originalTitle: 'Original title',
      coverUrl: 'https://example.com/cover.jpg',
      totalEpisodes: 24,
      totalVolumes: 4,
      platform: 'TV',
    );
    final restoredSubject = BangumiSubject.fromJson(localSubject.toJson());
    expect(restoredSubject.id, localSubject.id);
    expect(restoredSubject.title, localSubject.title);
    expect(restoredSubject.originalTitle, localSubject.originalTitle);
    expect(restoredSubject.coverUrl, localSubject.coverUrl);
    expect(restoredSubject.totalEpisodes, localSubject.totalEpisodes);
    expect(restoredSubject.totalVolumes, localSubject.totalVolumes);
    expect(restoredSubject.platform, localSubject.platform);

    const localCollection = BangumiCollection(
      type: 2,
      rate: 8,
      epStatus: 12,
      volStatus: 3,
    );
    final restoredCollection = BangumiCollection.fromJson(
      localCollection.toJson(),
    );
    expect(restoredCollection.type, localCollection.type);
    expect(restoredCollection.rate, localCollection.rate);
    expect(restoredCollection.epStatus, localCollection.epStatus);
    expect(restoredCollection.volStatus, localCollection.volStatus);
  });

  test('Bangumi settings have defaults', () {
    expect(appdata.settings['bangumiAccessToken'], '');
    expect(appdata.settings['bangumiUsername'], '');
    expect(appdata.settings['bangumiAutoSyncEnabled'], isTrue);
    expect(
      appdata.settings['bangumiBindings'],
      isA<Map<String, Map<String, dynamic>>>(),
    );
  });
}
