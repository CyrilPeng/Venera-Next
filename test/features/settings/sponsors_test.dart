import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/settings/sponsors.dart';
import 'package:venera_next/features/settings/sponsor_catalog.dart';
import 'package:venera_next/foundation/translations.dart';

void main() {
  test('sectioned sponsor data is parsed without losing status', () {
    var catalog = SponsorCatalog.fromJson({
      'schemaVersion': 2,
      'sections': {
        'featured': [
          {'name': 'Featured', 'tier': 200, 'kind': 'monthly'},
        ],
        'current': [
          {'name': 'Current', 'tier': 80, 'kind': 'monthly'},
        ],
        'historical': [
          {'name': 'Past', 'tier': 30, 'kind': 'oneTime'},
        ],
      },
    });

    expect(catalog.featured.single.name, 'Featured');
    expect(catalog.current.single.name, 'Current');
    expect(catalog.historical.single.kind, SponsorKind.oneTime);
  });

  test('legacy flat sponsor data remains readable', () {
    var catalog = SponsorCatalog.fromJson({
      'sponsors': [
        {'name': 'Featured', 'tier': 200},
        {'name': 'Current', 'tier': 30},
      ],
    });

    expect(catalog.featured.single.name, 'Featured');
    expect(catalog.current.single.name, 'Current');
    expect(catalog.historical, isEmpty);
  });

  test('invalid sponsor data is rejected', () {
    expect(
      () => SponsorCatalog.fromJson({
        'sections': {
          'featured': [
            {'name': '', 'tier': 200},
          ],
        },
      }),
      throwsFormatException,
    );
  });

  testWidgets('sponsor page renders featured, current, and past sections', (
    tester,
  ) async {
    await AppTranslation.init();
    var catalog = SponsorCatalog.fromJson({
      'schemaVersion': 2,
      'sections': {
        'featured': [
          {'name': 'Featured Studio', 'tier': 200, 'kind': 'monthly'},
        ],
        'current': [
          {'name': 'Current Supporter', 'tier': 80, 'kind': 'monthly'},
        ],
        'historical': [
          {'name': 'Past Supporter', 'tier': 30, 'kind': 'oneTime'},
        ],
      },
    });

    await tester.pumpWidget(
      MaterialApp(home: SponsorsPage(loader: () async => catalog)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Featured Sponsors'), findsOneWidget);
    expect(find.text('Current Sponsors'), findsOneWidget);
    expect(find.text('Past Sponsors'), findsOneWidget);
    expect(find.text('Featured Studio'), findsOneWidget);
    expect(find.text('Current Supporter'), findsOneWidget);
    expect(find.text('Past Supporter'), findsOneWidget);
    expect(find.text('Tier ¥200'), findsOneWidget);
    expect(find.text('One-time'), findsOneWidget);
  });
}
