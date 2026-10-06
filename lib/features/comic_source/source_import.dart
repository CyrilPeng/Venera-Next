import 'source_failure.dart';
import 'dart:convert';

import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/app_dio.dart';

import 'parser.dart' show sourceClassName;
import 'source_repositories.dart';
import 'source_text_request.dart';

class SourceImportNeedsBaseUrl implements Exception {
  @override
  String toString() =>
      'This list uses relative script paths. Enter the original list URL to resolve them.'
          .tl;
}

/// Previewing never evaluates a source or modifies installed sources.
class SourceImportPreview {
  const SourceImportPreview({
    required this.contents,
    required this.name,
    this.url,
    this.catalog,
  });

  final String contents, name;
  final String? url;
  final SourceCatalog? catalog;

  static SourceImportPreview parse(
    String contents, {
    String? url,
    String? baseUrl,
    String? fileName,
  }) {
    contents = contents.replaceFirst('\uFEFF', '').trim();
    if (contents.startsWith('[') || contents.startsWith('{')) {
      dynamic decoded;
      try {
        decoded = jsonDecode(contents);
      } catch (error, stack) {
        throw SourceFailure(
          SourceFailureCode.invalidCatalog,
          cause: error,
          stackTrace: stack,
        );
      }
      if (decoded is List && url == null && baseUrl == null) {
        for (final record in decoded.whereType<Map>()) {
          final target =
              record['url'] is String &&
                  (record['url'] as String).trim().isNotEmpty
              ? record['url']
              : record['fileName'];
          if (target is String &&
              target.trim().isNotEmpty &&
              Uri.tryParse(target.trim())?.hasScheme == false) {
            throw SourceImportNeedsBaseUrl();
          }
        }
      }
      return SourceImportPreview(
        contents: contents,
        name:
            fileName ?? (url == null ? 'Source list'.tl : Uri.parse(url).host),
        url: url,
        catalog: SourceRepositories.parseCatalog(
          contents,
          baseUrl: url ?? baseUrl,
        ),
      );
    }
    try {
      final className = sourceClassName(contents);
      return SourceImportPreview(
        contents: contents,
        name: fileName ?? className,
        url: url,
      );
    } catch (error, stack) {
      throw SourceFailure(
        SourceFailureCode.invalidImport,
        cause: error,
        stackTrace: stack,
      );
    }
  }

  static Future<SourceImportPreview> fromUrl(
    String url, {
    Dio? client,
    Dio Function()? createClient,
    CancelToken? cancelToken,
  }) async {
    url = SourceRepositories.normalizeUrl(url);
    final response = await readSourceText(
      url,
      client: client,
      createClient: createClient,
      cancelToken: cancelToken,
    );
    if (response.statusCode != 200 || response.data == null) {
      throw 'Failed to load source'.tl;
    }
    return parse(response.data!, url: response.realUri.toString());
  }
}
