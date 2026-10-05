import 'data_sync_commit.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';

enum DataSyncDirection { upload, download }

/// Durable identity and known outcome of an unfinished sync operation.
/// This record cannot recreate an in-memory follow-up callback or prove that an
/// interrupted remote request did not commit. Startup must resolve it explicitly.
class DataSyncOperation {
  DataSyncOperation({
    required this.id,
    required this.direction,
    required List<String> connection,
    required this.excludedFields,
    required this.mode,
    required this.intervalMinutes,
    required this.pendingBefore,
    required this.generation,
    required this.commitState,
    required this.followUpComplete,
    this.recoveryPath,
    this.version = 3,
    this.configurationChange = false,
    this.previousConfiguration,
  }) : connection = List.unmodifiable(connection);

  final String id;
  final DataSyncDirection direction;
  final List<String> connection;
  final String excludedFields;
  final String mode;
  final int intervalMinutes;
  final bool pendingBefore;
  final int generation;
  final DataSyncCommitState commitState;
  final bool followUpComplete;
  final String? recoveryPath;
  final int version;
  final bool configurationChange;
  final SyncPreferenceCheckpoint? previousConfiguration;

  Map<String, Object?> toJson() => {
    'version': version,
    'id': id,
    'direction': direction.name,
    'connection': List<String>.of(connection),
    'excludedFields': excludedFields,
    'mode': mode,
    'intervalMinutes': intervalMinutes,
    'pendingBefore': pendingBefore,
    'generation': generation,
    'commitState': commitState.name,
    'followUpComplete': followUpComplete,
    'recoveryPath': recoveryPath,
    if (version >= 2) ...{
      'configurationChange': configurationChange,
      'previousConfiguration': previousConfiguration?.toJson(),
    },
  };

  factory DataSyncOperation.fromJson(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const FormatException('Invalid sync operation object');
    }
    final version = value['version'];
    final id = value['id'];
    final direction = value['direction'];
    final connection = value['connection'];
    final excludedFields = value['excludedFields'];
    final mode = value['mode'];
    final interval = value['intervalMinutes'];
    final pendingBefore = value['pendingBefore'];
    final generation = value['generation'];
    final commitState = value['commitState'];
    final followUpComplete = value['followUpComplete'];
    final recoveryPath = value['recoveryPath'];
    if (version is! int || (version != 1 && version != 2 && version != 3)) {
      throw const FormatException('Unsupported sync operation version');
    }
    final configurationChange = version == 1
        ? false
        : value['configurationChange'];
    if (configurationChange is! bool) {
      throw const FormatException('Invalid sync configuration operation');
    }
    final previousConfiguration = value['previousConfiguration'];
    final checkpoint = previousConfiguration == null
        ? null
        : SyncPreferenceCheckpoint.fromJson(previousConfiguration);
    if (configurationChange && checkpoint == null) {
      throw const FormatException('Missing previous sync configuration');
    }
    if (id is! String ||
        id.trim().isEmpty ||
        direction is! String ||
        connection is! List ||
        (connection.isNotEmpty && connection.length != 3) ||
        connection.any((part) => part is! String) ||
        excludedFields is! String ||
        mode is! String ||
        !const ['manual', 'realtime', 'scheduled'].contains(mode) ||
        interval is! int ||
        interval <= 0 ||
        pendingBefore is! bool ||
        generation is! int ||
        generation < 0 ||
        commitState is! String ||
        followUpComplete is! bool ||
        (recoveryPath != null && recoveryPath is! String)) {
      throw const FormatException('Invalid sync operation fields');
    }
    final parsedDirection = switch (direction) {
      'upload' => DataSyncDirection.upload,
      'download' => DataSyncDirection.download,
      _ => throw const FormatException('Invalid sync operation direction'),
    };
    final parsedState = switch (commitState) {
      'notApplied' => DataSyncCommitState.notApplied,
      'applied' => DataSyncCommitState.applied,
      'recoveryRequired' => DataSyncCommitState.recoveryRequired,
      _ => throw const FormatException('Invalid sync operation commit state'),
    };
    return DataSyncOperation(
      id: id,
      direction: parsedDirection,
      connection: connection.cast<String>(),
      excludedFields: excludedFields,
      mode: mode,
      intervalMinutes: interval,
      pendingBefore: pendingBefore,
      generation: generation,
      commitState: parsedState,
      followUpComplete: followUpComplete,
      recoveryPath: recoveryPath as String?,
      version: version,
      configurationChange: configurationChange,
      previousConfiguration: checkpoint,
    );
  }

  DataSyncOperation copyWith({
    DataSyncCommitState? commitState,
    bool? followUpComplete,
    String? recoveryPath,
  }) => DataSyncOperation(
    id: id,
    direction: direction,
    connection: connection,
    excludedFields: excludedFields,
    mode: mode,
    intervalMinutes: intervalMinutes,
    pendingBefore: pendingBefore,
    generation: generation,
    commitState: commitState ?? this.commitState,
    followUpComplete: followUpComplete ?? this.followUpComplete,
    recoveryPath: recoveryPath ?? this.recoveryPath,
    version: version,
    configurationChange: configurationChange,
    previousConfiguration: previousConfiguration,
  );
}
