import 'dart:convert';
import 'dart:isolate';

import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'comic_export.dart';

/// 导入结果
class ImportResult {
  final int imported;
  final int skipped;
  final List<String> errors;

  ImportResult({
    required this.imported,
    required this.skipped,
    this.errors = const [],
  });
}

/// 漫画导入工具
class ComicImporter {
  /// 从 .venera-comics 文件导入漫画
  static Future<ImportResult> importComics({
    required String filePath,
    void Function(int current, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    // 1. 解压到临时目录
    final tempDirPath = FilePath.join(
      App.cachePath,
      'comic_import_temp_${DateTime.now().millisecondsSinceEpoch}',
    );
    final tempDir = Directory(tempDirPath);
    tempDir.createSync(recursive: true);

    try {
      await Isolate.run(() {
        ZipFile.openAndExtract(filePath, tempDirPath);
      });

      // 2. 读取 metadata.json
      final metadataFile = File(FilePath.join(tempDirPath, 'metadata.json'));
      if (!metadataFile.existsSync()) {
        return ImportResult(
          imported: 0,
          skipped: 0,
          errors: ['Invalid file: metadata.json not found'],
        );
      }

      final List<ComicExportInfo> comicsInfo;
      try {
        final metadataJson =
            jsonDecode(await metadataFile.readAsString())
                as Map<String, dynamic>;
        final comicsJson = metadataJson['comics'] as List<dynamic>;
        comicsInfo = comicsJson
            .map((e) => _parseComicExportInfo(e as Map<String, dynamic>))
            .toList();
      } catch (e) {
        return ImportResult(
          imported: 0,
          skipped: 0,
          errors: ['Failed to parse metadata: $e'],
        );
      }

      // 3. 检查本地重复和 ComicSource 可用性，过滤不合规的漫画
      final comicsToImport = <ComicExportInfo>[];
      var skippedCount = 0;
      final sourceErrors = <String>[];

      for (var info in comicsInfo) {
        if (_isComicExists(info.id, info.comicType)) {
          skippedCount++;
        } else if (!_isComicSourceAvailable(info.comicType)) {
          sourceErrors.add(
            '"${info.title}": Comic source not available on this device',
          );
        } else {
          comicsToImport.add(info);
        }
      }

      // 4. 导入漫画
      // 进度以文件中全部漫画数量为基准，包含已跳过的部分
      final totalCount = comicsInfo.length;
      final errors = <String>[];
      final skippedAndUnavailable = skippedCount + sourceErrors.length;
      // 先报告跳过的部分，让进度条从非零开始
      if (skippedAndUnavailable > 0) {
        onProgress?.call(skippedAndUnavailable, totalCount);
      }

      for (var i = 0; i < comicsToImport.length; i++) {
        if (isCancelled?.call() == true) {
          return ImportResult(
            imported: i - errors.length,
            skipped: skippedCount,
            errors: errors,
          );
        }

        try {
          final info = comicsToImport[i];
          await _importSingleComic(info, tempDirPath);
        } catch (e, s) {
          Log.error(
            "ComicImporter",
            "Failed to import ${comicsToImport[i].title}",
            s,
          );
          errors.add('Failed to import ${comicsToImport[i].title}: $e');
        } finally {
          onProgress?.call(skippedAndUnavailable + i + 1, totalCount);
        }
      }

      return ImportResult(
        imported: comicsToImport.length - errors.length,
        skipped: skippedCount,
        errors: [...sourceErrors, ...errors],
      );
    } finally {
      // 5. 清理临时目录
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  }

  /// 解析漫画导出信息
  static ComicExportInfo _parseComicExportInfo(Map<String, dynamic> json) {
    return ComicExportInfo.fromJson(json);
  }

  /// 检查漫画是否已存在
  static bool _isComicExists(String id, int comicType) {
    final existing = LocalManager().find(id, ComicType(comicType));
    return existing != null;
  }

  /// 检查 ComicSource 是否在当前设备上可用
  static bool _isComicSourceAvailable(int comicType) {
    final type = ComicType(comicType);
    // Local comics (type 0) are always available
    if (type == ComicType.local) return true;
    return type.comicSource != null;
  }

  /// 导入单个漫画
  static Future<void> _importSingleComic(
    ComicExportInfo info,
    String tempDirPath,
  ) async {
    final sourceDir = Directory(
      FilePath.join(tempDirPath, info.sourceDirectory),
    );
    if (!sourceDir.existsSync()) {
      throw Exception('Comic directory not found: ${info.sourceDirectory}');
    }

    // 1. 复制漫画文件到本地存储
    final localPath = LocalManager().path;

    // 如果目标目录已存在，添加后缀避免冲突
    var finalDirectory = info.directory;
    var counter = 1;
    while (Directory(FilePath.join(localPath, finalDirectory)).existsSync()) {
      finalDirectory = '${info.directory}_$counter';
      counter++;
    }

    await copyDirectoryIsolate(
      sourceDir,
      Directory(FilePath.join(localPath, finalDirectory)),
    );

    // 2. 添加到数据库
    final comic = LocalComic(
      id: info.id,
      title: info.title,
      subtitle: info.subtitle,
      tags: info.tags,
      directory: finalDirectory,
      chapters: ComicChapters.fromJsonOrNull(info.chapters),
      cover: info.cover,
      comicType: ComicType(info.comicType),
      downloadedChapters: info.downloadedChapters,
      createdAt: DateTime.fromMillisecondsSinceEpoch(info.createdAt),
    );
    try {
      LocalManager().add(comic);
    } catch (e) {
      // 数据库写入失败，清理已复制的文件
      Directory(
        FilePath.join(localPath, finalDirectory),
      ).deleteIgnoreError(recursive: true);
      rethrow;
    }
  }
}
