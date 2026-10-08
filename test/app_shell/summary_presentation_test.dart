import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_summary.dart';
import 'package:venera_next/features/history/history_summary.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  for (final size in [const Size(375, 740), const Size(812, 375)]) {
    testWidgets(
      'summary labels fit and retain their semantics at 2x text: $size',
      (tester) async {
        final language = appdata.settings['language'];
        appdata.settings['language'] = 'en-US';
        addTearDown(() => appdata.settings['language'] = language);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: size.width == 375
                  ? Brightness.dark
                  : Brightness.light,
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: const Scaffold(
              body: CustomScrollView(
                slivers: [
                  HistorySummary(manager: null, favoriteChanges: null),
                  ComicSourceSummary(manager: null),
                ],
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(
          tester
              .getSemantics(find.text('Comic Source'))
              .getSemanticsData()
              .label,
          contains('Comic Source'),
        );
        expect(
          tester.getSemantics(find.text('History')).getSemanticsData().label,
          contains('History'),
        );
        await tester.pumpWidget(const SizedBox());
        semantics.dispose();
      },
    );
  }
}
