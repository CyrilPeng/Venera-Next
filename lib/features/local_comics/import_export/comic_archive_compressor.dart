import 'dart:io';

import 'package:archive/archive_io.dart' as archive;
import 'package:flutter/foundation.dart';

/// Stream local staging files off the UI isolate. Dart file I/O preserves
/// Unicode paths on Windows, including the CBZ names in a multi-book export.
Future<void> compressComicArchive(String directory, String output) =>
    compute(_compressComicArchive, (directory: directory, output: output));

Future<void> _compressComicArchive(
  ({String directory, String output}) request,
) => archive.ZipFileEncoder().zipDirectory(
  Directory(request.directory),
  filename: request.output,
  followLinks: false,
);
