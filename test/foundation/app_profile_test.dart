import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app_profile.dart';

void main() {
  test('ordinary builds keep their title and base version', () {
    for (final flavor in ['', 'mobile', 'other']) {
      final profile = AppProfile(flavor: flavor);
      expect(profile.isTv, isFalse);
      expect(profile.applicationTitle, 'VeneraNext');
      expect(profile.displayVersion('1.18.2-rc.1'), '1.18.2-rc.1');
    }
  });

  test(
    'TV identity retains build provenance without an experimental title',
    () {
      const profile = AppProfile(
        flavor: 'tv',
        build: '12',
        revision: 'abc1234',
      );
      expect(profile.isTv, isTrue);
      expect(profile.applicationTitle, 'VeneraNext TV');
      expect(
        profile.displayVersion('1.18.2-rc.1'),
        '1.18.2-rc.1 / TV 12 / abc1234',
      );
    },
  );
}
