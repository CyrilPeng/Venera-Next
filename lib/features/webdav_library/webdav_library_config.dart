import 'dart:convert';

import 'package:venera_next/network/webdav.dart';

class WebDavLibraryConfig {
  WebDavLibraryConfig({
    required String url,
    required String user,
    required String pass,
    required String remotePath,
  }) : endpoint = WebDavEndpoint(url: url, user: user, password: pass),
       remotePath = normalizeWebDavDirectoryPath(
         remotePath,
         fallback: '/venera_comics/',
       );

  final WebDavEndpoint endpoint;
  final String remotePath;

  String get url => endpoint.url;

  String get user => endpoint.user;

  String get pass => endpoint.password;

  bool get isValid => endpoint.isValid;

  Map<String, String> get authHeaders => endpoint.authHeaders;

  String get cacheKey => jsonEncode([url, user, remotePath]);

  String get connectionKey => jsonEncode([url, user, pass, remotePath]);

  String childDirectoryPath(String name) {
    return childDirectoryPathFrom(remotePath, name);
  }

  String childFilePath(String parent, String name) {
    return joinWebDavFilePath(parent, name);
  }

  String childDirectoryPathFrom(String parent, String name) {
    return joinWebDavDirectoryPath(parent, name);
  }

  String fileUrl(String remoteFilePath) => endpoint.fileUrl(remoteFilePath);
}
