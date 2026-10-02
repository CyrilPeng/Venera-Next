import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  bool nativeAvailable;
  try {
    if (Platform.isWindows) {
      final build = Directory('build/windows/x64/runner/Release').absolute.path;
      if (File('$build/flutter_windows.dll').existsSync()) {
        DynamicLibrary.open('$build/flutter_windows.dll');
        DynamicLibrary.open('$build/flutter_qjs_plugin.dll');
      }
    }
    DynamicLibrary.open(
      Platform.isWindows
          ? 'flutter_qjs_plugin.dll'
          : Platform.isLinux
          ? 'libflutter_qjs_plugin.so'
          : 'flutter_qjs.framework/flutter_qjs',
    );
    nativeAvailable = true;
  } catch (_) {
    nativeAvailable = false;
  }

  group(
    'source capability compatibility',
    () {
      late Directory directory;
      late Map<String, dynamic> settings;
      final manager = ComicSourceManager();
      setUp(() async {
        directory = Directory.systemTemp.createTempSync(
          'venera-source-transaction-',
        );
        Directory('${directory.path}/comic_source').createSync();
        App.dataPath = directory.path;
        App.cachePath = directory.path;
        App.version = '9.0.0';
        settings = jsonDecode(jsonEncode(appdata.toJson()['settings']));
        Log.isMuted = true;
        JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
        await JsEngine().init();
      });
      tearDown(() async {
        for (final key in ['transaction_a', 'transaction_b']) {
          manager.remove(key);
        }
        await appdata.saveData(false);
        JsEngine().dispose();
        settings.forEach((key, value) => appdata.settings[key] = value);
        Log.isMuted = false;
        directory.deleteSync(recursive: true);
      });

      Future<ComicSource> parse(String capabilities) async {
        final source = await ComicSourceParser().parse(
          sourceScript(capabilities),
          '${directory.path}/matrix.js',
        );
        manager.add(source);
        return source;
      }

      test(
        'account callbacks preserve arguments and persisted login identity',
        () async {
          final source = await parse(accountScript);
          final account = source.account!;
          expect(
            (await account.login!('user"名', 'password\\value')).success,
            isTrue,
          );
          await source.saveData();
          expect(source.data['account'], ['user"名', 'password\\value']);
          expect(
            jsonDecode(
              await File(
                '${directory.path}/comic_source/transaction_a.data',
              ).readAsString(),
            )['account'],
            source.data['account'],
          );
          expect(
            JsEngine().runCode('ComicSource.sources.transaction_a.credentials'),
            source.data['account'],
          );
          expect(account.checkLoginStatus!('done', 'title'), isTrue);
          expect(account.checkLoginStatus!('other', 'title'), isFalse);
          account.onLoginWithWebviewSuccess!();
          expect(await account.validateCookies!(['cookie']), isTrue);
          expect(await account.validateCookies!(['invalid']), isFalse);
          account.logout();
          expect(
            JsEngine().runCode('ComicSource.sources.transaction_a.events'),
            ['webview', 'logout'],
          );
        },
      );

      for (final failLogin in [false, true]) {
        test(
          'favorites retries once after expired login; login fails=$failLogin',
          () async {
            final source = await parse(accountScript + favoritesScript);
            source.data['account'] = ['user', 'password'];
            JsEngine().runCode(
              'void (ComicSource.sources.transaction_a.failLogin = $failLogin)',
            );
            final result = await source.favoriteData!.loadComic!(1, 'folder');
            expect(result.error, failLogin);
            expect(
              JsEngine().runCode('ComicSource.sources.transaction_a.attempts'),
              failLogin ? 1 : 2,
            );
            expect(
              JsEngine().runCode('ComicSource.sources.transaction_a.logins'),
              1,
            );
            if (!failLogin) {
              expect(result.subData, 3);
              await source.saveData();
              final folders = await source.favoriteData!.loadFolders!('comic');
              expect(folders.data, {'f': 'Folder'});
              expect(folders.subData, ['f']);
              expect(
                (await source.favoriteData!.addFolder!('new')).success,
                isTrue,
              );
              expect(
                (await source.favoriteData!.deleteFolder!('f')).success,
                isTrue,
              );
            }
          },
        );
      }

      test(
        'cursor search, explore and ranking preserve next tokens and argument order',
        () async {
          final source = await parse(cursorScript);
          final search = await source.searchPageData!.loadNext!(
            'query"名',
            'cursor',
            ['option'],
          );
          expect(search.subData, 'search-next');
          expect(
            (await source.explorePages.single.loadNext!(
              'explore-cursor',
            )).subData,
            'explore-next',
          );
          final category = source.categoryComicsData!;
          expect(
            (await category.rankingData!.loadWithNext!(
              'rank',
              'rank-cursor',
            )).subData,
            'rank-next',
          );
          expect(
            (await category.load('category', 'param', ['option'], 2)).subData,
            6,
          );
          expect(
            (await category.optionsLoader!(
              'category',
              'param',
            )).data.single.options,
            {'a': 'Alpha-Beta'},
          );
          expect(
            JsEngine().runCode('ComicSource.sources.transaction_a.calls'),
            [
              [
                'query"名',
                ['option'],
                'cursor',
              ],
              ['explore-cursor'],
              ['rank', 'rank-cursor'],
              [
                'category',
                'param',
                ['option'],
                2,
              ],
              ['category', 'param'],
            ],
          );
        },
      );

      test(
        'unauthenticated favorites do not invoke JS or attempt login',
        () async {
          final source = await parse(accountScript + favoritesScript);
          final result = await source.favoriteData!.loadComic!(1);
          expect(result.errorMessage, 'Not login');
          expect(
            JsEngine().runCode('ComicSource.sources.transaction_a.attempts'),
            0,
          );
          expect(
            JsEngine().runCode('ComicSource.sources.transaction_a.logins'),
            0,
          );
        },
      );

      test(
        'repeated expired login stops after one re-login and one retry',
        () async {
          final source = await parse(
            accountScript +
                favoritesScript.replaceFirst('this.attempts === 1', 'true'),
          );
          source.data['account'] = ['user', 'password'];
          final result = await source.favoriteData!.loadComic!(1);
          expect(result.errorMessage, contains('Login expired'));
          expect(
            JsEngine().runCode('ComicSource.sources.transaction_a.attempts'),
            2,
          );
          expect(
            JsEngine().runCode('ComicSource.sources.transaction_a.logins'),
            1,
          );
          await source.saveData();
        },
      );

      test(
        'legacy and current category targets retain source and attributes',
        () async {
          final source = await parse(r'''
category = {title: "Categories", parts: [
  {name: "legacy", type: "fixed", categories: ["Tag"], itemType: "category", groupParam: "group"},
  {name: "current", type: "fixed", categories: [{label: "Label", target: {page:"search", attributes:{keyword:"word"}}}]}
]};
''');
          final parts = source.categoryData!.categories;
          expect(parts[0].categories.single.target.sourceKey, source.key);
          expect(parts[0].categories.single.target.attributes, {
            'category': 'Tag',
            'param': 'group',
          });
          expect(parts[1].categories.single.label, 'Label');
          expect(parts[1].categories.single.target.attributes, {
            'keyword': 'word',
          });
        },
      );

      test(
        'dynamic category callbacks release before engine shutdown',
        () async {
          final source = await parse(dynamicCategoryScript);
          final part = source.categoryData!.categories.single;
          expect(part.categories.single.label, 'Dynamic');
          expect(part.categories.single.target.sourceKey, source.key);
        },
      );

      test(
        'removed source rejects retained dynamic callback without native access',
        () async {
          final source = await parse(dynamicCategoryScript);
          final part = source.categoryData!.categories.single;
          manager.remove(source.key);
          source.disposeRuntimeCallbacks();
          expect(() => part.categories, throwsStateError);
        },
      );

      test(
        'engine shutdown releases active source callbacks and prevents reuse',
        () async {
          final source = await parse(dynamicCategoryScript);
          final part = source.categoryData!.categories.single;
          final engine = JsEngine();
          engine.dispose();
          expect(() => part.categories, throwsStateError);
          await JsEngine().init();
          expect(() => part.categories, throwsStateError);
        },
      );

      test(
        'replacement rollback keeps old loader; commit releases it',
        () async {
          final original = await parse(dynamicCategoryScript);
          await File(
            original.filePath,
          ).writeAsString(sourceScript(dynamicCategoryScript));
          final oldPart = original.categoryData!.categories.single;
          for (var attempt = 0; attempt < 3; attempt++) {
            await expectLater(
              manager.replaceScript(
                original,
                sourceScript('${dynamicCategoryScript}comic = {idMatch: "["};'),
                validate: () {},
              ),
              throwsA(anything),
            );
            expect(oldPart.categories.single.label, 'Dynamic');
            expect(manager.find(original.key), same(original));
          }
          await manager.replaceScript(
            original,
            sourceScript(
              dynamicCategoryScript.replaceFirst(
                'label: "Dynamic"',
                'label: "Replacement"',
              ),
            ),
            validate: () {},
          );
          expect(() => oldPart.categories, throwsStateError);
          expect(
            manager
                .find(original.key)!
                .categoryData!
                .categories
                .single
                .categories
                .single
                .label,
            'Replacement',
          );
        },
      );

      test('static settings callback is released with its source', () async {
        final source = await parse(settingsCallbacksScript);
        final callback = source.settings!['action']!['callback'];
        expect(callback(['value']), [1, 'value']);
        manager.remove(source.key);
        expect(() => callback([]), throwsStateError);
      });

      test(
        'dynamic settings snapshots have independent bounded lifetimes',
        () async {
          final source = await parse(settingsCallbacksScript);
          final firstScope = source.createSettingsCallbackScope();
          final first = source.getSettingsDynamic(
            callbacks: firstScope,
          )!['action']!['callback'];
          final secondScope = source.createSettingsCallbackScope();
          final second = source.getSettingsDynamic(
            callbacks: secondScope,
          )!['action']!['callback'];
          expect(first(['a']), [2, 'a']);
          expect(second(['b']), [3, 'b']);
          firstScope.dispose();
          firstScope.dispose();
          expect(() => first([]), throwsStateError);
          expect(second(['c']), [3, 'c']);
          for (var index = 0; index < 20; index++) {
            final scope = source.createSettingsCallbackScope();
            final callback = source.getSettingsDynamic(
              callbacks: scope,
            )!['action']!['callback'];
            scope.dispose();
            expect(() => callback([]), throwsStateError);
          }
          manager.remove(source.key);
          expect(() => second([]), throwsStateError);
          expect(() => secondScope.fork(), throwsStateError);
        },
      );

      test(
        'settings getter failure falls back to source-owned static callback',
        () async {
          final source = await parse(settingsCallbacksScript);
          JsEngine().runCode(
            'void (ComicSource.sources.transaction_a.failSettings = true)',
          );
          final scope = source.createSettingsCallbackScope();
          final fallback = source.getSettingsDynamic(
            callbacks: scope,
          )!['action']!['callback'];
          scope.dispose();
          expect(fallback(['fallback']), [1, 'fallback']);
          manager.remove(source.key);
          expect(() => fallback([]), throwsStateError);
        },
      );

      test(
        'parse failure after settings registration releases native callbacks',
        () async {
          for (var attempt = 0; attempt < 3; attempt++) {
            await expectLater(
              parse('${settingsCallbacksScript}comic = {idMatch:"["};'),
              throwsA(anything),
            );
            expect(
              JsEngine().runCode('ComicSource.sources.transaction_a == null'),
              isTrue,
            );
          }
        },
      );

      test(
        'invalid dynamic loader reports actionable parse error and rolls back runtime',
        () async {
          await expectLater(
            parse(
              'category = {title:"Categories", parts:[{name:"dynamic", type:"dynamic", loader:42}]};',
            ),
            throwsA(
              predicate(
                (error) => error.toString().contains(
                  'DynamicCategoryPart loader must be a function',
                ),
              ),
            ),
          );
          expect(
            JsEngine().runCode('ComicSource.sources.transaction_a == null'),
            isTrue,
          );
        },
      );

      test(
        'empty category sections do not prevent source installation',
        () async {
          final source = await parse(
            'category = {title: "Categories", parts: [{name:"empty", type:"fixed", categories: []}]};',
          );
          expect(source.categoryData!.categories, isEmpty);
        },
      );
    },
    skip: nativeAvailable
        ? false
        : 'QuickJS native library unavailable; run with platform build DLLs on PATH.',
  );
}

