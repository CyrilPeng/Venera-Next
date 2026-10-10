import 'package:venera_next/features/history/image_favorites.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/history/history_scope.dart';
import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/app_runtime/data_sync.dart';
import 'package:venera_next/app_runtime/bootstrap_core.dart';
import 'package:venera_next/app_runtime/core_bootstrap.dart';
import 'package:venera_next/app_runtime/application_host.dart';
import 'package:venera_next/app_runtime/application_updates.dart';
import 'package:venera_next/components/application_update_prompt.dart';
import 'package:venera_next/app_runtime/image_loading.dart';
import 'package:venera_next/app_runtime/follow_updates.dart';
import 'package:venera_next/app_runtime/webdav_library.dart';
import 'package:venera_next/features/reader/reader.dart'
    show ReaderPlatformEffectsScope, ReaderSessionScope;
import 'package:venera_next/features/follow_updates/follow_updates.dart';
import 'package:venera_next/app_runtime/background_sync.dart';
import 'package:venera_next/app_runtime/interactive_platform_bindings.dart';
import 'package:venera_next/app_runtime/window_placement.dart';
import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'dart:async';
import 'package:venera_next/app_runtime/sync_window_binding.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:venera_next/app_runtime/app_runtime.dart';
import 'package:venera_next/app_shell/app_shell.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'components/gesture.dart';
import 'components/js_ui.dart';
import 'components/message.dart';
import 'components/window_frame.dart';
import 'components/window_selection_task.dart';
import 'foundation/app.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'foundation/app_locale.dart';
import 'foundation/appdata.dart';
import 'foundation/context.dart';
import 'foundation/js_engine.dart';
import 'features/webdav_library/webdav_library.dart';
import 'features/sync/sync.dart';
import 'features/comic_source/comic_source_api.dart';
import 'features/comic_source/comic_source_ui.dart';
import 'features/comic_source/source_repositories.dart';
import 'network/app_dio.dart';

void main(List<String> args) {
  if (args.contains('--headless')) {
    runHeadlessMode(args);
    return;
  }
  if (runWebViewTitleBarWidget(args)) return;
  overrideIO(() {
    runZonedGuarded(
      () async {
        WidgetsFlutterBinding.ensureInitialized();
        registerShowMessageHandler((context, message) {
          showToast(message: message, context: context);
        });
        JsEngine().bindUiMessageHandler(JsUiApi());
        final sync = createApplicationDataSync();
        final core = createCoreBootstrap(onDataChanged: sync.onDataChanged);
        try {
          await init(core);
        } catch (error, stack) {
          await rollbackCoreStartup(
            [
              (name: 'sync', close: sync.closeAndWait),
              (name: 'core', close: core.close),
            ],
            error,
            stack,
          );
          Error.throwWithStackTrace(error, stack);
        }
        final placement = App.isDesktop
            ? WindowPlacementHost.platform(
                dataPath: App.dataPath,
                linux: App.isLinux,
                macos: App.isMacOS,
              )
            : null;
        final host = ApplicationHost(
          core: core,
          sync: sync,
          placement: placement,
          sourceInstallations: SourceInstallations(
            manager: ComicSourceManager(),
            repositories: SourceRepositories.instance,
            createClient: AppDio.new,
          ),
        );
        runApp(MyApp(host: host));
        await placement?.initialize();
      },
      (error, stack) {
        Log.error("Unhandled Exception", error, stack);
      },
    );
  });
}

class MyApp extends StatefulWidget {
  const MyApp({super.key, required this.host});

  /// The host owns this controller beyond an individual widget mount.
  final ApplicationHost host;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  late final _library = webDavLibrary;
  late final _interactiveBindings = createPlatformInteractiveBindings(
    placement: widget.host.placement?.attach(),
  );
  late final _dataSync = widget.host.sync;
  ApplicationMount? _mount;
  late final _followUpdates = createFollowUpdatesRuntime(_dataSync);
  late final _backgroundSync = BackgroundSync.platform(_dataSync);
  late final _startupUpdates = createStartupUpdateCheck(
    sources: widget.host.sourceUpdates,
    checkApplication: (scope) async {
      if (!mounted || widget.host.isClosing) return;
      final navigator = appNavigation.rootNavigatorKey.currentState;
      final context = navigator?.overlay?.context;
      if (context == null || !context.mounted) return;
      await ApplicationUpdatePrompt(
        context: context,
        service: widget.host.applicationUpdates,
        parent: scope,
        isActive: () => mounted && !widget.host.isClosing,
      ).check(silent: true, delay: const Duration(seconds: 2));
    },
  );

