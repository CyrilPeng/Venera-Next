import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/foundation/app_language.dart';
import 'package:venera_next/foundation/app_locale.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/reader_preferences.dart';
import 'package:venera_next/foundation/translations.dart';

import '../support/ui_regression_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousLanguage = appdata.settings['language'];

  setUpAll(AppTranslation.init);
  setUpAll(loadUiRegressionFonts);
  setUp(() => appdata.settings['language'] = 'en-US');
  tearDown(() => appdata.settings['language'] = previousLanguage);

  test('bundled dictionaries cover the registered non-English languages', () {
    expect(AppTranslation.translations.keys.toSet(), {
      for (final language in AppLanguage.values)
        if (language != AppLanguage.english) language.translationKey,
    });
  });

  test('switching languages translates overwrite confirmation and fallback', () {
    const confirmation =
        'Local changes will be overwritten by the downloaded backup. Continue?';
    for (final (language, expected) in [
      ('zh-CN', '下载备份会覆盖本地修改，是否继续？'),
      ('zh-TW', '下載的備份將覆寫本機修改，是否繼續？'),
      (
        'de-DE',
        'Lokale Änderungen werden durch das heruntergeladene Backup überschrieben. Fortfahren?',
      ),
      ('ja-JP', 'ダウンロードしたバックアップでローカルの変更が上書きされます。続行しますか？'),
      ('en-US', confirmation),
      ('zh-CN', '下载备份会覆盖本地修改，是否继续？'),
    ]) {
      appdata.settings['language'] = language;
      expect(confirmation.tl, expected);
      expect('An unknown translation key'.tl, 'An unknown translation key');
    }
  });

  test('parameters replace complete tokens once and cover repeated uses', () {
    expect(
      '@a and @amount: @a / @unknown'.tlParams({'a': '@amount', 'amount': 10}),
      '@amount and 10: @amount / @unknown',
    );
    for (final language in AppLanguage.values) {
      appdata.settings['language'] = language.preference;
      expect('Page @page'.tlParams({'page': 12}), isNot(contains('@page')));
      expect('Page @page'.tlParams({'page': 12}), contains('12'));
    }
  });

  for (final language in [AppLanguage.german, AppLanguage.japanese]) {
    for (final scenario in [
      (size: const Size(375, 740), scale: 1.0, dark: false),
      (size: const Size(375, 740), scale: 2.0, dark: true),
      (size: const Size(740, 375), scale: 2.0, dark: true),
      (size: const Size(1024, 768), scale: 2.0, dark: false),
    ]) {
      testWidgets('localized settings and confirmation fit $language $scenario', (
        tester,
      ) async {
        appdata.settings['language'] = language.preference;
        tester.view.physicalSize = scenario.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final boundary = GlobalKey();
        const confirmation =
            'Local changes will be overwritten by the downloaded backup. Continue?';
        var confirmed = false;
        final prefix =
            '${language.translationKey}-${scenario.size.width.toInt()}-${scenario.scale}';
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              locale: language.locale,
              supportedLocales: AppLanguage.supportedLocales,
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
              ],
              theme: ThemeData(
                brightness: scenario.dark ? Brightness.dark : Brightness.light,
                fontFamily: uiRegressionFont,
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scenario.scale),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => ListView(
                    children: [
                      SelectSetting.preference(
                        title: 'Language'.tl,
                        preference: AppPreferences.language,
                        optionTranslation: {
                          ...AppLanguage.options,
                          'system': 'System'.tl,
                        },
                      ),
                      SelectSetting.reader(
                        title: 'Reading mode'.tl,
                        preference: ReaderPreferences.readerMode,
                        optionTranslation: {
                          'waterfallTopToBottom':
                              'Waterfall (Top to Bottom)'.tl,
                          'continuousTopToBottom':
                              'Continuous (Top to Bottom)'.tl,
                          'galleryRightToLeft': 'Gallery (Right to Left)'.tl,
                        },
                      ),
                      FilledButton(
                        onPressed: () => showConfirmDialog(
                          context: context,
                          title: 'Overwrite local data?'.tl,
                          content: confirmation.tl,
                          onConfirm: () => confirmed = true,
                        ),
                        child: Text('Restore'.tl),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final context = tester.element(find.byType(Scaffold));
        expect(Localizations.localeOf(context), language.locale);
        expect(appLocale, language.locale);
        expect(
          MaterialLocalizations.of(context).cancelButtonLabel,
          language == AppLanguage.german ? 'Abbrechen' : 'キャンセル',
        );
        await captureUiRegression(tester, boundary, '$prefix-settings');
        final field = find.widgetWithText(SelectSetting, 'Reading mode'.tl);
        final selector = find.descendant(
          of: field,
          matching: find.byType(Select),
        );
        await tester.tap(
          selector.evaluate().isEmpty
              ? find.descendant(of: field, matching: find.byType(ListTile))
              : selector,
        );
        await tester.pumpAndSettle();
        expect(find.text('Continuous (Top to Bottom)'.tl), findsOneWidget);
        expect(tester.takeException(), isNull);
        await captureUiRegression(tester, boundary, '$prefix-menu');
        Navigator.of(context).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Restore'.tl));
        await tester.pumpAndSettle();
        final body = find.text(confirmation.tl);
        expect(body, findsOneWidget);
        expect(
          tester
              .renderObject<RenderParagraph>(
                find.text('Overwrite local data?'.tl),
              )
              .didExceedMaxLines,
          isFalse,
        );
        expect(
          tester.renderObject<RenderParagraph>(body).didExceedMaxLines,
          isFalse,
        );
        expect(confirmed, isFalse);
        expect(tester.takeException(), isNull);
        await captureUiRegression(tester, boundary, '$prefix-confirmation');
        final confirm = find.widgetWithText(FilledButton, 'Confirm'.tl);
        await tester.ensureVisible(confirm);
        await tester.pumpAndSettle();
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(confirmed, isTrue);
        expect(find.byType(ContentDialog), findsNothing);
        expect(tester.takeException(), isNull);

        showDialog<void>(
          context: context,
          builder: (dialogContext) => ContentDialog(
            title: 'Restore'.tl,
            content: Text(confirmation.tl),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text('Cancel'.tl),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text('Restore'.tl),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final restore = find.descendant(
          of: find.byType(ContentDialog),
          matching: find.widgetWithText(FilledButton, 'Restore'.tl),
        );
        final restoreTitle = find
            .descendant(
              of: find.byType(ContentDialog),
              matching: find.text('Restore'.tl),
            )
            .first;
        expect(
          tester
              .renderObject<RenderParagraph>(restoreTitle)
              .text
              .style
              ?.fontFamily,
          uiRegressionFont,
        );
        await tester.ensureVisible(restore);
        await tester.pumpAndSettle();
        final dialogBounds = tester.getRect(find.byType(Dialog));
        final actionBounds = tester.getRect(restore);
        expect(actionBounds.left, greaterThanOrEqualTo(dialogBounds.left));
        expect(actionBounds.right, lessThanOrEqualTo(dialogBounds.right));
        await captureUiRegression(tester, boundary, '$prefix-restore-actions');
        await tester.tap(restore);
        await tester.pumpAndSettle();
        expect(find.byType(ContentDialog), findsNothing);
      });
    }
  }
}
