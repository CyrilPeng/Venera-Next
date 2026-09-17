import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/routing/page_jump_target.dart';

class _FakeBuildContext extends Fake implements BuildContext {}

const MethodChannel _urlLauncherChannel = MethodChannel(
  'plugins.flutter.io/url_launcher',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> launchedUrls;
  late bool initialMuted;
  final context = _FakeBuildContext();

  setUp(() {
    launchedUrls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_urlLauncherChannel, (
          MethodCall methodCall,
        ) async {
          if (methodCall.method == 'launch') {
            final args = methodCall.arguments;
            if (args is Map && args['url'] is String) {
              launchedUrls.add(args['url'] as String);
            }
            return true;
          }
          return null;
        });

    initialMuted = Log.isMuted;
    Log.isMuted = false;
    Log.clear();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_urlLauncherChannel, null);
    Log.isMuted = initialMuted;
    Log.clear();
  });

  group('PageJumpTarget url navigation', () {
    test('valid https author URL launches correctly', () async {
      const target = PageJumpTarget('test_source', 'url', {
        'url': 'https://komiic.cc/author/192',
      });

      target.jump(context);
      await Future<void>.delayed(Duration.zero);

      expect(launchedUrls, ['https://komiic.cc/author/192']);
      expect(Log.logs, isEmpty);
    });

    test('valid https category URL launches correctly', () async {
      const target = PageJumpTarget('test_source', 'url', {
        'url': 'https://komiic.cc/comics/category/1',
      });

      target.jump(context);
      await Future<void>.delayed(Duration.zero);

      expect(launchedUrls, ['https://komiic.cc/comics/category/1']);
      expect(Log.logs, isEmpty);
    });

    test('valid http URL launches correctly', () async {
      const target = PageJumpTarget('test_source', 'url', {
        'url': 'http://example.com/comics/list',
      });

      target.jump(context);
      await Future<void>.delayed(Duration.zero);

      expect(launchedUrls, ['http://example.com/comics/list']);
      expect(Log.logs, isEmpty);
    });

    test('URL with whitespace is trimmed before launching', () async {
      const target = PageJumpTarget('test_source', 'url', {
        'url': '   https://komiic.cc/author/192   ',
      });

      target.jump(context);
      await Future<void>.delayed(Duration.zero);

      expect(launchedUrls, ['https://komiic.cc/author/192']);
      expect(Log.logs, isEmpty);
    });

    test(
      'missing or blank URL logs "URL is required" and does not launch',
      () async {
        const targets = [
          PageJumpTarget('test_source', 'url', null),
          PageJumpTarget('test_source', 'url', {}),
          PageJumpTarget('test_source', 'url', {'url': null}),
          PageJumpTarget('test_source', 'url', {'url': ''}),
          PageJumpTarget('test_source', 'url', {'url': '   '}),
        ];

        for (final target in targets) {
          launchedUrls.clear();
          Log.clear();

          target.jump(context);
          await Future<void>.delayed(Duration.zero);

          expect(launchedUrls, isEmpty);
          expect(Log.logs, hasLength(1));
          expect(Log.logs.first.title, 'Page Jump');
          expect(Log.logs.first.content, 'URL is required');
          expect(Log.logs.first.level, LogLevel.error);
        }
      },
    );

    test('non-string URL values log "Invalid URL" and do not launch', () async {
      const nonStringValues = [
        12345,
        true,
        ['https://komiic.cc/author/192'],
      ];

      for (final value in nonStringValues) {
        launchedUrls.clear();
        Log.clear();

        final target = PageJumpTarget('test_source', 'url', {'url': value});
        target.jump(context);
        await Future<void>.delayed(Duration.zero);

        expect(launchedUrls, isEmpty);
        expect(Log.logs, hasLength(1));
        expect(Log.logs.first.title, 'Page Jump');
        expect(Log.logs.first.content, 'Invalid URL');
        expect(Log.logs.first.level, LogLevel.error);
      }
    });

    test('relative URLs log "Invalid URL" and do not launch', () async {
      const relativeUrls = ['/author/192', 'comics/category/1'];

      for (final url in relativeUrls) {
        launchedUrls.clear();
        Log.clear();

        final target = PageJumpTarget('test_source', 'url', {'url': url});
        target.jump(context);
        await Future<void>.delayed(Duration.zero);

        expect(launchedUrls, isEmpty);
        expect(Log.logs, hasLength(1));
        expect(Log.logs.first.title, 'Page Jump');
        expect(Log.logs.first.content, 'Invalid URL');
        expect(Log.logs.first.level, LogLevel.error);
      }
    });

    test(
      'URLs with missing host log "Invalid URL" and do not launch',
      () async {
        const noHostUrls = ['http:///path', 'https://', 'http://:80'];

        for (final url in noHostUrls) {
          launchedUrls.clear();
          Log.clear();

          final target = PageJumpTarget('test_source', 'url', {'url': url});
          target.jump(context);
          await Future<void>.delayed(Duration.zero);

          expect(launchedUrls, isEmpty);
          expect(Log.logs, hasLength(1));
          expect(Log.logs.first.title, 'Page Jump');
          expect(Log.logs.first.content, 'Invalid URL');
          expect(Log.logs.first.level, LogLevel.error);
        }
      },
    );

    test(
      'dangerous schemes (file, javascript, intent) log "Invalid URL" and do not launch',
      () async {
        const dangerousUrls = [
          'file:///etc/passwd',
          'javascript:alert(1)',
          'intent://komiic.cc/#Intent;end',
        ];

        for (final url in dangerousUrls) {
          launchedUrls.clear();
          Log.clear();

          final target = PageJumpTarget('test_source', 'url', {'url': url});
          target.jump(context);
          await Future<void>.delayed(Duration.zero);

          expect(launchedUrls, isEmpty);
          expect(Log.logs, hasLength(1));
          expect(Log.logs.first.title, 'Page Jump');
          expect(Log.logs.first.content, 'Invalid URL');
          expect(Log.logs.first.level, LogLevel.error);
        }
      },
    );
  });

  group('PageJumpTarget.parse preservation', () {
    test('preserves url page and attributes when parsed from map', () {
      final target = PageJumpTarget.parse('source_key_1', {
        'page': 'url',
        'attributes': {'url': 'https://komiic.cc/author/192'},
      });

      expect(target.sourceKey, 'source_key_1');
      expect(target.page, 'url');
      expect(target.attributes, isNotNull);
      expect(target.attributes?['url'], 'https://komiic.cc/author/192');
    });
  });
}
