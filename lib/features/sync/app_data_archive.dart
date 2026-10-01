import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive_io.dart' as archive_io;
import 'package:path/path.dart' as p;
import 'package:zip_flutter/zip_flutter.dart';
import 'app_data_snapshot.dart';

/// Archive filesystem work with explicit paths; no application settings or UI.
abstract final class AppDataArchive {
  static Future<void> create({
    required String dataPath,
    required String cachePath,
    required String destinationPath,
    required String settingsJson,
  }) async {
    final destination = File(destinationPath);
    if (destination.existsSync()) {
      throw StateError('Archive destination already exists');
    }
    final staging = Directory(cachePath).createTempSync('.app_data_export_');
    final stagingPath = staging.path;
    try {
      await Isolate.run(() async {
        final entries = await createAppDataSnapshot(
          dataPath,
          stagingPath,
          settingsJson: settingsJson,
        );
        final zip = ZipFile.open(destinationPath);
        try {
          for (final name in entries) {
            zip.addFile(name, p.join(stagingPath, name));
          }
        } finally {
          zip.close();
        }
      });
    } catch (_) {
      await _deleteTemporary(destination);
      rethrow;
    } finally {
      await _deleteTemporary(staging);
    }
  }

  /// The caller owns the extraction directory and any cleanup after failure.
  static Future<void> extract(String archivePath, String outputPath) =>
      Isolate.run(() => _extractZip(archivePath, outputPath));
}

Future<void> _deleteTemporary(FileSystemEntity entity) async {
  try {
    if (await entity.exists()) {
      await entity.delete(recursive: entity is Directory);
    }
  } catch (_) {
    // Best effort cleanup must not mask the archive operation's result.
  }
}

// Decode ZIP content directly so custom .venera/.picadata extensions work.
// The native extractor in zip_flutter 0.0.13 double-frees its callback argument.
void _extractZip(String archivePath, String outputPath) {
  final input = archive_io.InputFileStream(archivePath);
  try {
    final archive = archive_io.ZipDecoder().decodeStream(input);
    final entries = archive.map((entry) {
      final name = entry.name.replaceAll('\\', '/');
      final destination = p.normalize(p.join(outputPath, name));
      if (entry.isSymbolicLink ||
          p.isAbsolute(name) ||
          !p.isWithin(p.absolute(outputPath), p.absolute(destination))) {
        throw FormatException('Invalid app data archive entry: ${entry.name}');
      }
      return (entry, destination);
    }).toList();
    for (final (entry, destination) in entries) {
      if (entry.isDirectory) {
        Directory(destination).createSync(recursive: true);
      } else {
        File(destination).parent.createSync(recursive: true);
        final output = archive_io.OutputFileStream(destination);
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
      }
    }
  } finally {
    input.closeSync();
  }
}
