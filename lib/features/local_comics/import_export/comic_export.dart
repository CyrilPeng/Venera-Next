import 'dart:convert';
import 'dart:isolate';

import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:zip_flutter/zip_flutter.dart';

/// 漫画导出元信息
class ComicExportInfo {
  final String id;
  final String title;
  final String subtitle;
  final List<String> tags;
  final String directory;

  /// Chapter data as stored by [ComicChapters.toJson].
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

  factory ComicExportInfo.fromLocalComic(LocalComic comic) {
    final sourceDirectory = '${comic.id}_${comic.comicType.value}';
    final chapters = comic.chapters?.toJson() ?? <String, dynamic>{};
    return ComicExportInfo(
      id: comic.id,
      title: comic.title,
      subtitle: comic.subtitle,
      tags: comic.tags,
      directory: comic.directory,
      chapters: chapters,
      cover: comic.cover,
      comicType: comic.comicType.value,
      downloadedChapters: comic.downloadedChapters,
      createdAt: comic.createdAt.millisecondsSinceEpoch,
      sourceDirectory: sourceDirectory,
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

/// 漫画导出工具
class ComicExporter {
  /// 导出漫画到 .venera-comics 文件
  ///
  /// Throws [FileSystemException] if source comics cannot be read or
  /// the output path is not writable.
  /// Throws [StateException] if a comic's source directory is missing.
  static Future<void> exportComics({
    required List<LocalComic> comics,
    required String outputPath,
    void Function(int current, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    // 1. 创建临时目录
    final tempDirPath = FilePath.join(
      App.cachePath,
      'comic_export_temp_${DateTime.now().millisecondsSinceEpoch}',
    );
    final tempDir = Directory(tempDirPath);
    tempDir.createSync(recursive: true);

    try {
      // 2. 生成元数据
      final exportInfos = comics
          .map((e) => ComicExportInfo.fromLocalComic(e))
          .toList();
      final metadata = ComicExportMetadata(
        version: 1,
        exportTime: DateTime.now().toIso8601String(),
        totalCount: comics.length,
        comics: exportInfos,
      );

      // 3. 写入 metadata.json
      final metadataFile = File(FilePath.join(tempDirPath, 'metadata.json'));
      await metadataFile.writeAsString(jsonEncode(metadata.toJson()));

      // 4. 复制漫画文件
      for (var i = 0; i < comics.length; i++) {
        if (isCancelled?.call() == true) return;

        final comic = comics[i];
        final sourceDir = Directory(
          FilePath.join(LocalManager().path, comic.directory),
        );
        final targetDir = Directory(
          FilePath.join(tempDirPath, exportInfos[i].sourceDirectory),
        );

        if (!sourceDir.existsSync()) {
          throw StateError(
            'Source directory missing for comic "${comic.title}" '
            '(id: ${comic.id}): ${sourceDir.path}',
          );
        }
        await copyDirectoryIsolate(sourceDir, targetDir);

        onProgress?.call(i + 1, comics.length);
      }

      // 5. 打包成 ZIP
      // Ensure the parent directory of the output file exists
      final outputDir = Directory(outputPath).parent;
      if (!outputDir.existsSync()) {
        outputDir.createSync(recursive: true);
      }

      // Convert to plain Maps before passing to Isolate to ensure sendability
      final metadataFilePath = metadataFile.path;
      final exportInfosData = exportInfos.map((e) => e.toJson()).toList();

      await Isolate.run(() {
        final zipFile = ZipFile.open(outputPath);

        // 添加 metadata.json
        zipFile.addFile('metadata.json', metadataFilePath);

        // 添加漫画文件夹
        for (var info in exportInfosData) {
          final sourceDir = info['sourceDirectory'] as String;
          final comicDirPath = '$tempDirPath/$sourceDir';
          final comicDir = Directory(comicDirPath);
          if (comicDir.existsSync()) {
            _addDirectoryToZip(zipFile, comicDir, sourceDir);
          }
        }

        zipFile.close();
      });
    } finally {
      // 6. 清理临时目录
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  }

  /// 递归添加目录到 ZIP
  static void _addDirectoryToZip(
    ZipFile zipFile,
    Directory dir,
    String basePath,
  ) {
    for (var entity in dir.listSync(recursive: true)) {
      if (entity is File) {
        var relativePath = entity.path.substring(dir.path.length + 1);
        // ZIP entries must use forward slashes regardless of platform
        relativePath = relativePath.replaceAll('\\', '/');
        final zipPath = '$basePath/$relativePath';
        zipFile.addFile(zipPath, entity.path);
      }
    }
  }
}
