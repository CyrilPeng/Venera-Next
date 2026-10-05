import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/extensions.dart';

class CookieJarSql {
  Database? _database;
  Database get _db =>
      _database ?? (throw StateError('Cookie database is closed'));

  final String path;
  final AppDataOperations _operations;

  /// Owns the returned connection, including schema-initialization failures.
  CookieJarSql(
    this.path, {
    Database Function(String)? openDatabase,
    AppDataOperations? operations,
  }) : _operations = operations ?? AppDataOperations.instance {
    _operations.accessSync(() {
      final database = (openDatabase ?? sqlite3.open)(path);
      try {
        database.execute('''
        CREATE TABLE IF NOT EXISTS cookies (
          name TEXT NOT NULL,
          value TEXT NOT NULL,
          domain TEXT NOT NULL,
          path TEXT,
          expires INTEGER,
          secure INTEGER,
          httpOnly INTEGER,
          PRIMARY KEY (name, domain, path)
        );
      ''');
        _database = database;
      } catch (_) {
        database.dispose();
        rethrow;
      }
    });
  }

  /// Captures mutable input before waiting. A retired jar is never redirected
  /// to a newly imported database, even if both connections use the same path.
  Future<void> saveFromResponseAsync(Uri uri, List<Cookie> cookies) {
    final captured = cookies
        .map(
          (cookie) => Cookie(cookie.name, cookie.value)
            ..domain = cookie.domain
            ..path = cookie.path
            ..expires = cookie.expires
            ..maxAge = cookie.maxAge
            ..secure = cookie.secure
            ..httpOnly = cookie.httpOnly,
        )
        .toList();
    return _operations.access(() => saveFromResponse(uri, captured));
  }

  void saveFromResponse(Uri uri, List<Cookie> cookies) =>
      _operations.accessSync(() => _saveFromResponse(uri, cookies));

  void _saveFromResponse(Uri uri, List<Cookie> cookies) {
    var current = loadForRequest(uri);
    for (var cookie in cookies) {
      var currentCookie = current.firstWhereOrNull(
        (element) =>
            element.name == cookie.name &&
            (cookie.path == null || cookie.path!.startsWith(element.path!)),
      );
      if (currentCookie != null) {
        cookie.domain = currentCookie.domain;
      }
      _db.execute(
        '''
        INSERT OR REPLACE INTO cookies (name, value, domain, path, expires, secure, httpOnly)
        VALUES (?, ?, ?, ?, ?, ?, ?);
      ''',
        [
          cookie.name,
          cookie.value,
          cookie.domain ?? uri.host,
          cookie.path ?? "/",
          cookie.expires?.millisecondsSinceEpoch,
          cookie.secure ? 1 : 0,
          cookie.httpOnly ? 1 : 0,
        ],
      );
    }
  }

  List<Cookie> _loadWithDomain(String domain) {
    var rows = _db.select(
      '''
      SELECT name, value, domain, path, expires, secure, httpOnly
      FROM cookies
      WHERE domain = ?;
    ''',
      [domain],
    );

    return rows
        .map(
          (row) => Cookie(row["name"] as String, row["value"] as String)
            ..domain = row["domain"] as String
            ..path = row["path"] as String
            ..expires = row["expires"] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(row["expires"] as int)
            ..secure = row["secure"] == 1
            ..httpOnly = row["httpOnly"] == 1,
        )
        .toList();
  }

  List<String> _getAcceptedDomains(String host) {
    var acceptedDomains = <String>[host];
    var hostParts = host.split(".");
    for (var i = 0; i < hostParts.length - 1; i++) {
      acceptedDomains.add(".${hostParts.sublist(i).join(".")}");
    }
    return acceptedDomains;
  }

  List<Cookie> loadForRequest(Uri uri) =>
      _operations.accessSync(() => _loadForRequest(uri));

  List<Cookie> _loadForRequest(Uri uri) {
    // if uri.host is example.example.com, acceptedDomains will be [".example.example.com", ".example.com", "example.com"]
    var acceptedDomains = _getAcceptedDomains(uri.host);

    var cookies = <Cookie>[];
    for (var domain in acceptedDomains) {
      cookies.addAll(_loadWithDomain(domain));
    }

    // check expires
    var expires = cookies.where(
      (cookie) =>
          cookie.expires != null && cookie.expires!.isBefore(DateTime.now()),
    );
    for (var cookie in expires) {
      _db.execute(
        '''
        DELETE FROM cookies
        WHERE name = ? AND domain = ? AND path = ?;
      ''',
        [cookie.name, cookie.domain, cookie.path],
      );
    }

    return cookies
        .where(
          (element) =>
              !expires.contains(element) && _checkPathMatch(uri, element.path),
        )
        .toList();
  }

  bool _checkPathMatch(Uri uri, String? cookiePath) {
    if (cookiePath == null) {
      return true;
    }

    if (cookiePath == uri.path) {
      return true;
    }

    if (cookiePath == "/") {
      return true;
    }

    if (cookiePath.endsWith("/")) {
      return uri.path.startsWith(cookiePath);
    }

    return uri.path.startsWith(cookiePath);
  }

