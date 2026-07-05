import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:yaml/yaml.dart';

import 'appdata.dart';

export "widget_utils.dart";
export "context.dart";

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
    Locale deviceLocale = PlatformDispatcher.instance.locale;
    if (deviceLocale.languageCode == "zh" &&
        deviceLocale.scriptCode == "Hant") {
      deviceLocale = const Locale("zh", "TW");
    }
    if (appdata.settings['language'] != 'system') {
      return Locale(
        appdata.settings['language'].split('-')[0],
        appdata.settings['language'].split('-')[1],
      );
    }
    return deviceLocale;
  }

  late String dataPath;
  late String cachePath;
  String? externalStoragePath;

  final rootNavigatorKey = GlobalKey<NavigatorState>();

  GlobalKey<NavigatorState>? mainNavigatorKey;

  BuildContext get rootContext => rootNavigatorKey.currentContext!;

  final Appdata data = appdata;

  static const _legacyWindowsCompanyDirectory = 'CyrilPeng_venera-next';
  static const _windowsCompanyDirectory = 'com.github.cyrilpeng';

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
    if (companyDirectory != _windowsCompanyDirectory) {
      return;
    }

    final baseDirectory = p.dirname(p.dirname(normalizedCurrentPath));
    final legacyPath = p.join(
      baseDirectory,
      _legacyWindowsCompanyDirectory,
      appDirectoryName,
    );
    if (p.equals(p.normalize(legacyPath), normalizedCurrentPath)) {
      return;
    }

    final legacyDirectory = Directory(legacyPath);
    if (!await legacyDirectory.exists()) {
      return;
    }

    final currentDirectory = Directory(normalizedCurrentPath);
    if (await currentDirectory.exists()) {
      if (!await currentDirectory.list(followLinks: false).isEmpty) {
        return;
      }
    } else {
      await currentDirectory.create(recursive: true);
    }

    await _copyDirectoryContents(legacyDirectory, currentDirectory);
  }

  Future<void> _copyDirectoryContents(
    Directory source,
    Directory destination,
  ) async {
    if (!await destination.exists()) {
      await destination.create(recursive: true);
    }

    await for (final entity in source.list(followLinks: false)) {
      final targetPath = p.join(destination.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectoryContents(entity, Directory(targetPath));
      } else if (entity is File) {
        await File(targetPath).parent.create(recursive: true);
        await entity.copy(targetPath);
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
