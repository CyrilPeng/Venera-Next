import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:yaml/yaml.dart';

import 'appdata.dart';

class _App {
  String version = "0.0.0";

  bool get isAndroid => Platform.isAndroid;

  bool get isIOS => Platform.isIOS;

  bool get isWindows => Platform.isWindows;

  bool get isLinux => Platform.isLinux;

  bool get isMacOS => Platform.isMacOS;

  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  // Whether the app has been initialized.
  // If current Isolate is main Isolate, this value is always true.
  bool isInitialized = false;

  Locale get locale {
    final selected = switch (appdata.settings['language']) {
      'zh-CN' => const Locale('zh', 'CN'),
      'zh-TW' => const Locale('zh', 'TW'),
      'en-US' => const Locale('en'),
      _ => null,
    };
    if (selected != null) return selected;

    for (final locale in PlatformDispatcher.instance.locales) {
      if (locale.languageCode == 'zh') {
        // Script takes priority over region: zh-Hans-US is simplified Chinese.
        // Older locale identifiers may only provide a region, such as zh-HK.
        final traditional = switch (locale.scriptCode) {
          'Hant' => true,
          'Hans' => false,
          _ => const ['TW', 'HK', 'MO'].contains(locale.countryCode),
        };
        return Locale('zh', traditional ? 'TW' : 'CN');
      }
      if (locale.languageCode == 'en') return const Locale('en');
    }
    return const Locale('en');
  }

  late String dataPath;
  late String cachePath;
  String? externalStoragePath;

  final rootNavigatorKey = GlobalKey<NavigatorState>();

  GlobalKey<NavigatorState>? mainNavigatorKey;

  BuildContext get rootContext => rootNavigatorKey.currentContext!;

  final Appdata data = appdata;

  static const _windowsCompanyDirectory = 'com.github.cyrilpeng';
  static const _windowsProductDirectory = 'VeneraNext';
  static const _legacyWindowsDirectories = [
    ('CyrilPeng_venera-next', 'VeneraNext'),
    ('CyrilPeng_venera-next', 'venera'),
    ('com.github.wgh136', 'venera'),
  ];

  void rootPop() {
    rootNavigatorKey.currentState?.maybePop();
  }

  void pop() {
    if (rootNavigatorKey.currentState?.canPop() ?? false) {
      rootNavigatorKey.currentState?.pop();
    } else if (mainNavigatorKey?.currentState?.canPop() ?? false) {
      mainNavigatorKey?.currentState?.pop();
    }
  }

  Future<void> init() async {
    await _initVersion();
    cachePath = (await getApplicationCacheDirectory()).path;
    dataPath = (await getApplicationSupportDirectory()).path;
    if (isWindows) {
      await _migrateLegacyWindowsPath(cachePath);
      await _migrateLegacyWindowsPath(dataPath);
    }
    if (isAndroid) {
      externalStoragePath = (await getExternalStorageDirectory())!.path;
    }
    isInitialized = true;
  }

  @visibleForTesting
  Future<void> migrateLegacyWindowsPathForTesting(String currentPath) {
    return _migrateLegacyWindowsPath(currentPath);
  }

  Future<void> _migrateLegacyWindowsPath(String currentPath) async {
    final normalizedCurrentPath = p.normalize(currentPath);
    final appDirectoryName = p.basename(normalizedCurrentPath);
    final companyDirectory = p.basename(p.dirname(normalizedCurrentPath));
    if (companyDirectory != _windowsCompanyDirectory ||
        appDirectoryName != _windowsProductDirectory) {
      return;
    }

    final baseDirectory = p.dirname(p.dirname(normalizedCurrentPath));
    final currentDirectory = Directory(normalizedCurrentPath);
    if (!await currentDirectory.exists()) {
      await currentDirectory.create(recursive: true);
    }

    for (final (company, product) in _legacyWindowsDirectories) {
      final legacyDirectory = Directory(
        p.join(baseDirectory, company, product),
      );
      if (!await legacyDirectory.exists()) {
        continue;
      }
      await _copyMissingDirectoryContents(legacyDirectory, currentDirectory);
    }
  }

  Future<void> _copyMissingDirectoryContents(
    Directory source,
    Directory destination,
  ) async {
    if (!await destination.exists()) {
      await destination.create(recursive: true);
    }

    await for (final entity in source.list(followLinks: false)) {
      final targetPath = p.join(destination.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyMissingDirectoryContents(entity, Directory(targetPath));
      } else if (entity is File) {
        final target = File(targetPath);
        if (!await target.exists()) {
          await target.parent.create(recursive: true);
          await entity.copy(targetPath);
        }
      }
    }
  }

  Future<void> _initVersion() async {
    final pubspec = await rootBundle.loadString("pubspec.yaml");
    final data = loadYaml(pubspec);
    version = data["version"].toString().split('+').first;
  }

  Future<void> initComponents([
    Iterable<Future<void> Function()> featureInitializers = const [],
  ]) async {
    await Future.wait([
      data.init(),
      for (final initializer in featureInitializers) initializer(),
    ]);
  }

  Function? _forceRebuildHandler;

  void registerForceRebuild(Function handler) {
    _forceRebuildHandler = handler;
  }

  void forceRebuild() {
    _forceRebuildHandler?.call();
  }
}

// ignore: non_constant_identifier_names
final App = _App();
