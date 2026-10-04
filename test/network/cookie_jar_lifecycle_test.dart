import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/network/cookie_jar.dart';

void main() {
  late Directory directory;
  late String path;
  late SingleInstanceCookieJar? previous;
  final uri = Uri.parse('https://example.test/path');
  setUp(() {
    directory = Directory.systemTemp.createTempSync('cookie-lifecycle-');
    path = '${directory.path}/cookie.db';
    previous = SingleInstanceCookieJar.instance;
    SingleInstanceCookieJar.instance = null;
  });
  tearDown(() {
    SingleInstanceCookieJar.instance?.dispose();
    SingleInstanceCookieJar.instance = previous;
    directory.deleteSync(recursive: true);
  });

  test('schema failure releases the opened connection and allows retry', () {
    sqlite3.open(path).dispose();
    late Database opened;
    expect(
      () => CookieJarSql(
        path,
        openDatabase: (name) {
          opened = sqlite3.open(name, mode: OpenMode.readOnly);
          return opened;
        },
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(() => opened.select('SELECT 1'), throwsStateError);
    final jar = CookieJarSql(path);
    jar.saveFromResponse(uri, [Cookie('session', 'saved')]);
    expect(jar.loadForRequestCookieHeader(uri), 'session=saved');
    jar.dispose();
    jar.dispose();
  });

  test(
    'closed jar rejects access and reconstruction preserves stored cookies',
    () {
      final jar = CookieJarSql(path);
      jar.saveFromResponse(uri, [Cookie('session', 'saved')]);
      jar.dispose();
      jar.dispose();
      expect(() => jar.loadForRequest(uri), throwsStateError);
      final reopened = CookieJarSql(path);
      expect(reopened.loadForRequestCookieHeader(uri), 'session=saved');
      reopened.dispose();
    },
  );

  test(
    'disposed singleton rebuilds and old disposal preserves its replacement',
    () async {
      final old = await SingleInstanceCookieJar.createInstance(
        directory: directory.path,
      );
      old.saveFromResponse(uri, [Cookie('session', 'saved')]);
      old.dispose();
      expect(SingleInstanceCookieJar.instance, isNull);
      final replacement = await SingleInstanceCookieJar.createInstance(
        directory: directory.path,
      );
      expect(replacement, isNot(same(old)));
      expect(replacement.loadForRequestCookieHeader(uri), 'session=saved');
      old.dispose();
      expect(SingleInstanceCookieJar.instance, same(replacement));
    },
  );

  test(
    'concurrent creation shares one live jar and failed construction is retryable',
    () async {
      File(path).writeAsStringSync('invalid sqlite file');
      await expectLater(
        SingleInstanceCookieJar.createInstance(directory: directory.path),
        throwsA(isA<SqliteException>()),
      );
      expect(SingleInstanceCookieJar.instance, isNull);
      File(path).deleteSync();
      final jars = await Future.wait(
        List.generate(
          8,
          (_) =>
              SingleInstanceCookieJar.createInstance(directory: directory.path),
        ),
      );
      expect(jars.every((jar) => identical(jar, jars.first)), isTrue);
      jars.first.saveFromResponse(uri, [Cookie('shared', '1')]);
      expect(jars.last.loadForRequestCookieHeader(uri), 'shared=1');
    },
  );
}
