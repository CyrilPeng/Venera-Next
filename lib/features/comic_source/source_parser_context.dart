import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/res.dart';
import 'models.dart';
import 'normalization.dart';

/// Immutable identity shared by the capability parsers for one source.
class SourceParserContext {
  const SourceParserContext({
    required this.key,
    required this.name,
    required this.callbacks,
  });
  final String key;
  final String name;
  final JsCallbackScope callbacks;

  bool checkExists(String index) =>
      JsEngine().runCode('${_propertyPath(index)} != null');
  dynamic getValue(String index) => JsEngine().runCode(_propertyPath(index));
  String _propertyPath(String index) =>
      'ComicSource.sources.$key?.${index.replaceAll(RegExp(r'(?<!\?)\.'), '?.')}';

  Res<List<Comic>> parseComicListResult(dynamic value, String subDataKey) {
    final data = normalizeComicSourceStringKeyedMap(value);
    final comics = normalizeComicSourceComicList(data?["comics"], key);
    if (data == null || comics == null) throw "Invalid data";
    return Res(comics, subData: data[subDataKey]);
  }
}
