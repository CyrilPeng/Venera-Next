import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/keyword_match_preview.dart';
import 'package:venera_next/components/message.dart' show ContentDialog;
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/comic_widgets/comic_list.dart';
import 'package:venera_next/features/comic_widgets/comic_tile.dart';
import 'package:venera_next/features/settings/keyword_blocking.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/keyword_filter.dart';
import 'package:venera_next/foundation/keyword_settings_store.dart';
import 'package:venera_next/foundation/translations.dart';

const _wordKey = ValueKey('keyword-rule-word');
const _sampleKey = ValueKey('keyword-rule-sample');

Directory _prepare() {
  final root = Directory.systemTemp.createTempSync('keyword-rules-widget-');
  final oldPath = App.dataPath;
  final oldSettings =
      jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map;
  App.dataPath = root.path;
  appdata.settings['language'] = 'en-US';
  appdata.settings['disableSyncFields'] = '';
  appdata.settings['blockedWords'] = ['alpha'];
  appdata.settings['blockedCommentWords'] = ['comment'];
  appdata.settings['blockedWordRules'] = <String, String>{};
  appdata.settings['blockedCommentWordRules'] = <String, String>{};
  addTearDown(() {
    App.dataPath = oldPath;
    oldSettings.forEach((key, value) => appdata.settings[key] = value);
    root.deleteSync(recursive: true);
  });
  return root;
}

Map<String, dynamic> _saved(Directory root) =>
    (jsonDecode(File('${root.path}/appdata.json').readAsStringSync())
            as Map)['settings']
        as Map<String, dynamic>;

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

