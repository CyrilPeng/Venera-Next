/// Metadata codec for historical .venera-comics batches.
/// It does not implement archive I/O or a current user-facing import format.
library;

/// 漫画导出元信息
class ComicExportInfo {
  final String id;
  final String title;
  final String subtitle;
  final List<String> tags;
  final String directory;

  /// Chapter data as stored by the legacy ComicChapters.toJson protocol.
  /// May be a flat `Map<String, String>` or grouped `Map<String, Map<String, String>>`.
  final Map<String, dynamic> chapters;
  final String cover;
  final int comicType;
  final List<String> downloadedChapters;
  final int createdAt;
  final String sourceDirectory;

  ComicExportInfo({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.directory,
    required this.chapters,
    required this.cover,
    required this.comicType,
    required this.downloadedChapters,
    required this.createdAt,
    required this.sourceDirectory,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'subtitle': subtitle,
      'tags': tags,
      'directory': directory,
      'chapters': chapters,
      'cover': cover,
      'comicType': comicType,
      'downloadedChapters': downloadedChapters,
      'createdAt': createdAt,
      'sourceDirectory': sourceDirectory,
    };
  }

  factory ComicExportInfo.fromJson(Map<String, dynamic> json) {
    String asString(dynamic value, String field) {
      if (value is String) return value;
      throw FormatException(
        'Invalid metadata: "$field" must be a String, got ${value.runtimeType}',
      );
    }

    int asInt(dynamic value, String field) {
      if (value is int) return value;
      throw FormatException(
        'Invalid metadata: "$field" must be an int, got ${value.runtimeType}',
      );
    }

    List<String> asStringList(dynamic value, String field) {
      if (value is List) {
        return value.map((e) {
          if (e is String) return e;
          throw FormatException(
            'Invalid metadata: items in "$field" must be Strings',
          );
        }).toList();
      }
      throw FormatException(
        'Invalid metadata: "$field" must be a List, got ${value.runtimeType}',
      );
    }

    Map<String, dynamic> asStringMap(dynamic value, String field) {
      if (value is Map) {
        return value.map((k, v) {
          if (v is String) return MapEntry(k.toString(), v);
          if (v is Map) {
            return MapEntry(k.toString(), Map<String, dynamic>.from(v));
          }
          throw FormatException(
            'Invalid metadata: values in "$field" must be Strings or Maps',
          );
        });
      }
      throw FormatException(
        'Invalid metadata: "$field" must be a Map, got ${value.runtimeType}',
      );
    }

    return ComicExportInfo(
      id: asString(json['id'], 'id'),
      title: asString(json['title'], 'title'),
      subtitle: asString(json['subtitle'], 'subtitle'),
      tags: asStringList(json['tags'], 'tags'),
      directory: asString(json['directory'], 'directory'),
      chapters: asStringMap(json['chapters'], 'chapters'),
      cover: asString(json['cover'], 'cover'),
      comicType: asInt(json['comicType'], 'comicType'),
      downloadedChapters: asStringList(
        json['downloadedChapters'],
        'downloadedChapters',
      ),
      createdAt: asInt(json['createdAt'], 'createdAt'),
      sourceDirectory: asString(json['sourceDirectory'], 'sourceDirectory'),
    );
  }
}

/// 导出元数据
class ComicExportMetadata {
  final int version;
  final String exportTime;
  final int totalCount;
  final List<ComicExportInfo> comics;

  ComicExportMetadata({
    required this.version,
    required this.exportTime,
    required this.totalCount,
    required this.comics,
  });

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'exportTime': exportTime,
      'totalCount': totalCount,
      'comics': comics.map((e) => e.toJson()).toList(),
    };
  }
}
