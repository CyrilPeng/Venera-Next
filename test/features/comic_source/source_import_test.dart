import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/source_import.dart';
import 'package:venera_next/features/comic_source/source_import_dialog.dart';
import 'package:venera_next/features/comic_source/source_installation.dart';
import 'package:venera_next/foundation/appdata.dart';

String catalog(String target) => jsonEncode([
  {'key': 'one', 'name': 'Source One', 'version': '1.0.0', 'fileName': target},
]);

void main() {
  test(
    'URL detection uses the redirected address for relative catalog scripts',
    () async {
      final client = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                Response<String>(
                  requestOptions: options,
                  statusCode: 200,
                  data: catalog('one.js'),
                  redirects: [
                    RedirectRecord(
                      302,
                      'GET',
                      Uri.parse('https://cdn.test/repo/index'),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      final preview = await SourceImportPreview.fromUrl(
        'https://example.test/no-extension',
        client: client,
      );
      expect(preview.url, 'https://cdn.test/repo/index');
      expect(
        preview.catalog!.entries.single.url,
        'https://cdn.test/repo/one.js',
      );
      client.close();
    },
  );

  test(
    'content determines type regardless of extension and never executes JS',
    () {
      final script = SourceImportPreview.parse(
        'throw new Error("must not execute");\nclass Demo extends ComicSource {}',
        url: 'https://example.test/catalog.json',
      );
      expect(script.catalog, isNull);
      expect(script.name, 'Demo');
      final list = SourceImportPreview.parse(
        '\uFEFF${catalog('one.js')}',
        url: 'https://example.test/repo/list.js',
      );
      expect(
        list.catalog!.entries.single.url,
        'https://example.test/repo/one.js',
      );
    },
  );

  test(
    'local JSON supports absolute links and asks for a base for relative paths',
    () {
      expect(
        SourceImportPreview.parse(
          catalog('https://example.test/one.js'),
        ).catalog!.entries,
        hasLength(1),
      );
      expect(
        () => SourceImportPreview.parse(catalog('one.js')),
        throwsA(isA<SourceImportNeedsBaseUrl>()),
      );
      final preview = SourceImportPreview.parse(
        catalog('../one.js'),
        baseUrl: 'https://example.test/repo/index.json',
      );
      expect(preview.url, isNull);
      expect(
        preview.catalog!.entries.single.url,
        'https://example.test/one.js',
      );
    },
  );

  for (final invalid in [
    '<html>error</html>',
    '{"error":"forbidden"}',
    '[broken json',
    '',
  ]) {
    test('unsupported input is rejected without installing: $invalid', () {
      expect(() => SourceImportPreview.parse(invalid), throwsA(isA<String>()));
    });
  }

  testWidgets(
    'invalid base URL remains editable when importing relative JSON',
    (tester) async {
      final previousLanguage = appdata.settings['language'];
      appdata.settings['language'] = 'en-US';
      addTearDown(() => appdata.settings['language'] = previousLanguage);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SourceImportDialog())),
      );
      await tester.enterText(find.byType(TextField).first, catalog('one.js'));
      await tester.tap(find.text('Detect and preview'));
      await tester.pumpAndSettle();
      expect(find.text('Original source list URL'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'invalid');
      await tester.tap(find.text('Detect and preview'));
      await tester.pumpAndSettle();
      expect(find.text('Original source list URL'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).last,
        'https://example.test/repo/index.json',
      );
      await tester.tap(find.text('Detect and preview'));
      await tester.pumpAndSettle();
      expect(find.text('Source One'), findsOneWidget);
    },
  );

  testWidgets(
    'one input previews a list and allows selection before any install',
    (tester) async {
      final previousLanguage = appdata.settings['language'];
      appdata.settings['language'] = 'en-US';
      addTearDown(() => appdata.settings['language'] = previousLanguage);
      final taskCount = SourceInstallations.instance.tasks.length;
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SourceImportDialog())),
      );
      await tester.enterText(
        find.byType(TextField).first,
        catalog('https://example.test/one.js'),
      );
      await tester.tap(find.text('Detect and preview'));
      await tester.pumpAndSettle();
      expect(find.text('Source list detected: 1 sources'), findsOneWidget);
      expect(find.text('Source One'), findsOneWidget);
      expect(find.text('Install selected (1)'), findsOneWidget);
      expect(SourceInstallations.instance.tasks.length, taskCount);
      await tester.tap(find.text('Deselect all'));
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('Choose another source'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'class Demo extends ComicSource {}',
      );
      await tester.tap(find.text('Detect and preview'));
      await tester.pumpAndSettle();
      expect(find.text('Source script detected'), findsOneWidget);
      expect(find.text('Install source'), findsOneWidget);
      expect(SourceInstallations.instance.tasks.length, taskCount);
    },
  );
}
