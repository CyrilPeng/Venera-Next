import 'dart:typed_data';
import 'package:dio/dio.dart';

ResponseBody dataSyncResponse(
  int status, {
  List<int> bytes = const [],
  Map<String, List<String>> headers = const {},
}) => ResponseBody(
  Stream.value(Uint8List.fromList(bytes)),
  status,
  headers: {
    'content-length': ['${bytes.length}'],
    ...headers,
  },
);
