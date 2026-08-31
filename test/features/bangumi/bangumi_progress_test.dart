import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/bangumi/bangumi.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/translations.dart';

void main() {
  late _Gateway gateway;

  setUp(() {
    appdata.settings['bangumiAccessToken'] = 'token';
    appdata.settings['bangumiUsername'] = 'alice';
    appdata.settings['bangumiBindings'] = <String, dynamic>{};
    gateway = _Gateway();
  });

  testWidgets('unconnected panel explains that Bangumi must be connected', (
    tester,
  ) async {
    appdata.settings['bangumiAccessToken'] = '';
    appdata.settings['bangumiUsername'] = '';
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiProgressPanel(
          service: BangumiService.forTesting(
            gatewayFactory: (_) => throw StateError('disconnected'),
          ),
          sourceKey: 'source',
          comicId: 'comic',
          comicTitle: 'Title',
          chapters: const ComicChapters({'1': '第 1 话'}),
          history: null,
        ),
      ),
    );

    expect(find.text('Connect Bangumi in Settings first'), findsOneWidget);
  });

  test(
    'parser failure template translates its reason in Simplified Chinese',
    () {
      final oldLanguage = appdata.settings['language'];
      final oldTranslations = AppTranslation.translations;
      addTearDown(() {
        appdata.settings['language'] = oldLanguage;
        AppTranslation.translations = oldTranslations;
      });
      final data =
          jsonDecode(File('assets/translation.json').readAsStringSync())
              as Map<String, dynamic>;
      AppTranslation.translations = {
        for (final entry in data.entries)
          entry.key: Map<String, String>.from(entry.value as Map),
      };
      appdata.settings['language'] = 'zh-CN';
      expect(
        'Chapter title cannot be parsed: @reason'.tlParams({
          'reason': 'Decimal chapter number'.tl,
        }),
        '章节标题无法解析：小数章节号',
      );
      expect('Status'.tl, '状态');
      expect('Plan to read'.tl, '想读');
      expect('Currently reading'.tl, '在读');
      expect('Finished reading'.tl, '读过');
      expect('On hold'.tl, '搁置');
      expect('Dropped'.tl, '抛弃');
      appdata.settings['language'] = 'zh-TW';
      expect('Status'.tl, '狀態');
      expect('Plan to read'.tl, '想讀');
      expect('Currently reading'.tl, '在讀');
      expect('Finished reading'.tl, '讀過');
      expect('On hold'.tl, '擱置');
      expect('Dropped'.tl, '拋棄');
    },
  );

  testWidgets(
    'search starts with the comic title and numeric query fetches subject',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: BangumiProgressPanel(
            service: BangumiService.forTesting(gatewayFactory: (_) => gateway),
            sourceKey: 'source',
            comicId: 'comic',
            comicTitle: 'Title',
            chapters: const ComicChapters({'1': '第 1 话'}),
            history: null,
          ),
        ),
      );

      expect(find.text('Title'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('bangumi-subject-query')),
        '42',
      );
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      expect(gateway.subjectIds, [42]);
      expect(find.text('Book'), findsWidgets);
    },
  );

  testWidgets('keyword query delegates to subject search', (tester) async {
    await tester.pumpWidget(_panel(gateway));
    await tester.enterText(
      find.byKey(const Key('bangumi-subject-query')),
      'keyword',
    );
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    expect(gateway.searches, ['keyword']);
    expect(gateway.subjectIds, isEmpty);
  });

  testWidgets('binding exposes editable progress and rating', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiProgressPanel(
          service: BangumiService.forTesting(gatewayFactory: (_) => gateway),
          sourceKey: 'source',
          comicId: 'comic',
          comicTitle: 'Title',
          chapters: const ComicChapters({'1': '第 1 话'}),
          history: null,
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bangumi-bind')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('bangumi-progress-field')), findsOneWidget);
    expect(find.byKey(const Key('bangumi-rating-field')), findsOneWidget);
    expect(find.byKey(const Key('bangumi-status')), findsOneWidget);
  });

  testWidgets('bound panel exposes all Bangumi book statuses', (tester) async {
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): _binding().toJson(),
    };
    await tester.pumpWidget(_panel(gateway));

    expect(find.text('Currently reading'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bangumi-status')));
    await tester.pumpAndSettle();

    for (final label in [
      'Plan to read',
      'Currently reading',
      'Finished reading',
      'On hold',
      'Dropped',
    ]) {
      expect(find.text(label), findsWidgets);
    }
  });

  testWidgets('selected status is submitted with the existing save action', (
    tester,
  ) async {
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): _binding().toJson(),
    };
    await tester.pumpWidget(_panel(gateway));
    await tester.tap(find.byKey(const Key('bangumi-status')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('On hold').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bangumi-save')));
    await tester.pumpAndSettle();

    expect(gateway.patches, [
      {'type': 4},
    ]);
    expect(find.text('On hold'), findsOneWidget);
    expect(
      BangumiService.forTesting(
        gatewayFactory: (_) => gateway,
      ).bindingFor('source', 'comic')?.collectionStatus,
      BangumiCollectionStatus.onHold,
    );
  });

  testWidgets('sync now refreshes the displayed status', (tester) async {
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): _binding().toJson(),
    };
    gateway.collection = const BangumiCollection(
      type: 5,
      rate: 0,
      epStatus: 0,
      volStatus: 0,
    );
    await tester.pumpWidget(_panel(gateway));
    await tester.tap(find.byKey(const Key('bangumi-sync-now')));
    await tester.pumpAndSettle();

    expect(find.text('Dropped'), findsOneWidget);
  });

  testWidgets('legacy binding fetches its missing status once', (tester) async {
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): _binding(
        collectionStatus: null,
      ).toJson(),
    };
    gateway.collection = const BangumiCollection(
      type: 4,
      rate: 0,
      epStatus: 0,
      volStatus: 0,
    );
    await tester.pumpWidget(_panel(gateway));
    await tester.pumpAndSettle();

    expect(gateway.collectionRequests, 1);
    expect(find.text('On hold'), findsOneWidget);
  });

  testWidgets('selected volume mode is passed to binding', (tester) async {
    await tester.pumpWidget(_panel(gateway));
    await tester.tap(find.byKey(const Key('bangumi-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Volume').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bangumi-bind')));
    await tester.pumpAndSettle();

    expect(
      BangumiService.forTesting(
        gatewayFactory: (_) => gateway,
      ).bindingFor('source', 'comic')?.progressMode,
      BangumiProgressMode.volume,
    );
  });

  testWidgets('bound panel saves an episode progress and rating', (
    tester,
  ) async {
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): _binding().toJson(),
    };
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiProgressPanel(
          service: BangumiService.forTesting(gatewayFactory: (_) => gateway),
          sourceKey: 'source',
          comicId: 'comic',
          comicTitle: 'Title',
          chapters: const ComicChapters({'1': '第 1 话'}),
          history: null,
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('bangumi-progress-field')),
      '5',
    );
    await tester.enterText(find.byKey(const Key('bangumi-rating-field')), '8');
    await tester.tap(find.byKey(const Key('bangumi-save')));
    await tester.pumpAndSettle();

    expect(gateway.patches, [
      {'ep_status': 5, 'rate': 8},
    ]);
  });

  testWidgets('rebind returns an existing binding to the search form', (
    tester,
  ) async {
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): _binding().toJson(),
    };
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiProgressPanel(
          service: BangumiService.forTesting(gatewayFactory: (_) => gateway),
          sourceKey: 'source',
          comicId: 'comic',
          comicTitle: 'Title',
          chapters: const ComicChapters({'1': '第 1 话'}),
          history: null,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('bangumi-rebind')));
    await tester.pump();

    expect(find.byKey(const Key('bangumi-subject-query')), findsOneWidget);
    expect(find.byKey(const Key('bangumi-progress-field')), findsNothing);
  });

  testWidgets('auto mode with an ambiguous title still saves rating only', (
    tester,
  ) async {
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): _binding(
        mode: BangumiProgressMode.auto,
        episode: 3,
        volume: 1,
      ).toJson(),
    };
    await tester.pumpWidget(
      _panel(gateway, chapters: const ComicChapters({'1': '第 1 卷 第 3 话'})),
    );

    expect(find.textContaining('Episodes: 12'), findsOneWidget);
    expect(find.textContaining('Volumes: 2'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('bangumi-progress-field')))
          .enabled,
      isFalse,
    );
    await tester.enterText(find.byKey(const Key('bangumi-rating-field')), '8');
    await tester.tap(find.byKey(const Key('bangumi-save')));
    await tester.pumpAndSettle();
    expect(gateway.patches, [
      {'rate': 8},
    ]);
  });

  testWidgets(
    'summary shows book totals while current chapter shows local progress',
    (tester) async {
      appdata.settings['bangumiBindings'] = {
        bangumiBindingKey('source', 'comic'): _binding(
          episode: 3,
          volume: 1,
        ).toJson(),
      };
      await tester.pumpWidget(
        MaterialApp(
          home: BangumiProgressPanel(
            service: BangumiService.forTesting(gatewayFactory: (_) => gateway),
            sourceKey: 'source',
            comicId: 'comic',
            comicTitle: 'Title',
            chapters: const ComicChapters({'chapter': '第 5 话'}),
            history: _history(ep: 1, page: 1, maxPage: 1),
          ),
        ),
      );

      expect(find.textContaining('Episodes: 12'), findsOneWidget);
      expect(find.textContaining('Volumes: 2'), findsOneWidget);
      expect(find.text('Current chapter: 5 (Episode)'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('bangumi-progress-field')))
            .controller!
            .text,
        '3',
      );
    },
  );

  testWidgets('explicit mode saves only an edited rating', (tester) async {
    gateway.collection = const BangumiCollection(
      type: 3,
      rate: 6,
      epStatus: 8,
      volStatus: 0,
    );
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): _binding(
        episode: 5,
        rating: 6,
      ).toJson(),
    };
    await tester.pumpWidget(_panel(gateway));

    await tester.enterText(find.byKey(const Key('bangumi-rating-field')), '9');
    await tester.tap(find.byKey(const Key('bangumi-save')));
    await tester.pumpAndSettle();

    expect(find.text('Lower Bangumi progress?'), findsNothing);
    expect(gateway.patches, [
      {'rate': 9},
    ]);
  });

  testWidgets('rating-only save keeps pending progress in explicit mode', (
    tester,
  ) async {
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): _binding(
        episode: 5,
        rating: 6,
      ).toJson(),
    };
    gateway.collection = const BangumiCollection(
      type: 3,
      rate: 6,
      epStatus: 5,
      volStatus: 0,
    );
    final key = bangumiBindingKey('source', 'comic');
    final service = BangumiService.forTesting(
      gatewayFactory: (_) => gateway,
      implicitData: {
        'bangumiPendingProgress': {
          key: {
            'ep_status': {
              'field': 'ep_status',
              'subjectId': 42,
              'username': 'alice',
              'value': 10,
              'attempts': 0,
              'nextAttemptAt': DateTime.now().millisecondsSinceEpoch,
            },
          },
        },
      },
    );
    await tester.pumpWidget(_panelWithService(service));

    await tester.enterText(find.byKey(const Key('bangumi-rating-field')), '8');
    await tester.tap(find.byKey(const Key('bangumi-save')));
    await tester.pumpAndSettle();

    expect(gateway.patches, [
      {'rate': 8},
    ]);
    expect(service.hasPendingProgress('source', 'comic'), isTrue);
  });

  testWidgets('progress-only save does not overwrite a newer remote rating', (
    tester,
  ) async {
    gateway.collection = const BangumiCollection(
      type: 3,
      rate: 9,
      epStatus: 5,
      volStatus: 0,
    );
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): _binding(
        episode: 5,
        rating: 6,
      ).toJson(),
    };
    await tester.pumpWidget(_panel(gateway));

    await tester.enterText(
      find.byKey(const Key('bangumi-progress-field')),
      '7',
    );
    await tester.tap(find.byKey(const Key('bangumi-save')));
    await tester.pumpAndSettle();

    expect(gateway.patches, [
      {'ep_status': 7},
    ]);
  });

  testWidgets('unbinding deletes only the local binding', (tester) async {
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): _binding().toJson(),
    };
    await tester.pumpWidget(_panel(gateway));
    await tester.ensureVisible(find.byKey(const Key('bangumi-unbind')));
    await tester.tap(find.byKey(const Key('bangumi-unbind')));
    await tester.pumpAndSettle();

    expect(gateway.patches, isEmpty);
    expect(appdata.settings['bangumiBindings'], isEmpty);
  });

  testWidgets('confirmed manual decrease retries with explicit approval', (
    tester,
  ) async {
    gateway.collection = const BangumiCollection(
      type: 3,
      rate: 0,
      epStatus: 10,
      volStatus: 0,
    );
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): _binding(episode: 10).toJson(),
    };
    await tester.pumpWidget(_panel(gateway));
    await tester.enterText(
      find.byKey(const Key('bangumi-progress-field')),
      '5',
    );
    await tester.tap(find.byKey(const Key('bangumi-save')));
    await tester.pumpAndSettle();
    expect(find.text('Lower Bangumi progress?'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    expect(gateway.patches, [
      {'ep_status': 5},
    ]);
  });

  testWidgets('sync now retries the binding queue then refreshes', (
    tester,
  ) async {
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): _binding().toJson(),
    };
    await tester.pumpWidget(_panel(gateway));
    await tester.tap(find.byKey(const Key('bangumi-sync-now')));
    await tester.pumpAndSettle();

    expect(gateway.collectionRequests, 1);
  });

  testWidgets(
    'binding uses only a completed grouped chapter for local progress',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: BangumiProgressPanel(
            service: BangumiService.forTesting(gatewayFactory: (_) => gateway),
            sourceKey: 'source',
            comicId: 'comic',
            comicTitle: 'Title',
            chapters: const ComicChapters.grouped({
              'g1': {'1': '第 1 话'},
              'g2': {'2': '第 2 话'},
            }),
            history: _history(ep: 1, group: 2, page: 5, maxPage: 5),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bangumi-bind')));
      await tester.pumpAndSettle();

      expect(gateway.patches, [
        {'ep_status': 2},
      ]);
    },
  );

  testWidgets('binding ignores a flat chapter that is not at its last page', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiProgressPanel(
          service: BangumiService.forTesting(gatewayFactory: (_) => gateway),
          sourceKey: 'source',
          comicId: 'comic',
          comicTitle: 'Title',
          chapters: const ComicChapters({'1': '第 1 话'}),
          history: _history(ep: 1, page: 4, maxPage: 5),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bangumi-bind')));
    await tester.pumpAndSettle();

    expect(gateway.patches, isEmpty);
  });

  testWidgets('binding ignores an empty chapter history at page zero', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiProgressPanel(
          service: BangumiService.forTesting(gatewayFactory: (_) => gateway),
          sourceKey: 'source',
          comicId: 'comic',
          comicTitle: 'Title',
          chapters: const ComicChapters({'1': '第 1 话'}),
          history: _history(ep: 1, page: 0, maxPage: 0),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bangumi-bind')));
    await tester.pumpAndSettle();

    expect(gateway.patches, isEmpty);
  });

  testWidgets('binding ignores chapter history past its last page', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiProgressPanel(
          service: BangumiService.forTesting(gatewayFactory: (_) => gateway),
          sourceKey: 'source',
          comicId: 'comic',
          comicTitle: 'Title',
          chapters: const ComicChapters({'1': '第 1 话'}),
          history: _history(ep: 1, page: 6, maxPage: 5),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bangumi-bind')));
    await tester.pumpAndSettle();

    expect(gateway.patches, isEmpty);
  });

  testWidgets('bound panel displays a specific parser failure', (tester) async {
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): _binding().toJson(),
    };
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiProgressPanel(
          service: BangumiService.forTesting(gatewayFactory: (_) => gateway),
          sourceKey: 'source',
          comicId: 'comic',
          comicTitle: 'Title',
          chapters: const ComicChapters({'1': '第 12.5 话'}),
          history: _history(ep: 1, page: 5, maxPage: 5),
        ),
      ),
    );

    expect(find.textContaining('Decimal chapter number'), findsOneWidget);
  });

  testWidgets(
    'bound explicit mode explains when current title is unavailable',
    (tester) async {
      appdata.settings['bangumiBindings'] = {
        bangumiBindingKey('source', 'comic'): _binding().toJson(),
      };
      await tester.pumpWidget(_panel(gateway));
      expect(find.text('Current chapter title is unavailable'), findsOneWidget);
    },
  );

  testWidgets('out of range grouped chapter does not use a later group', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiProgressPanel(
          service: BangumiService.forTesting(gatewayFactory: (_) => gateway),
          sourceKey: 'source',
          comicId: 'comic',
          comicTitle: 'Title',
          chapters: const ComicChapters.grouped({
            'g1': {'1': '第 1 话'},
            'g2': {'2': '第 9 话'},
          }),
          history: _history(ep: 2, group: 1, page: 5, maxPage: 5),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bangumi-bind')));
    await tester.pumpAndSettle();

    expect(gateway.patches, isEmpty);
  });

  testWidgets('pending progress is shown and disappears after sync', (
    tester,
  ) async {
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): _binding().toJson(),
    };
    final implicit = <String, dynamic>{
      'bangumiPendingProgress': {
        bangumiBindingKey('source', 'comic'): {
          'ep_status': {
            'field': 'ep_status',
            'subjectId': 42,
            'username': 'alice',
            'value': 1,
            'attempts': 0,
            'nextAttemptAt': DateTime.now().millisecondsSinceEpoch,
          },
        },
      },
    };
    final service = BangumiService.forTesting(
      gatewayFactory: (_) => gateway,
      implicitData: implicit,
    );
    await tester.pumpWidget(_panelWithService(service));
    expect(find.text('Bangumi progress is waiting to retry'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bangumi-sync-now')));
    await tester.pumpAndSettle();
    expect(find.text('Bangumi progress is waiting to retry'), findsNothing);
    expect(service.hasPendingProgress('source', 'comic'), isFalse);
  });

  testWidgets('failed mode save restores the displayed mode', (tester) async {
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): _binding().toJson(),
    };
    final service = BangumiService.forTesting(
      gatewayFactory: (_) => gateway,
      saveSettings: () async => throw StateError('save failed'),
    );
    await tester.pumpWidget(_panelWithService(service));
    await tester.tap(find.byKey(const Key('bangumi-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Volume').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButtonFormField<BangumiProgressMode>>(
            find.byType(DropdownButtonFormField<BangumiProgressMode>),
          )
          .initialValue,
      BangumiProgressMode.episode,
    );
    expect(
      service.bindingFor('source', 'comic')!.progressMode,
      BangumiProgressMode.episode,
    );
  });

  testWidgets('double search while a request is pending starts one request', (
    tester,
  ) async {
    gateway.searchCompleter = Completer<List<BangumiSubject>>();
    await tester.pumpWidget(_panel(gateway));
    await tester.tap(find.byIcon(Icons.search));
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    expect(gateway.searches, ['Title']);
    gateway.searchCompleter!.complete([_Gateway.subject]);
    await tester.pumpAndSettle();
  });

  testWidgets('refresh missing collection displays a local error', (
    tester,
  ) async {
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): _binding().toJson(),
    };
    gateway.collection = null;
    await tester.pumpWidget(_panel(gateway));
    await tester.tap(find.byKey(const Key('bangumi-sync-now')));
    await tester.pumpAndSettle();
    expect(find.text('Bangumi collection no longer exists'), findsOneWidget);
  });
}

