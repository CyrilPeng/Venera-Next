import 'dart:convert';

import 'package:dio/dio.dart';

bool isMalformedExpectedJsonResponse(Response<dynamic> response) {
  final statusCode = response.statusCode;
  if (statusCode == 204 || statusCode == 205) {
    return false;
  }

  final requestHeaders = response.requestOptions.headers;
  final accept = requestHeaders.entries
      .where((entry) => entry.key.toLowerCase() == 'accept')
      .map((entry) => entry.value.toString())
      .join(',')
      .toLowerCase();
  final contentType = response.headers
      .value(Headers.contentTypeHeader)
      ?.toLowerCase();
  final expectsJson =
      accept.contains('json') ||
      (contentType?.contains('json') ?? false) ||
      response.requestOptions.uri.path.toLowerCase().endsWith('.json');
  if (!expectsJson) {
    return false;
  }

  final data = response.data;
  if (data is Map || data is num || data is bool) {
    return false;
  }
  if (data is List && data is! List<int>) {
    return false;
  }

  try {
    final String text;
    if (data is String) {
      text = data;
    } else if (data is List<int>) {
      text = utf8.decode(data, allowMalformed: false);
    } else {
      return true;
    }
    jsonDecode(text);
    return false;
  } catch (_) {
    return true;
  }
}