  void saveFromResponseCookieHeader(Uri uri, List<String> cookieHeader) {
    var cookies = <Cookie>[];
    for (var header in cookieHeader) {
      try {
        var cookie = Cookie.fromSetCookieValue(header);
        cookies.add(cookie);
      } catch (_) {
        Log.warning("Network", "Invalid cookie header: $header");
        continue;
      }
    }
    saveFromResponse(uri, cookies);
  }

  String loadForRequestCookieHeader(Uri uri) {
    var cookies = loadForRequest(uri);
    var map = <String, Cookie>{};
    for (var cookie in cookies) {
      if (map.containsKey(cookie.name)) {
        if (cookie.domain![0] != '.' && map[cookie.name]!.domain![0] == '.') {
          map[cookie.name] = cookie;
        } else if (cookie.domain!.length > map[cookie.name]!.domain!.length) {
          map[cookie.name] = cookie;
        }
      } else {
        map[cookie.name] = cookie;
      }
    }
    return map.entries
        .map((cookie) => "${cookie.value.name}=${cookie.value.value}")
        .join("; ");
  }

  void delete(Uri uri, String name) =>
      _operations.accessSync(() => _delete(uri, name));

  void _delete(Uri uri, String name) {
    var acceptedDomains = _getAcceptedDomains(uri.host);
    for (var domain in acceptedDomains) {
      _db.execute(
        '''
        DELETE FROM cookies
        WHERE name = ? AND domain = ? AND path = ?;
      ''',
        [name, domain, uri.path],
      );
    }
  }

  void deleteUri(Uri uri) => _operations.accessSync(() => _deleteUri(uri));

  void _deleteUri(Uri uri) {
    var acceptedDomains = _getAcceptedDomains(uri.host);
    for (var domain in acceptedDomains) {
      _db.execute(
        '''
        DELETE FROM cookies
        WHERE domain = ?;
      ''',
        [domain],
      );
    }
  }

  void dispose() => _operations.accessSync(() {
    final database = _database;
    _database = null;
    database?.dispose();
  });
}

class SingleInstanceCookieJar extends CookieJarSql {
  factory SingleInstanceCookieJar(String path) =>
      instance ??= SingleInstanceCookieJar._create(path);

  SingleInstanceCookieJar._create(super.path);

  static SingleInstanceCookieJar? instance;

  /// Capture the login/request owner after any pending replacement reopens it.
  static Future<SingleInstanceCookieJar> captureInstance() =>
      AppDataOperations.instance.access(
        () =>
            instance ??
            (throw StateError('Cookie database is not initialized')),
      );

  @override
  void dispose() {
    super.dispose();
    if (identical(instance, this)) instance = null;
  }

  static Future<SingleInstanceCookieJar> createInstance({String? directory}) =>
      AppDataOperations.instance.access(() async {
        if (instance != null) {
          return instance!;
        }
        var dataPath =
            directory ?? (await getApplicationSupportDirectory()).path;
        instance = SingleInstanceCookieJar("$dataPath/cookie.db");
        return instance!;
      });
}

class CookieManagerSql extends Interceptor {
  CookieManagerSql(CookieJarSql cookieJar)
    : this.dynamic(() => cookieJar, operations: cookieJar._operations);

  CookieManagerSql.dynamic(
    this._cookieJarProvider, {
    AppDataOperations? operations,
  }) : _operations = operations ?? AppDataOperations.instance;

  final CookieJarSql? Function() _cookieJarProvider;
  final AppDataOperations _operations;
  final _requestJars = Expando<CookieJarSql>();

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      await _operations.access(() {
        final cancellation = options.cancelToken?.cancelError;
        if (cancellation != null) throw cancellation;
        final cookieJar = _cookieJarProvider();
        var cookies = cookieJar?.loadForRequestCookieHeader(options.uri) ?? "";
        _requestJars[options] = cookieJar;
        if (cookies.isNotEmpty) {
          if (options.headers["cookie"] != null) {
            cookies = "${options.headers["cookie"]}; $cookies";
          }
          options.headers["cookie"] = cookies;
        }
      });
    } catch (e, s) {
      handler.reject(_failure(options, e, s, 'Failed to load cookies'));
      return;
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) async {
    try {
      final options = response.requestOptions;
      final cookieJar = _requestJars[options];
      _requestJars[options] = null;
      final headers = response.headers['set-cookie'] ?? const <String>[];
      if (cookieJar != null && headers.isNotEmpty) {
        await _operations.access(() {
          if (!identical(cookieJar, _cookieJarProvider()) ||
              cookieJar._database == null) {
            // Import won the race. This response belongs to the retired
            // connection, not to the replacement's authenticated session.
            return;
          }
          cookieJar.saveFromResponseCookieHeader(options.uri, headers);
        });
      }
    } catch (e, s) {
      handler.reject(
        _failure(
          response.requestOptions,
          e,
          s,
          'Failed to save cookies',
          response: response,
        ),
      );
      return;
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _requestJars[err.requestOptions] = null;
    handler.next(err);
  }

  DioException _failure(
    RequestOptions options,
    Object error,
    StackTrace stack,
    String message, {
    Response? response,
  }) => error is DioException
      ? error
      : DioException(
          requestOptions: options,
          response: response,
          error: error,
          stackTrace: stack,
          message: message,
        );
}
