import 'package:venera_next/foundation/js_engine.dart';

import 'source.dart';

void configureComicSourceJsEngineBridge({
  required Object? Function(String key, String dataKey) loadData,
  required void Function(String key, String dataKey, Object? data) saveData,
  required void Function(String key, String dataKey) deleteData,
  required Object? Function(String key, String settingKey) loadSetting,
  required bool Function(String key) isLogged,
}) {
  JsEngine.configureSourceDataBridge(
    JsSourceDataBridge(
      loadData: loadData,
      saveData: saveData,
      deleteData: deleteData,
      loadSetting: loadSetting,
      isLogged: isLogged,
    ),
  );
}

void configureComicSourceJsDataBridge() {
  configureComicSourceJsEngineBridge(
    loadData: _loadSourceData,
    saveData: _saveSourceData,
    deleteData: _deleteSourceData,
    loadSetting: _loadSourceSetting,
    isLogged: _isSourceLogged,
  );
}

Object? _loadSourceData(String key, String dataKey) {
  return ComicSource.find(key)?.data[dataKey];
}

void _saveSourceData(String key, String dataKey, Object? data) {
  final source = ComicSource.find(key)!;
  source.data[dataKey] = data;
  source.saveData();
}

void _deleteSourceData(String key, String dataKey) {
  final source = ComicSource.find(key);
  source?.data.remove(dataKey);
  source?.saveData();
}

Object? _loadSourceSetting(String key, String settingKey) {
  final source = ComicSource.find(key)!;
  return source.data["settings"]?[settingKey] ??
      source.settings?[settingKey]!['default'] ??
      (throw "Setting not found: $settingKey");
}

bool _isSourceLogged(String key) {
  return ComicSource.find(key)!.isLogged;
}
