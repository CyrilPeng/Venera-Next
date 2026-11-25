import 'dart:convert';

import 'package:flutter/services.dart';

import 'app_locale.dart';

extension AppTranslation on String {
  String _translate() {
    return translations[appLanguage.translationKey]?[this] ?? this;
  }

  String get tl => _translate();

  String tlParams(Map<String, Object> values) {
    return _translate().replaceAllMapped(
      _placeholder,
      (match) =>
          values[match.group(0)!.substring(1)]?.toString() ?? match.group(0)!,
    );
  }

  static final _placeholder = RegExp(r'@[A-Za-z][A-Za-z0-9_]*');

  static Map<String, Map<String, String>> translations = const {};

  static Future<void> init() async {
    var data = await rootBundle.load("assets/translation.json");
    var json = jsonDecode(utf8.decode(data.buffer.asUint8List()));
    translations = {
      for (var e in json.entries) e.key: Map<String, String>.from(e.value),
    };
  }
}

extension ListTranslation on List<String> {
  List<String> _translate() {
    return List.generate(length, (index) => this[index].tl);
  }

  List<String> get tl => _translate();
}
