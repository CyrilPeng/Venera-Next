import 'dart:io';

/// Content evidence from one complete GET, never inferred from a HEAD/listing.
sealed class DataSyncArchiveProbe {
  const DataSyncArchiveProbe();
}

final class DataSyncArchiveMissing extends DataSyncArchiveProbe {
  const DataSyncArchiveMissing();
}

final class DataSyncArchivePresent extends DataSyncArchiveProbe {
  const DataSyncArchivePresent({
    required this.sha256,
    required this.length,
    this.strongEtag,
  });

  final String sha256;
  final int length;

  /// Null for absent, weak, malformed, or ambiguous entity tags. Such a result
  /// proves content but cannot authorize conditional retention deletion.
  final String? strongEtag;
}

enum DataSyncArchiveCreateResult { created, preconditionFailed }

enum DataSyncArchiveRemoveResult { removed, missing, preconditionFailed }

/// A single owned connection. Upload recovery depends only on this Dart port.
abstract interface class DataSyncRemote {
  Future<List<String>> listNames();

  /// Only an authoritative 404 is missing. Authentication, transport, partial
  /// content and server failures remain errors, including incomplete bodies.
  Future<DataSyncArchiveProbe> probeArchive(String name);

  /// Verify local content before a create-only PUT. A failed response may leave
  /// an unknown outcome; callers reconcile it with [probeArchive].
  Future<DataSyncArchiveCreateResult> createArchiveIfAbsent(
    String name,
    File source, {
    required String sha256,
    required int length,
  });

  /// Refuse weak or missing validators; never fall back to unconditional DELETE.
  Future<DataSyncArchiveRemoveResult> removeArchiveIfUnchanged(
    String name, {
    required String strongEtag,
  });

  Future<void> readToFile(String name, String path);
  Future<void> dispose();
}
