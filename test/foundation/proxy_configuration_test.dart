import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/proxy_configuration.dart';

void main() {
  test(
    'mode names are exact and serialization ignores dormant form fields',
    () {
      for (final mode in [ProxyMode.direct, ProxyMode.system]) {
        final value = ProxyConfiguration.parse(mode.name);
        expect(value.mode, mode);
        expect(
          value.copyWith(host: 'old', username: 'user').serialize(),
          mode.name,
        );
      }
      for (final input in ['Direct', ' system ', '', 'manual']) {
        expect(ProxyConfiguration.parse(input).mode, ProxyMode.manual);
      }
    },
  );

  test(
    'manual fields retain Unicode, whitespace, and textual port spelling',
    () {
      final value = ProxyConfiguration.parse(' 用户 : 密码 @proxy.test:+07897');
      expect(value.mode, ProxyMode.manual);
      expect(value.host, 'proxy.test');
      expect(value.port, '+07897');
      expect(value.username, ' 用户 ');
      expect(value.password, ' 密码 ');
      expect(value.serialize(), ' 用户 : 密码 @proxy.test:+07897');
    },
  );

  test('empty port and credentials retain the existing output convention', () {
    for (final (input, output) in [
      ('host:', 'host'),
      ('user:@host:80', 'user@host:80'),
      (':pass@host:80', 'host:80'),
      ('@:80', ':80'),
      ('host:not-a-number', 'host:not-a-number'),
    ]) {
      expect(ProxyConfiguration.parse(input).serialize(), output);
    }
  });

  test(
    'legacy host-only, username-only, IPv6 and extra separators are explicit',
    () {
      for (final (input, output) in [
        ('host', ''),
        ('user@host:80', 'host:80'),
        ('user:pass@host', 'user:pass@'),
        ('[::1]:80', ''),
        ('user:pass@[::1]:80', 'user:pass@'),
        ('user:pa:ss@host:80', 'host:80'),
        ('a@b@host:80', 'a@b@host:80'),
      ]) {
        expect(ProxyConfiguration.parse(input).serialize(), output);
      }
    },
  );

  test(
    'mode switches preserve editable fields without mutating the snapshot',
    () {
      final original = ProxyConfiguration.parse('user:pass@host:80');
      final edited = original.copyWith(host: 'new', port: '');
      final direct = edited.copyWith(mode: ProxyMode.direct);
      expect(direct.serialize(), 'direct');
      expect(
        direct.copyWith(mode: ProxyMode.manual).serialize(),
        'user:pass@new',
      );
      expect(original.serialize(), 'user:pass@host:80');
      expect(edited.copyWith(username: '', password: '').serialize(), 'new');
    },
  );
}
