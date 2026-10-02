import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/foundation/log.dart';
import 'webdav_library_entries.dart';
import 'webdav_library_session.dart';

class WebDavLibraryDiscovery {
  const WebDavLibraryDiscovery(this.session);

  final WebDavLibrarySession session;
  static const _maxDiscoveryDepth = 8;
  static const _maxDiscoveryDirectories = 2000;

  Future<List<WebDavDiscoveredDirectory>> discover({
    required List<WebDavLibraryEntry> rootEntries,
    required bool Function(WebDavLibraryEntry directory) canReuse,
  }) async {
    session.check();
    final config = session.config;
    final topLevelDirectories = webDavSortedDirectories(rootEntries);
    final result = <WebDavDiscoveredDirectory>[];
    var inspectedDirectories = 0;

    Future<List<WebDavDiscoveredDirectory>> scanNested(
      String parentId,
      List<WebDavLibraryEntry> entries,
      int depth,
    ) async {
      if (depth > _maxDiscoveryDepth ||
          inspectedDirectories >= _maxDiscoveryDirectories) {
        return const [];
      }

      final directories = webDavSortedDirectories(entries);
      final nested = <WebDavDiscoveredDirectory>[];
      for (final directory in directories) {
        if (inspectedDirectories >= _maxDiscoveryDirectories) break;
        inspectedDirectories++;
        final id = _joinRelativeDirectoryPath(parentId, directory.name);
        final path = config.childDirectoryPath(id);
        List<WebDavLibraryEntry> childEntries;
        try {
          childEntries = List<WebDavLibraryEntry>.from(
            await session.readDir(path),
          );
        } catch (e) {
          if (e is WebDavLibraryCancelled) rethrow;
          Log.warning(
            'WebDAV Library',
            'Failed to inspect nested directory at $path: $e',
          );
          continue;
        }

        if (_hasMetadataFile(childEntries)) {
          nested.add(
            WebDavDiscoveredDirectory(
              id: id,
              entries: childEntries,
              eTag: directory.eTag,
              modifiedAt: directory.modifiedAt,
            ),
          );
          continue;
        }
        nested.addAll(await scanNested(id, childEntries, depth + 1));
      }
      return nested;
    }

    for (final directory in topLevelDirectories) {
      if (inspectedDirectories >= _maxDiscoveryDirectories) break;
      inspectedDirectories++;
      final id = directory.name;
      if (canReuse(directory)) {
        result.add(
          WebDavDiscoveredDirectory(
            id: id,
            entries: const [],
            eTag: directory.eTag,
            modifiedAt: directory.modifiedAt,
          ),
        );
        continue;
      }
      final path = config.childDirectoryPath(id);
      List<WebDavLibraryEntry> entries;
      try {
        entries = List<WebDavLibraryEntry>.from(await session.readDir(path));
      } catch (e) {
        if (e is WebDavLibraryCancelled) rethrow;
        Log.warning(
          'WebDAV Library',
          'Failed to inspect directory at $path: $e',
        );
        result.add(
          WebDavDiscoveredDirectory(
            id: id,
            entries: const [],
            eTag: directory.eTag,
            modifiedAt: directory.modifiedAt,
          ),
        );
        continue;
      }

      if (_hasMetadataFile(entries)) {
        final discoveredDirectories = [
          WebDavDiscoveredDirectory(
            id: id,
            entries: entries,
            eTag: directory.eTag,
            modifiedAt: directory.modifiedAt,
          ),
        ];
        result.addAll(discoveredDirectories);
        continue;
      }

      final rootImages = webDavImageEntries(entries);
      final childDirectories = webDavSortedDirectories(entries);
      if (rootImages.isNotEmpty || childDirectories.isEmpty) {
        final discoveredDirectories = [
          WebDavDiscoveredDirectory(
            id: id,
            entries: entries,
            eTag: directory.eTag,
            modifiedAt: directory.modifiedAt,
          ),
        ];
        result.addAll(discoveredDirectories);
        continue;
      }

      final nested = await scanNested(id, entries, 1);
      if (nested.isEmpty) {
        // Keep the original first-level directory behavior when no metadata
        // marker can be found below a directory.
        final discoveredDirectories = [
          WebDavDiscoveredDirectory(
            id: id,
            entries: entries,
            eTag: directory.eTag,
            modifiedAt: directory.modifiedAt,
          ),
        ];
        result.addAll(discoveredDirectories);
      } else {
        result.addAll(nested);
      }
    }

    session.check();
    result.sort((a, b) => compareComicFileNames(a.id, b.id));
    return result;
  }

  static bool _hasMetadataFile(List<WebDavLibraryEntry> entries) {
    return entries.any(
      (entry) =>
          !entry.isDirectory &&
          entry.name.toLowerCase() == webDavMetadataFileName,
    );
  }

  static String _joinRelativeDirectoryPath(String parent, String name) {
    return parent.isEmpty ? name : '$parent/$name';
  }
}

class WebDavDiscoveredDirectory {
  const WebDavDiscoveredDirectory({
    required this.id,
    required this.entries,
    this.eTag,
    this.modifiedAt,
  });

  final String id;
  final List<WebDavLibraryEntry> entries;
  final String? eTag;
  final int? modifiedAt;
}