History _history({
  required int ep,
  int? group,
  required int page,
  required int maxPage,
}) {
  final history = History.fromMap({
    'type': 0,
    'time': 0,
    'title': 'Title',
    'subtitle': '',
    'cover': '',
    'ep': ep,
    'page': page,
    'id': 'comic',
    'readEpisode': <String>[],
    'max_page': maxPage,
    'read_duration_ms': 0,
  });
  history.group = group;
  return history;
}

Widget _panel(_Gateway gateway, {ComicChapters? chapters}) => MaterialApp(
  home: BangumiProgressPanel(
    service: BangumiService.forTesting(gatewayFactory: (_) => gateway),
    sourceKey: 'source',
    comicId: 'comic',
    comicTitle: 'Title',
    chapters: chapters ?? const ComicChapters({'1': '第 1 话'}),
    history: null,
  ),
);

Widget _panelWithService(BangumiService service) => MaterialApp(
  home: BangumiProgressPanel(
    service: service,
    sourceKey: 'source',
    comicId: 'comic',
    comicTitle: 'Title',
    chapters: const ComicChapters({'1': '第 1 话'}),
    history: null,
  ),
);

BangumiBinding _binding({
  BangumiProgressMode mode = BangumiProgressMode.episode,
  int episode = 0,
  int volume = 0,
  int rating = 0,
  BangumiCollectionStatus? collectionStatus = BangumiCollectionStatus.reading,
}) => BangumiBinding(
  sourceKey: 'source',
  comicId: 'comic',
  subjectId: 42,
  subjectTitle: 'Book',
  subjectOriginalTitle: 'Original',
  coverUrl: '',
  progressMode: mode,
  collectionStatus: collectionStatus,
  totalEpisodes: 12,
  totalVolumes: 2,
  lastRemoteEpisode: episode,
  lastRemoteVolume: volume,
  rating: rating,
);

