import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/network/request_scope.dart';

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
          '${directory.path}/comic_source/matrix.js',
        );
        manager.add(source);
        return source;
      }

      for (final read in _R1Read.values) {
        test('R1 $read releases result and failure references', () async {
          final source = await parse(_r1ReadScript(read));
          await source.editData(
            (draft) => draft['account'] = ['user', 'password'],
          );
          final result = await read.call(source);
          expect(result.success, isTrue);
          if (read == _R1Read.exploreMixed) {
            final part = (result.data as List).last as ExplorePagePart;
            expect(part.viewMore!.page, 'search');
          }
          final engine = JsEngine();
          expect(engine.debugOwnedReferenceCount, 0);
          engine.runCode(
            'void (ComicSource.sources.transaction_a.mode = "reject")',
          );
          final failed = await read.call(source);
          expect(failed.failure!.kind, FailureKind.failed);
          final cause = failed.failure!.cause as Map;
          expect(cause['marker'], 'synthetic failure');
          expect(
            () => (cause['callback'] as JSInvokable)([]),
            throwsA(isA<JsDisposedError>()),
          );
          expect(engine.debugOwnedReferenceCount, 0);
        });

        test(
          'R1 $read cancellation drains original Promise and keeps late errors',
          () async {
            final source = await parse(_r1ReadScript(read));
            await source.editData(
              (draft) => draft['account'] = ['user', 'password'],
            );
            final engine = JsEngine();
            engine.runCode(
              'void (ComicSource.sources.transaction_a.mode = "pending")',
            );
            for (final reject in [false, true]) {
              final scope = RequestScope();
              Res<Object?>? observed;
              Object? operationError;
              var ended = false;
              final work = scope
                  .runToCompletion(() async {
                    observed = await read.call(source);
                  })
                  .then<void>(
                    (_) => ended = true,
                    onError: (Object error, StackTrace stack) {
                      operationError = error;
                      ended = true;
                    },
                  );
              await pumpEventQueue();
              scope.cancel();
              await pumpEventQueue();
              final endedEarly = ended;
              engine.runCode(
                reject
                    ? 'void failR1Read({marker:"late rejection",callback:()=>42})'
                    : 'void finishR1Read()',
              );
              await work;
              scope.dispose();
              expect(endedEarly, isFalse);
              expect(operationError, isA<RequestCancelled>());
              if (reject) {
                expect(observed!.failure!.kind, FailureKind.failed);
                expect(
                  (observed!.failure!.cause as Map)['marker'],
                  'late rejection',
                );
              } else {
                expect(observed!.failure!.kind, FailureKind.cancelled);
                expect(observed!.failure!.cause, isA<RequestCancelled>());
              }
              expect(observed!.failure!.stackTrace, isNotNull);
              expect(engine.debugOwnedReferenceCount, 0);
            }
          },
        );
      }

      for (final action in [
        'status',
        'tag',
        'suggestion',
        'link',
        'category',
      ]) {
        test(
          'R1 synchronous $action releases native result and rejection graphs',
          () async {
            final source = await parse(r'''
            fail = false;
            act(value) {
              if (this.fail) throw {marker:'synchronous failure',callback:()=>42};
              return value;
            }
            account = {loginWithWebview:{url:'login',checkStatus:()=>this.act(true)}};
            search = {onTagSuggestionSelected:()=>this.act('suggested')};
            comic = {
              onClickTag:()=>this.act({page:'search',attributes:{keyword:'word'},extra:()=>42}),
              link:{domains:['example.invalid'],linkToId:()=>this.act('book')}
            };
            category = {title:'Categories',parts:[{name:'Dynamic',type:'dynamic',
              loader:()=>this.act([{label:'Tag',target:'search:word',extra:()=>42}])}]};
          ''');
            Object? invoke() => switch (action) {
              'status' => source.account!.checkLoginStatus!('url', 'title'),
              'tag' => source.handleClickTagEvent!('namespace', 'tag'),
              'suggestion' => source.onTagSuggestionSelected!(
                'namespace',
                'tag',
              ),
              'link' => source.linkHandler!.linkToId(
                'https://example.invalid/book',
              ),
              _ => source.categoryData!.categories.single.categories,
            };
            expect(invoke(), isNotNull);
            final engine = JsEngine();
            engine.runCode(
              'void (ComicSource.sources.transaction_a.fail = true)',
            );
            Object? failure;
            try {
              invoke();
            } catch (error) {
              failure = error;
            }
            expect(failure, isA<Map>());
            final callback = (failure as Map)['callback'] as JSInvokable;
            expect(() => callback([]), throwsA(anything));
          },
        );
      }

      test(
        'R1 unsupported synchronous Promise is observed and releases late references',
        () async {
          final source = await parse(r'''
          search = {onTagSuggestionSelected:()=>new Promise(resolve=>{globalThis.finishSuggestion=resolve;})};
        ''');
          expect(
            source.onTagSuggestionSelected!('namespace', 'tag'),
            'namespace:tag',
          );
          final engine = JsEngine();
          engine.runCode('void finishSuggestion({callback:()=>42})');
          await pumpEventQueue();
          expect(engine.debugOwnedReferenceCount, 0);
        },
      );

      for (final action in ['login', 'logout', 'webview']) {
        test(
          'R1 account $action never retries a potentially applied action',
          () async {
            final source = await parse('''
            calls = 0;
            act() { ++this.calls; throw 'Connection reset by peer'; }
            account = {
              login: () => this.act(), logout: () => this.act(),
              loginWithWebview: {url:'login',checkStatus:()=>false,onLoginSuccess:()=>this.act()}
            };
          ''');
            Object? failure;
            try {
              if (action == 'login') {
                failure = (await source.account!.login!(
                  'user',
                  'password',
                )).failure;
              } else if (action == 'logout') {
                await source.account!.logout();
              } else {
                await source.account!.onLoginWithWebviewSuccess!();
              }
            } catch (error) {
              failure = error;
            }
            expect(failure, isNotNull);
            expect(
              JsEngine().runCode('ComicSource.sources.transaction_a.calls'),
              1,
            );
          },
        );
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
            await source.editData(
              (draft) => draft['account'] = ['user', 'password'],
            );
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
          await source.editData(
            (draft) => draft['account'] = ['user', 'password'],
          );
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

enum _R1Read {
  searchPage,
  searchCursor,
  favoritesPage,
  favoritesCursor,
  folders,
  categoryOptions,
  categoryPage,
  rankingPage,
  rankingCursor,
  explorePage,
  exploreCursor,
  explorePartsLegacy,
  exploreParts,
  exploreMixed;

  Future<Res<Object?>> call(ComicSource source) => switch (this) {
    searchPage => source.searchPageData!.loadPage!('keyword', 1, []),
    searchCursor => source.searchPageData!.loadNext!('keyword', null, []),
    favoritesPage => source.favoriteData!.loadComic!(1, 'folder'),
    favoritesCursor => source.favoriteData!.loadNext!(null, 'folder'),
    folders => source.favoriteData!.loadFolders!('comic'),
    categoryOptions => source.categoryComicsData!.optionsLoader!(
      'category',
      null,
    ),
    categoryPage => source.categoryComicsData!.load('category', null, [], 1),
    rankingPage => source.categoryComicsData!.rankingData!.load!('option', 1),
    rankingCursor => source.categoryComicsData!.rankingData!.loadWithNext!(
      'option',
      null,
    ),
    explorePage => source.explorePages.single.loadPage!(1),
    exploreCursor => source.explorePages.single.loadNext!(null),
    explorePartsLegacy ||
    exploreParts => source.explorePages.single.loadMultiPart!(),
    exploreMixed => source.explorePages.single.loadMixed!(1),
  };
}

String _r1ReadScript(_R1Read read) {
  const book = "{id:'one',title:'Book',cover:'',tags:['tag'],unused:()=>42}";
  const list = "{comics:[$book],maxPage:3,next:'cursor',unused:()=>42}";
  const part =
      "{title:'Part',comics:[$book],viewMore:{page:'search',attributes:{keyword:'word'}},unused:()=>42}";
  final capability = switch (read) {
    _R1Read.searchPage => "search = {load:()=>this.read($list)};",
    _R1Read.searchCursor => "search = {loadNext:()=>this.read($list)};",
    _R1Read.favoritesPage =>
      "favorites = {multiFolder:false,loadComics:()=>this.read($list)};",
    _R1Read.favoritesCursor =>
      "favorites = {multiFolder:false,loadNext:()=>this.read($list)};",
    _R1Read.folders =>
      "favorites = {multiFolder:true,loadFolders:()=>this.read({folders:{f:'Folder'},favorited:['f'],unused:()=>42})};",
    _R1Read.categoryOptions =>
      "categoryComics = {optionLoader:()=>this.read([{label:'Options',options:['one-First'],unused:()=>42}])};",
    _R1Read.categoryPage => "categoryComics = {load:()=>this.read($list)};",
    _R1Read.rankingPage =>
      "categoryComics = {ranking:{options:['one-First'],load:()=>this.read($list)}};",
    _R1Read.rankingCursor =>
      "categoryComics = {ranking:{options:['one-First'],loadWithNext:()=>this.read($list)}};",
    _R1Read.explorePage =>
      "explore = [{title:'Explore',type:'multiPageComicList',load:()=>this.read($list)}];",
    _R1Read.exploreCursor =>
      "explore = [{title:'Explore',type:'multiPageComicList',loadNext:()=>this.read($list)}];",
    _R1Read.explorePartsLegacy =>
      "explore = [{title:'Explore',type:'singlePageWithMultiPart',load:()=>this.read({Part:[$book]})}];",
    _R1Read.exploreParts =>
      "explore = [{title:'Explore',type:'multiPartPage',load:()=>this.read([$part])}];",
    _R1Read.exploreMixed =>
      "explore = [{title:'Explore',type:'mixed',load:()=>this.read({data:[[$book],$part],maxPage:3})}];",
  };
  return '''
    $accountScript
    mode = 'success'; reads = 0;
    read(payload) {
      ++this.reads;
      if (this.mode === 'reject') return Promise.reject({marker:'synthetic failure',callback:()=>42});
      if (this.mode === 'pending') return new Promise((resolve,reject)=>{
        globalThis.finishR1Read = () => resolve(payload); globalThis.failR1Read = reject;
      });
      return payload;
    }
    $capability
  ''';
}

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
