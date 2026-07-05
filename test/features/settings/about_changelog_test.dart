import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/settings/settings.dart';
import 'package:venera_next/foundation/translations.dart';

void main() {
  test('stable users are not notified about prerelease versions', () {
    expect(shouldNotifyUpdateForTesting('1.10.0-rc.2', '1.9.3'), isFalse);
    expect(selectUpdateVersionForTesting(['1.10.0-rc.2'], '1.9.3'), isNull);
  });

  test('prerelease users are notified about newer prereleases', () {
    expect(shouldNotifyUpdateForTesting('1.10.0-rc.2', '1.10.0-rc.1'), isTrue);
    expect(
      selectUpdateVersionForTesting(['1.10.0-rc.2'], '1.10.0-rc.1'),
      '1.10.0-rc.2',
    );
  });

  test('stable releases still notify stable users', () {
    expect(shouldNotifyUpdateForTesting('1.10.0', '1.9.3'), isTrue);
    expect(
      selectUpdateVersionForTesting(['1.10.0-rc.2', '1.9.4'], '1.9.3'),
      '1.9.4',
    );
  });

  testWidgets('changelog page renders markdown content', (tester) async {
    await AppTranslation.init();

    await tester.pumpWidget(const MaterialApp(home: ChangelogPage()));
    await tester.pumpAndSettle();

    expect(find.text('更新日志'), findsWidgets);
    expect(find.text('# 更新日志'), findsNothing);
    expect(find.text('变更'), findsWidgets);
    expect(find.text('修复'), findsWidgets);
    expect(
      find.byWidgetPredicate((widget) => widget is Text && widget.data == '•'),
      findsWidgets,
    );
  });
}