Future<void> _flush(WidgetTester tester, Future<void> operation) async {
  var done = false;
  Object? failure;
  operation.then(
    (_) => done = true,
    onError: (Object error) {
      failure = error;
      done = true;
    },
  );
  for (var i = 0; i < 500 && !done; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(done, isTrue);
  expect(failure, isNull);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _add(WidgetTester tester) async =>
    _tap(tester, find.text('Add'.tl));

Future<void> _mode(WidgetTester tester, String label) async {
  await _tap(tester, find.byType(DropdownButtonFormField<KeywordMatchMode>));
  await _tap(tester, find.text(label).last);
}

Future<void> _save(WidgetTester tester, {bool adding = false}) async {
  final button = find.widgetWithText(
    FilledButton,
    adding ? 'Add'.tl : 'Save'.tl,
  );
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
  await _flush(tester, appdata.saveData(false));
}

Future<void> _capture(WidgetTester tester, String name) async {
  final output = Platform.environment['KEYWORD_RULES_SCREENSHOTS'];
  if (output == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('keyword-rules-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$output/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

Comic _comic(String title) =>
    Comic(title, '', title, null, null, '', 'webdav_library', null, null);

void main() {
  App.dataPath = Directory.systemTemp.path;
  setUpAll(() async {
    await AppTranslation.init();
    final fontPath = Platform.environment['KEYWORD_RULES_FONT'];
    if (fontPath != null) {
      final loader = FontLoader('KeywordRulesPreview')
        ..addFont(
          Future.value(ByteData.sublistView(File(fontPath).readAsBytesSync())),
        );
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });

  testWidgets(
    'new abbreviation previews and persists independent matching across disk reload',
    (tester) async {
      final root = _prepare();
      await tester.pumpWidget(_host(const KeywordBlockingSettings()));
      await _add(tester);
      await tester.enterText(find.byKey(_wordKey), 'bl');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButtonFormField<KeywordMatchMode>>(
              find.byType(DropdownButtonFormField<KeywordMatchMode>),
            )
            .initialValue,
        KeywordMatchMode.wholeWord,
      );
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
      await _tap(tester, find.text('Test match'));
      await tester.enterText(find.byKey(_sampleKey), 'black and white');
      await tester.pumpAndSettle();
      expect(find.text('Will stay visible'), findsOneWidget);
      await tester.enterText(find.byKey(_sampleKey), '[BL] Story');
      await tester.pumpAndSettle();
      expect(find.text('Will be hidden'), findsOneWidget);
      final match = tester
          .widget<KeywordMatchPreview>(find.byType(KeywordMatchPreview))
          .match;
      expect(match.text.substring(match.start, match.end), 'BL');
      await _save(tester, adding: true);
      expect(_saved(root)['blockedWords'], ['alpha', 'bl']);
      expect(_saved(root)['blockedWordRules'], {'bl': 'wholeWord:insensitive'});
      appdata.settings['blockedWords'] = <String>[];
      appdata.settings['blockedWordRules'] = <String, String>{};
      await tester.runAsync(() => appdata.loadDataForTesting(root.path));
      final filter = KeywordFilter.fromSettings(appdata.settings);
      expect(filter.firstComicMatch(title: 'black', description: ''), isNull);
      expect(filter.firstComicMatch(title: '[BL]', description: ''), 'bl');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'saving an unchanged old rule preserves substring and case behavior',
    (tester) async {
      final root = _prepare();
      appdata.settings['blockedWords'] = ['bl'];
      await tester.pumpWidget(_host(const KeywordBlockingSettings()));
      await _tap(tester, find.widgetWithText(ListTile, 'bl'));
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      await _tap(tester, find.text('Test match'));
      await tester.enterText(find.byKey(_sampleKey), 'black');
      await tester.pumpAndSettle();
      expect(find.text('Will be hidden'), findsOneWidget);
      await _save(tester);
      expect(_saved(root)['blockedWordRules'], isEmpty);
      expect(isBlocked(_comic('black')), 'bl');
      expect(isBlocked(_comic('BLACK')), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'hidden reasons edit the actual rule on a narrow large-text screen and refresh the grid',
    (tester) async {
      _prepare();
      configureComicWidgets(
        keywordRuleEditor: (context, rule) => showKeywordRuleEditor(
          context,
          target: BlockedKeywordList.comics,
          rule: rule,
        ),
      );
      addTearDown(() => configureComicWidgets());
      appdata.settings['blockedWords'] = ['bl'];
      final comics = [
        _comic('black and white'),
        _comic('[bl] Story'),
        _comic('Other title'),
      ];
      tester.view.physicalSize = const Size(375, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: Platform.environment['KEYWORD_RULES_FONT'] == null
                ? null
                : 'KeywordRulesPreview',
          ),
          builder: (context, child) => RepaintBoundary(
            key: const ValueKey('keyword-rules-capture'),
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(1.8),
                disableAnimations: true,
              ),
              child: child!,
            ),
          ),
          home: Scaffold(
            body: CustomScrollView(slivers: [SliverGridComics(comics: comics)]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final hero = tester.widget<ComicTile>(find.byType(ComicTile)).heroID;
      await _tap(tester, find.text('Hidden by keyword filters: 2 comics'));
      expect(find.text('Keyword filter reasons'), findsOneWidget);
      expect(find.text('Keyword: bl'), findsWidgets);
      expect(find.text('Matched in Title'), findsWidgets);
      await _capture(tester, 'phone-reasons');
      expect(
        tester
            .widgetList<KeywordMatchPreview>(find.byType(KeywordMatchPreview))
            .first
            .match
            .rule
            .isLegacy,
        isTrue,
      );
      await _tap(tester, find.text('Edit rule').first);
      await _mode(tester, 'Whole word');
      await _tap(tester, find.byType(SwitchListTile));
      await _save(tester);
      expect(
        find.text('No comics in this list are hidden by keywords.'),
        findsNothing,
      );
      expect(isBlocked(comics[0]), isNull);
      expect(isBlocked(comics[1]), 'bl');
      await _tap(tester, find.widgetWithText(TextButton, 'Close'));
      expect(find.byType(ComicTile), findsNWidgets(2));
      expect(find.text('Hidden by keyword filters: 1 comics'), findsOneWidget);
      expect(
        tester
            .widgetList<ComicTile>(find.byType(ComicTile))
            .singleWhere((tile) => tile.comic.title == 'Other title')
            .heroID,
        hero,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final deleted in [false, true]) {
    testWidgets(
      'open editors reject changed or deleted rules: deleted=$deleted',
      (tester) async {
        final root = _prepare();
        appdata.settings['blockedWords'] = ['bl'];
        await tester.pumpWidget(_host(const KeywordBlockingSettings()));
        await _tap(tester, find.widgetWithText(ListTile, 'bl'));
        await _mode(tester, 'Whole word');
        if (deleted) {
          appdata.settings['blockedWords'] = ['keep'];
        } else {
          appdata.settings['blockedWordRules'] = {'bl': 'exactTag:insensitive'};
        }
        await _save(tester);
        expect(
          find.text('The rule changed. Close and reopen the editor.'),
          findsOneWidget,
        );
        expect(_saved(root)['blockedWords'], deleted ? ['keep'] : ['bl']);
        expect(
          _saved(root)['blockedWordRules'],
          deleted ? <String, String>{} : {'bl': 'exactTag:insensitive'},
        );
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
              .onPressed,
          isNull,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'reason editing retains the original reader save after its dialog is removed',
    (tester) async {
      final root = _prepare();
      final work = ImageWork();
      configureComicWidgets(
        keywordRuleEditor: (context, rule) => showKeywordRuleEditor(
          context,
          target: BlockedKeywordList.comics,
          rule: rule,
        ),
      );
      addTearDown(() => configureComicWidgets());
      appdata.settings['blockedWords'] = ['bl'];
      await tester.pumpWidget(
        _host(
          SettingsSaveScope(
            work: work,
            child: CustomScrollView(
              slivers: [
                SliverGridComics(comics: [_comic('black')]),
              ],
            ),
          ),
        ),
      );
      await _tap(tester, find.text('Hidden by keyword filters: 1 comics'));
      await _tap(tester, find.text('Edit rule'));
      await _mode(tester, 'Whole word');
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final exclusive = AppDataOperations.instance.run(() => release.future);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      var drained = false;
      final drain = work.prepareForExit().then((resume) {
        drained = true;
        resume();
      });
      final editor = tester.element(find.byType(KeywordRuleEditor));
      Navigator.of(editor).removeRoute(ModalRoute.of(editor)!);
      await tester.pumpAndSettle();
      final drainedEarly = drained;
      release.complete();
      await _flush(
        tester,
        Future.wait([exclusive, drain, appdata.saveData(false)]),
      );
      expect(drainedEarly, isFalse);
      expect(drained, isTrue);
      expect(_saved(root)['blockedWordRules'], {'bl': 'wholeWord:sensitive'});
      expect(find.text('Keyword filter reasons'), findsOneWidget);
      expect(
        find.text('No comics in this list are hidden by keywords.'),
        findsOneWidget,
      );
      expect(find.byType(ComicTile), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed additions retry both words and options without duplicates',
    (tester) async {
      final root = _prepare();
      await tester.pumpWidget(_host(const KeywordBlockingSettings()));
      await _add(tester);
      await tester.enterText(find.byKey(_wordKey), 'bl');
      await tester.pumpAndSettle();
      final blocked = Directory('${root.path}/appdata.json')..createSync();
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Add'));
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      for (var i = 0; i < 500 && find.text('Retry').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.text('Retry'), findsOneWidget);
      expect(appdata.settings['blockedWordRules'], {
        'bl': 'wholeWord:insensitive',
      });
      blocked.deleteSync();
      await tester.ensureVisible(find.text('Retry'));
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await _flush(tester, appdata.saveData(false));
      expect(_saved(root)['blockedWords'], ['alpha', 'bl']);
      expect(_saved(root)['blockedWordRules'], {'bl': 'wholeWord:insensitive'});
      expect(find.byType(KeywordRuleEditor), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'comment rules offer word matching and omit irrelevant tag matching',
    (tester) async {
      final root = _prepare();
      await tester.pumpWidget(
        _host(const KeywordBlockingSettings(comments: true)),
      );
      await _add(tester);
      await tester.enterText(find.byKey(_wordKey), 'BL');
      await tester.pumpAndSettle();
      await _tap(
        tester,
        find.byType(DropdownButtonFormField<KeywordMatchMode>),
      );
      expect(find.text('Exact tag'), findsNothing);
      expect(find.text('Contains text'), findsOneWidget);
      await _tap(tester, find.text('Whole word').last);
      await _tap(tester, find.text('Test match'));
      await tester.enterText(find.byKey(_sampleKey), 'black comment');
      await tester.pumpAndSettle();
      expect(find.text('Will stay visible'), findsOneWidget);
      await _save(tester, adding: true);
      expect(_saved(root)['blockedCommentWordRules'], {
        'BL': 'wholeWord:insensitive',
      });
      expect(
        KeywordFilter.fromSettings(
          appdata.settings,
          comments: true,
        ).blocksComment('black'),
        isFalse,
      );
      expect(
        KeywordFilter.fromSettings(
          appdata.settings,
          comments: true,
        ).blocksComment('[bl]'),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'sync exclusions and old imports preserve the intended matching policy',
    (tester) async {
      final root = _prepare();
      final store = KeywordSettingsStore(
        readSettings: () => appdata.settings,
        updateSettings: (change) => appdata.updateSettings(change),
      );
      await _flush(
        tester,
        store
            .saveRule(
              BlockedKeywordList.comics,
              const KeywordRule('bl', mode: KeywordMatchMode.wholeWord),
            )
            .then((_) {}),
      );
      appdata.settings['disableSyncFields'] = 'blockedWords';
      await _flush(
        tester,
        appdata.syncData({
          'settings': <String, dynamic>{
            'blockedWords': ['remote'],
            'blockedWordRules': {'bl': 'contains:insensitive'},
          },
        }),
      );
      expect(_saved(root)['blockedWords'], ['alpha', 'bl']);
      expect(_saved(root)['blockedWordRules'], {'bl': 'wholeWord:insensitive'});
      final sync =
          (jsonDecode(File('${root.path}/syncdata.json').readAsStringSync())
                  as Map)['settings']
              as Map;
      expect(sync.containsKey('blockedWords'), isFalse);
      expect(sync.containsKey('blockedWordRules'), isFalse);
      appdata.settings['disableSyncFields'] = '';
      await _flush(
        tester,
        appdata.syncData({
          'settings': <String, dynamic>{
            'blockedWords': ['bl'],
          },
        }),
      );
      expect(_saved(root)['blockedWordRules'], isEmpty);
      expect(isBlocked(_comic('black')), 'bl');
    },
  );

  for (final (name, size, scale, dark, insets) in [
    ('phone-light', const Size(375, 740), 1.0, false, 0.0),
    ('phone-dark-large', const Size(375, 740), 1.8, true, 0.0),
    ('landscape-large', const Size(740, 375), 2.0, false, 0.0),
    ('tablet-dark', const Size(834, 1112), 2.0, true, 0.0),
    ('phone-keyboard', const Size(375, 740), 1.0, false, 280.0),
  ]) {
    testWidgets('rule editing and previews fit $name with reduced motion', (
      tester,
    ) async {
      _prepare();
      appdata.settings['language'] = dark ? 'zh-CN' : 'en-US';
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
            fontFamily: Platform.environment['KEYWORD_RULES_FONT'] == null
                ? null
                : 'KeywordRulesPreview',
          ),
          builder: (context, child) => RepaintBoundary(
            key: const ValueKey('keyword-rules-capture'),
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
                padding: const EdgeInsets.only(top: 24, bottom: 24),
                viewInsets: EdgeInsets.only(bottom: insets),
              ),
              child: child!,
            ),
          ),
          home: const Scaffold(body: KeywordBlockingSettings()),
        ),
      );
      await _add(tester);
      expect(find.byTooltip('Close'.tl), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ContentDialog),
          matching: find.byType(AnimatedSize),
        ),
        findsNothing,
      );
      await tester.enterText(find.byKey(_wordKey), 'bl');
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Test match'.tl));
      await tester.ensureVisible(find.byKey(_sampleKey));
      await tester.enterText(find.byKey(_sampleKey), 'black and white');
      await tester.pumpAndSettle();
      expect(find.text('Will stay visible'.tl), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (insets == 0) await _capture(tester, name);
      await tester.enterText(find.byKey(_sampleKey), '[BL] Story');
      await tester.pumpAndSettle();
      expect(find.text('Will be hidden'.tl), findsOneWidget);
      if (name == 'phone-light') await _capture(tester, 'phone-highlight');
      final colors = Theme.of(
        tester.element(find.byType(KeywordMatchPreview)),
      ).colorScheme;
      final a = colors.primaryContainer.computeLuminance();
      final b = colors.onPrimaryContainer.computeLuminance();
      expect(
        ((a > b ? a : b) + 0.05) / ((a > b ? b : a) + 0.05),
        greaterThanOrEqualTo(4.5),
      );
      await _save(tester, adding: true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