String sourceScript(String capabilities) =>
    '''
class MatrixSource extends ComicSource {
  name = "Matrix";
  key = "transaction_a";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  $capabilities
}
''';

const accountScript = r'''
  events = [];
  logins = 0;
  account = {
    login: (user, password) => {
      this.logins++;
      if (this.failLogin) throw new Error("invalid credentials");
      this.credentials = [user, password];
    },
    logout: () => { this.events.push("logout"); },
    loginWithWebview: {url: "login", checkStatus: (url, title) => url === "done" && title === "title",
      onLoginSuccess: () => { this.events.push("webview"); }},
    loginWithCookies: {fields: ["session"], validate: (cookies) => cookies[0] === "cookie"}
  };
''';
const favoritesScript = r'''
  attempts = 0;
  favorites = {
    multiFolder: true,
    loadComics: (page, folder) => {
      this.attempts++;
      if (this.attempts === 1) throw new Error("Login expired");
      return {comics: [], maxPage: 3};
    },
    loadFolders: (id) => ({folders: {f: "Folder"}, favorited: ["f"]}),
    addFolder: (name) => {}, deleteFolder: (id) => {}
  };
''';
const cursorScript = r'''
  calls = [];
  search = {loadNext: (...args) => {this.calls.push(args); return {comics: [], next: "search-next"};}};
  explore = [{title: "Explore", type: "multiPageComicList", loadNext: (...args) => {
    this.calls.push(args); return {comics: [], next: "explore-next"};}}];
  categoryComics = {
    ranking: {options: ["rank-Ranking"], loadWithNext: (...args) => {
      this.calls.push(args); return {comics: [], next: "rank-next"};}},
    load: (...args) => { this.calls.push(args); return {comics: [], maxPage: 6}; },
    optionLoader: (...args) => { this.calls.push(args); return [{label: "Options", options: ["a-Alpha-Beta"]}]; }
  };
''';

const dynamicCategoryScript = r'''
  category = {title: "Categories", parts: [{name: "dynamic", type: "dynamic",
    loader: () => [{label: "Dynamic", target: {page: "search", attributes: {keyword: "word"}}}]
  }]};
''';

const settingsCallbacksScript = r'''
  reads = 0;
  get settings() {
    if (this.failSettings) throw new Error("settings failed");
    const snapshot = ++this.reads;
    return { action: {type: "callback", title: "Action", callback: (args) => [snapshot, args]},
      ignored: () => "unused" };
  }
''';
