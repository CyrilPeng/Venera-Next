import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/routing/windows_webview_environment.dart';

void main() {
  const endpoints = {
    'system': null,
    'direct': '--no-proxy-server',
    '127.0.0.1:7890': '--proxy-server=http://127.0.0.1:7890',
    'http://127.0.0.1:7890': '--proxy-server=http://127.0.0.1:7890',
    'HTTP://LOCALHOST:00080': '--proxy-server=http://localhost:80',
    'https://proxy.example:443': '--proxy-server=https://proxy.example:443',
    'socks4://localhost:1080': '--proxy-server=socks4://localhost:1080',
    'socks5://localhost:1080': '--proxy-server=socks5://localhost:1080',
    '[::1]:7890': '--proxy-server=http://[::1]:7890',
    'http://[2001:db8::1]:80': '--proxy-server=http://[2001:db8::1]:80',
    'proxy.example.:65535': '--proxy-server=http://proxy.example.:65535',
  };
  for (final entry in endpoints.entries) {
    test('Windows proxy arguments: ${entry.key}', () {
      expect(windowsWebviewProxyArguments(entry.key), entry.value);
    });
  }
  for (final invalid in [
    '',
    'localhost',
    ':7890',
    'localhost:0',
    'localhost:65536',
    'localhost:123456',
    'localhost:-1',
    'localhost:port',
    'localhost:1 --no-proxy-server',
    'localhost:1\t--no-proxy-server',
    'localhost:1\r\n--no-proxy-server',
    'localhost:1" --no-proxy-server',
    'localhost:1;direct://',
    'localhost:1,direct://',
    'http=localhost:1',
    'http://localhost:1/path',
    'http://localhost:1/',
    'http://localhost:1?option=1',
    'http://localhost:1#option',
    'http://localhost%20:1',
    'ftp://localhost:1',
    'socks://localhost:1',
    'http://-proxy.example:1',
    'http://proxy..example:1',
    'http://proxy_.example:1',
    '[1:2:3]:80',
    '::1:80',
    'http://[::1%25zone]:80',
  ]) {
    test('rejects malformed proxy without echoing it: $invalid', () {
      expect(
        () => windowsWebviewProxyArguments(invalid),
        throwsA(
          isA<WebviewEnvironmentException>().having(
            (error) => error.message,
            'actionable error',
            startsWith('Invalid Windows webview proxy.'),
          ),
        ),
      );
    });
  }
  for (final proxy in [
    'user:secret@localhost:7890',
    'http://user:secret@localhost:7890',
    'socks5://user:secret@localhost:1080',
  ]) {
    test('authenticated proxies fail closed without exposing credentials', () {
      expect(
        () => windowsWebviewProxyArguments(proxy),
        throwsA(
          isA<WebviewEnvironmentException>()
              .having(
                (error) => error.message,
                'guidance',
                contains('system proxy'),
              )
              .having(
                (error) => '$error',
                'credentials',
                isNot(contains('secret')),
              ),
        ),
      );
    });
  }

  late WindowsWebviewEnvironmentPool pool;
  late List<_Environment> created;
  setUp(() {
    created = [];
    pool = WindowsWebviewEnvironmentPool(
      create: (settings) async {
        final environment = _Environment(settings);
        created.add(environment);
        return WebViewEnvironment.fromPlatform(platform: environment);
      },
    );
  });

  Future<WindowsWebviewEnvironmentLease> acquire(String proxy) =>
      pool.acquire(userDataFolder: r'profile\webview', proxy: proxy);

  test('concurrent same-policy callers share one environment', () async {
    final leases = await Future.wait([
      acquire('127.0.0.1:7890'),
      acquire('http://127.0.0.1:7890'),
    ]);
    expect(created, hasLength(1));
    expect(leases[0].environment, same(leases[1].environment));
    leases[0].viewRequested();
    leases[0].release();
    leases[0].release();
    await expectLater(
      acquire('direct'),
      throwsA(isA<WebviewEnvironmentException>()),
    );
    expect(created.single.disposals, 0);
    leases[1].release();
    created.single.exit();
    final direct = await acquire('direct');
    expect(created, hasLength(2));
    expect(created.first.disposals, 1);
    expect(
      created.last.settings!.additionalBrowserArguments,
      '--no-proxy-server',
    );
    expect(created.last.settings!.userDataFolder, r'profile\webview');
    direct.release();
  });

  test(
    'a proxy switch waits for native exit, not just route disposal',
    () async {
      final first = await acquire('system');
      first.viewRequested();
      first.release();
      var completed = false;
      final second = acquire('localhost:7890').then((value) {
        completed = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(created, hasLength(1));
      expect(created.first.disposals, 0);
      created.first.exit();
      final lease = await second;
      expect(completed, isTrue);
      expect(created.first.disposals, 1);
      expect(
        created.last.settings!.userDataFolder,
        created.first.settings!.userDataFolder,
      );
      lease.release();
    },
  );

  test('an abandoned creation without a view can be replaced safely', () async {
    final abandoned = await acquire('system');
    abandoned.release();
    final next = await acquire('direct');
    expect(created.first.disposals, 1);
    expect(created, hasLength(2));
    next.release();
  });

  test(
    'native exit timeout is actionable and does not change the route',
    () async {
      pool = WindowsWebviewEnvironmentPool(
        browserExitTimeout: const Duration(milliseconds: 1),
        create: (settings) async {
          final environment = _Environment(settings);
          created.add(environment);
          return WebViewEnvironment.fromPlatform(platform: environment);
        },
      );
      final first = await acquire('system');
      first.viewRequested();
      first.release();
      await expectLater(
        acquire('direct'),
        throwsA(
          isA<WebviewEnvironmentException>().having(
            (error) => error.message,
            'recovery',
            contains('restart the app'),
          ),
        ),
      );
      expect(created, hasLength(1));
      expect(created.single.disposals, 0);
      created.single.exit();
      final retry = await acquire('direct');
      expect(created, hasLength(2));
      retry.release();
    },
  );

  test(
    'cookie work retains its environment and closed controllers cannot read',
    () async {
      final first = await acquire('system');
      final read = Completer<String>();
      WebViewEnvironment? captured;
      final cookies = first.use((environment) {
        captured = environment;
        return read.future;
      });
      first.release();
      await expectLater(
        acquire('direct'),
        throwsA(isA<WebviewEnvironmentException>()),
      );
      expect(created, hasLength(1));
      expect(captured, same(first.environment));
      read.complete('original cookie');
      expect(await cookies, 'original cookie');
      final next = await acquire('direct');
      var lateRead = false;
      await expectLater(
        first.use((_) async {
          lateRead = true;
        }),
        throwsA(isA<WebviewEnvironmentException>()),
      );
      expect(lateRead, isFalse);
      expect(created.first.disposals, 1);
      next.release();
    },
  );

  test('a failed creation does not poison subsequent attempts', () async {
    var attempts = 0;
    pool = WindowsWebviewEnvironmentPool(
      create: (settings) async {
        if (attempts++ == 0) throw StateError('native creation failed');
        final environment = _Environment(settings);
        created.add(environment);
        return WebViewEnvironment.fromPlatform(platform: environment);
      },
    );
    await expectLater(acquire('system'), throwsStateError);
    final retry = await acquire('direct');
    expect(attempts, 2);
    expect(
      created.single.settings!.additionalBrowserArguments,
      '--no-proxy-server',
    );
    retry.release();
  });
}

class _Environment extends PlatformWebViewEnvironment {
  _Environment(WebViewEnvironmentSettings settings)
    : super.implementation(
        PlatformWebViewEnvironmentCreationParams(settings: settings),
      );

  int disposals = 0;

  void exit() => onBrowserProcessExited?.call(_BrowserExit());

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

class _BrowserExit extends Fake implements BrowserProcessExitedDetail {}