  @override
  void initState() {
    super.initState();
    if (widget.host.isClosing) return;
    _mount = widget.host.attach(
      stop: () {
        _backgroundSync.stop();
        _startupUpdates.cancel();
      },
      close: () => closeApplicationMountBindings(
        followUpdates: _followUpdates,
        interactive: _interactiveBindings,
        closeStartupUpdates: _startupUpdates.closeAndWait,
      ),
    );
    mountWebDavLibrary(_library);
    appNavigation.registerForceRebuild(forceRebuild);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.host.isClosing) {
        _interactiveBindings.start();
        _backgroundSync.start();
        _followUpdates.start();
        unawaited(
          _startupUpdates.start().catchError((Object error, StackTrace stack) {
            Log.error('Startup update check', error, stack);
          }),
        );
      }
    });
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    if (_mount == null) {
      super.dispose();
      return;
    }
    WidgetsBinding.instance.removeObserver(this);
    appNavigation.registerForceRebuild(null);
    hideContentOverlay?.remove();
    hideContentOverlay = null;
    unawaited(
      _mount!.closeAndWait().catchError((Object error, StackTrace stack) {
        Log.error('Interactive bindings', error, stack);
      }),
    );
    super.dispose();
  }

  bool isAuthPageActive = false;

  OverlayEntry? hideContentOverlay;

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (mounted &&
        GlobalPreferenceStore(appdata.settings).read(AppPreferences.language) ==
            'system') {
      forceRebuild();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.host.isClosing) return;
    if (state == AppLifecycleState.resumed) {
      _dataSync.checkForAutomaticSync();
      _library.source.synchronizer.checkForAutomaticSync();
    }
    if (!App.isMobile ||
        !GlobalPreferenceStore(
          appdata.settings,
        ).read(AppPreferences.authorizationRequired)) {
      return;
    }
    if (state == AppLifecycleState.inactive && hideContentOverlay == null) {
      hideContentOverlay = OverlayEntry(
        builder: (context) {
          return Positioned.fill(
            child: Container(
              width: double.infinity,
              height: double.infinity,
              color: appNavigation.rootContext.colorScheme.surface,
            ),
          );
        },
      );
      Overlay.of(appNavigation.rootContext).insert(hideContentOverlay!);
    } else if (hideContentOverlay != null &&
        state == AppLifecycleState.resumed) {
      hideContentOverlay!.remove();
      hideContentOverlay = null;
    }
    if (state == AppLifecycleState.hidden &&
        !isAuthPageActive &&
        !IO.isSelectingFiles) {
      isAuthPageActive = true;
      appNavigation.rootContext.to(
        () => AuthPage(
          onSuccessfulAuth: () {
            appNavigation.rootContext.pop();
            isAuthPageActive = false;
          },
        ),
      );
    }
    super.didChangeAppLifecycleState(state);
  }

  void forceRebuild() {
    if (!mounted || widget.host.isClosing) return;
    void rebuild(Element el) {
      el.markNeedsBuild();
      el.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
    setState(() {});
  }

  Color translateColorSetting() {
    return switch (GlobalPreferenceStore(appdata.settings).appearance.color) {
      'red' => Colors.red,
      'pink' => Colors.pink,
      'purple' => Colors.purple,
      'green' => Colors.green,
      'orange' => Colors.orange,
      'blue' => Colors.blue,
      'yellow' => Colors.yellow,
      'cyan' => Colors.cyan,
      _ => Colors.blue,
    };
  }

  ThemeData getTheme(
    Color primary,
    Color? secondary,
    Color? tertiary,
    Brightness brightness,
  ) {
    String? font;
    List<String>? fallback;
    if (App.isLinux || App.isWindows) {
      font = 'Noto Sans CJK';
      fallback = [
        'Segoe UI',
        'Noto Sans SC',
        'Noto Sans TC',
        'Noto Sans',
        'Microsoft YaHei',
        'PingFang SC',
        'Arial',
        'sans-serif',
      ];
    }
    return ThemeData(
      colorScheme: SeedColorScheme.fromSeeds(
        primaryKey: primary,
        secondaryKey: secondary,
        tertiaryKey: tertiary,
        brightness: brightness,
        tones: FlexTones.vividBackground(brightness),
      ),
      fontFamily: font,
      fontFamilyFallback: fallback,
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          mouseCursor: WidgetStatePropertyAll(SystemMouseCursors.click),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          mouseCursor: WidgetStatePropertyAll(SystemMouseCursors.click),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          mouseCursor: WidgetStatePropertyAll(SystemMouseCursors.click),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          mouseCursor: WidgetStatePropertyAll(SystemMouseCursors.click),
        ),
      ),
      listTileTheme: ListTileThemeData(),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_mount == null) {
      return MaterialApp(
        builder: (_, child) => WindowFrame(
          child!,
          isFinalizing: () => widget.host.isClosing,
          finalize: (drain) => widget.host.close(drain: drain),
        ),
        home: const SizedBox.expand(),
      );
    }
    Widget home;
    if (GlobalPreferenceStore(
      appdata.settings,
    ).read(AppPreferences.authorizationRequired)) {
      home = AuthPage(
        onSuccessfulAuth: () {
          appNavigation.rootContext.toReplacement(() => const MainPage());
        },
      );
    } else {
      home = const MainPage();
    }
    return DynamicColorBuilder(
      builder: (light, dark) {
        Color? primary, secondary, tertiary;
        if (GlobalPreferenceStore(appdata.settings).appearance.color !=
                'system' ||
            light == null ||
            dark == null) {
          primary = translateColorSetting();
        } else {
          primary = light.primary;
          secondary = light.secondary;
          tertiary = light.tertiary;
        }
        return MaterialApp(
          title: "VeneraNext",
          home: home,
          debugShowCheckedModeBanner: false,
          theme: getTheme(primary, secondary, tertiary, Brightness.light),
          navigatorKey: appNavigation.rootNavigatorKey,
          darkTheme: getTheme(primary, secondary, tertiary, Brightness.dark),
          themeMode: switch (GlobalPreferenceStore(
            appdata.settings,
          ).appearance.themeMode) {
            'light' => ThemeMode.light,
            'dark' => ThemeMode.dark,
            _ => ThemeMode.system,
          },
          color: Colors.transparent,
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          locale: appLocale,
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('zh', 'TW'),
            Locale('en'),
          ],
          builder: (context, widget) {
            ErrorWidget.builder = (details) {
              Log.error(
                "Unhandled Exception",
                "${details.exception}\n${details.stack}",
              );
              return Material(
                child: Center(child: Text(details.exception.toString())),
              );
            };
            if (widget != null) {
              /// 如果无法检测到状态栏高度设定指定高度
              /// https://github.com/flutter/flutter/issues/161086
              var isPaddingCheckError =
                  MediaQuery.of(context).viewPadding.top <= 0 ||
                  MediaQuery.of(context).viewPadding.top > 200;

              if (isPaddingCheckError && Platform.isAndroid) {
                widget = MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    viewPadding: const EdgeInsets.only(top: 15, bottom: 15),
                    padding: const EdgeInsets.only(top: 15, bottom: 15),
                  ),
                  child: widget,
                );
              }

              widget = FavoritesScope(
                manager: LocalFavoritesManager(),
                child: HistoryScope(
                  manager: HistoryManager(),
                  imageFavorites: ImageFavoriteManager(),
                  child: widget,
                ),
              );
              widget = ReaderPlatformEffectsScope(child: OverlayWidget(widget));
              if (App.isDesktop) {
                widget = WindowFrame(
                  Shortcuts(
                    shortcuts: {
                      LogicalKeySet(LogicalKeyboardKey.escape):
                          VoidCallbackIntent(appNavigation.pop),
                    },
                    child: MouseBackDetector(
                      onTapDown: appNavigation.pop,
                      child: SyncWindowBinding(
                        controller: _dataSync,
                        waitForHistoryWrites:
                            HistoryManager().waitForAsyncWrites,
                        isFinalizing: () => this.widget.host.isClosing,
                        prepareInteractive: _interactiveBindings.prepareForExit,
                        prepareFollowUpdates: () =>
                            prepareApplicationFollowUpdatesForExit(
                              _followUpdates,
                            ),
                        prepareWebDavLibrary: _library.source.prepareForExit,
                        prepareImages: prepareImageLoadingForExit,
                        cancelStartupUpdates: _startupUpdates.cancel,
                        closeStartupUpdates: _startupUpdates.closeAndWait,
                        child: widget,
                      ),
                    ),
                  ),
                  debugAction: reloadComicSourcesForDebug,
                  finalize: (drain) => this.widget.host.close(drain: drain),
                  isFinalizing: () => this.widget.host.isClosing,
                );
              }
              widget = FollowUpdatesScope(
                runtime: _followUpdates,
                child: widget,
              );
              widget = SelectionTasksScope(
                registry: this.widget.host.selections,
                child: widget,
              );
              widget = ReaderSessionScope(
                onClosed: _dataSync.onDataChanged,
                child: widget,
              );
              widget = DataSyncScope(controller: _dataSync, child: widget);
              widget = ApplicationUpdateScope(
                service: this.widget.host.applicationUpdates,
                child: widget,
              );
              widget = WebDavLibraryScope(services: _library, child: widget);
              final installations = this.widget.host.sourceInstallations;
              if (installations != null) {
                widget = SourceInstallationsScope(
                  queue: installations,
                  updates: this.widget.host.sourceUpdates,
                  refresh: forceRebuild,
                  child: widget,
                );
              }
              return _SystemUiProvider(
                Material(
                  color: App.isLinux ? Colors.transparent : null,
                  child: widget,
                ),
              );
            }
            throw ('widget is null');
          },
        );
      },
    );
  }
}

class _SystemUiProvider extends StatelessWidget {
  const _SystemUiProvider(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    var brightness = Theme.of(context).brightness;
    SystemUiOverlayStyle systemUiStyle;
    if (brightness == Brightness.light) {
      systemUiStyle = SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
      );
    } else {
      systemUiStyle = SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      );
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemUiStyle,
      child: child,
    );
  }
}
