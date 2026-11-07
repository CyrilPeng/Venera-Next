// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors

import 'dart:async';
import 'dart:io';

import 'backend.dart';
import 'entities.dart';

/// Recognizes the historical document-ID path scheme without treating IDs as
/// URI authorities. Ordinary IO stays in the zone that created this override.
base class SafIOOverrides extends IOOverrides {
  SafIOOverrides({bool? enabled}) : enabled = enabled ?? Platform.isAndroid;

  final bool enabled;
  final _parentZone = Zone.current;

  @override
  File createFile(String path) => enabled && isSafPath(path)
      ? AndroidFile.fromPathSync(path)!
      : super.createFile(path);

  @override
  Directory createDirectory(String path) => enabled && isSafPath(path)
      ? AndroidDirectory.fromPathSync(path)!
      : super.createDirectory(path);

  @override
  FileSystemEntityType fseGetTypeSync(String path, bool followLinks) =>
      enabled && isSafPath(path)
      ? AndroidDirectory.fromPathSync(path)!.statSync().type
      : _parentZone.run(
          () => FileSystemEntity.typeSync(path, followLinks: followLinks),
        );

  @override
  Future<FileSystemEntityType> fseGetType(String path, bool followLinks) =>
      enabled && isSafPath(path)
      ? AndroidDirectory.fromPathSync(path)!.stat().then((stat) => stat.type)
      : _parentZone.run(
          () => FileSystemEntity.type(path, followLinks: followLinks),
        );
}
