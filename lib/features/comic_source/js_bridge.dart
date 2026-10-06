import 'dart:convert';

import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/js_engine.dart';

import 'source.dart';

final _constructionReads = <JsSourceIdentity, SourceConstructionReads>{};

/// Parsing may read the original source before the new Dart instance exists.
/// This narrowly scoped capability never grants writes to the previous owner.
class SourceConstructionReads {
  SourceConstructionReads(this.identity, {this.expectedKey}) {
    _constructionReads[identity] = this;
  }
  final JsSourceIdentity identity;
  final String? expectedKey;
  final _snapshots = <String, Map<String, dynamic>>{};
  final _owners = <String, ComicSource?>{};

  Map<String, dynamic> data(String key) =>
      AppDataOperations.instance.accessSync(() {
        if (expectedKey != null && key.isNotEmpty && key != expectedKey) {
          throw StateError('Constructed source key does not match its owner');
        }
        return _snapshots.putIfAbsent(key, () {
          final source = _owners.putIfAbsent(key, () => ComicSource.find(key));
          return Map<String, dynamic>.from(
            jsonDecode(jsonEncode(source?.data ?? {})),
          );
        });
      });

  Object? setting(String key, String settingKey) {
    final saved = data(key)['settings']?[settingKey];
    return saved ??
        _owners[key]?.settings?[settingKey]?['default'] ??
        (throw StateError('Setting not found: $settingKey'));
  }

  void dispose() {
    if (identical(_constructionReads[identity], this)) {
      _constructionReads.remove(identity);
    }
    _snapshots.clear();
    _owners.clear();
  }
}

ComicSource _source(JsSourceIdentity identity, String key) {
  return ComicSource.requireRuntime(key, identity);
}

void configureComicSourceJsDataBridge() {
  JsEngine.configureSourceDataBridge(
    JsSourceDataBridge(
      loadData: (identity, key, dataKey) {
        final construction = _constructionReads[identity];
        return construction != null
            ? construction.data(key)[dataKey]
            : _source(identity, key).data[dataKey];
      },
      saveData: (identity, key, dataKey, data) {
        _source(identity, key).editDataSync((draft) => draft[dataKey] = data);
      },
      deleteData: (identity, key, dataKey) {
        _source(identity, key).editDataSync((draft) => draft.remove(dataKey));
      },
      loadSetting: (identity, key, settingKey) {
        final construction = _constructionReads[identity];
        if (construction != null) return construction.setting(key, settingKey);
        final source = _source(identity, key);
        return source.data['settings']?[settingKey] ??
            source.settings?[settingKey]?['default'] ??
            (throw StateError('Setting not found: $settingKey'));
      },
      isLogged: (identity, key) {
        final construction = _constructionReads[identity];
        return construction != null
            ? construction.data(key)['account'] != null
            : _source(identity, key).isLogged;
      },
    ),
  );
}
