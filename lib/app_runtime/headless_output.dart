import 'dart:convert';

/// Stable line prefix consumed by headless clients.
void cliPrint(Map<String, dynamic> data) {
  print('[CLI PRINT] ${jsonEncode(data)}');
}