class _Gateway implements BangumiGateway {
  final subjectIds = <int>[];
  final searches = <String>[];
  final patches = <Map<String, dynamic>>[];
  Completer<List<BangumiSubject>>? searchCompleter;
  var collectionRequests = 0;
  BangumiCollection? collection = const BangumiCollection(
    type: 3,
    rate: 0,
    epStatus: 0,
    volStatus: 0,
  );

  static const subject = BangumiSubject(
    id: 42,
    title: 'Book',
    originalTitle: 'Original',
    coverUrl: '',
    totalEpisodes: 12,
    totalVolumes: 2,
    platform: '漫画',
  );

  @override
  Future<void> createCollection(
    int subjectId,
    Map<String, dynamic> fields,
  ) async {}

  @override
  Future<BangumiCollection?> getCollection(
    String username,
    int subjectId,
  ) async {
    collectionRequests++;
    return collection;
  }

  @override
  Future<BangumiSubject> getSubject(int subjectId) async {
    subjectIds.add(subjectId);
    return subject;
  }

  @override
  Future<void> patchCollection(
    int subjectId,
    Map<String, dynamic> fields,
  ) async {
    patches.add(fields);
    collection = BangumiCollection(
      type: fields['type'] as int? ?? collection!.type,
      rate: fields['rate'] as int? ?? collection!.rate,
      epStatus: fields['ep_status'] as int? ?? collection!.epStatus,
      volStatus: fields['vol_status'] as int? ?? collection!.volStatus,
    );
  }

  @override
  Future<BangumiUser> currentUser() async =>
      const BangumiUser('alice', 'Alice');

  @override
  Future<List<BangumiSubject>> searchSubjects(String keyword) async {
    searches.add(keyword);
    if (searchCompleter != null) return searchCompleter!.future;
    return [subject];
  }
}
