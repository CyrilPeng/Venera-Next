import 'dart:convert';
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_qjs/flutter_qjs.dart' show JSInvokable;
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/init.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';

import 'category.dart';
import 'comic_type_bridge.dart';
import 'favorites.dart';
import 'image_loading.dart';
import 'js_bridge.dart';
import 'parser.dart';
import 'source.dart';
import 'source_data_storage.dart';
import 'source_repositories.dart';
import 'source_configuration.dart';
import 'source_mutation_failure.dart';
import 'source_script_checkpoint.dart';

typedef RuntimeComicSourcesProvider = Iterable<ComicSource> Function();

RuntimeComicSourcesProvider? _runtimeComicSourcesProvider;

void configureRuntimeComicSourcesProvider(
  RuntimeComicSourcesProvider? provider,
) {
  _runtimeComicSourcesProvider = provider;
}

class ComicSourceManager with ChangeNotifier, Init {
  final List<ComicSource> _sources = [];

  static ComicSourceManager? _instance;

  /// Observe an already assembled runtime without creating or replacing it.
  static ComicSourceManager? get current =>
      _instance?._closing == true ? null : _instance;
  bool _closing = false;
  Future<void>? _closeFuture;
  JsEngine? _sourceEngine;
  final _pendingInitializations = <Future<void>>{};
  final _acceptedMutations = <Future<void>>{};
  final _initializationAdmissions = <Object?, Future<void>>{};
  final _pendingDataClosures = <Future<void>>{};
  final _dataWriteFailures =
      <({String resource, Object error, StackTrace stack})>[];

  final SourceDataStorage _dataStorage;

  ComicSourceManager._create(this._dataStorage) {
    SourceRepositories.instance.addListener(_repositoriesChanged);
    configureComicSourceRegistry(
      all: all,
      find: find,
      fromIntKey: fromIntKey,
      isEmpty: () => isEmpty,
    );
    configureComicTypeSourceKeyResolver();
    configureCategoryDataResolver(_findCategoryDataByKey);
    configureFavoriteDataResolver(_findFavoriteDataByKey);
  }

  factory ComicSourceManager({SourceDataStorage? dataStorage}) {
    final current = _instance;
    if (current != null &&
        dataStorage != null &&
        !identical(dataStorage, current._dataStorage)) {
      throw StateError('Cannot replace storage on a live source manager');
    }
    return _instance ??= ComicSourceManager._create(
      dataStorage ?? const SourceDataStorage(),
    );
  }

  void _repositoriesChanged() => updateAvailableUpdates({});

  void _checkAccepting() {
    if (_closing) throw StateError('Comic source manager is closing');
  }

  @override
  void notifyListeners() {
    if (!_closing) AppDataOperations.instance.publish(super.notifyListeners);
  }

  /// Release the notifier immediately; retain native callbacks until accepted
  /// mutations and actual init Promises (including timed-out waits) settle.
  @override
  void dispose() {
    if (_closing) return;
    if ((_acceptedMutations.isNotEmpty ||
            _sources.isNotEmpty ||
            _pendingDataClosures.isNotEmpty) &&
        AppDataOperations.instance.sharingScope != null) {
      throw StateError('Close comic sources outside active data operations');
    }
    _closing = true;
    SourceRepositories.instance.removeListener(_repositoriesChanged);
    super.dispose();
    _closeFuture = _closeResources();
    unawaited(
      _closeFuture!.catchError((Object error, StackTrace stack) {
        Log.error('ComicSource close', error, stack);
      }),
    );
  }

  Future<void> closeAndWait() {
    dispose();
    return _closeFuture!;
  }

  @override
  Future<void> init() {
    if (_closing) {
      return Future.error(StateError('Comic source manager is closing'));
    }
    if (initializationState == InitializationState.ready ||
        initializationState == InitializationState.failed) {
      return super.init();
    }
    final operations = AppDataOperations.instance;
    final owner = operations.sharingScope;
    return _initializationAdmissions.putIfAbsent(owner, () {
      final result = _trackMutation(operations.prepare(super.init));
      unawaited(
        result.then<void>(
          (_) => _initializationAdmissions.remove(owner),
          onError: (Object _, StackTrace _) {
            _initializationAdmissions.remove(owner);
          },
        ),
      );
      return result;
    });
  }

  @override
  Future<void> ensureInit() {
    if (_closing) {
      return Future.error(StateError('Comic source manager is closing'));
    }
    if (initializationState == InitializationState.notStarted &&
        AppDataOperations.instance.sharingScope != null) {
      return Future.error(
        StateError(
          'Initialize comic sources explicitly before waiting inside a data operation',
        ),
      );
    }
    return super.ensureInit();
  }

  Future<void> _closeResources() async {
    while (_acceptedMutations.isNotEmpty) {
      await Future.wait(_acceptedMutations.toList());
    }
    while (_pendingInitializations.isNotEmpty) {
      await Future.wait(_pendingInitializations.toList());
    }
    for (final source in _sources) {
      _retireSourceDataWrites(source);
    }
    while (_pendingDataClosures.isNotEmpty) {
      await Future.wait(_pendingDataClosures.toList());
    }
    final failures = List.of(_dataWriteFailures);
    _dataWriteFailures.clear();
    for (final source in _sources) {
      try {
        if (source.filePath.isNotEmpty) {
          _sourceEngine?.runCode(
            'delete ComicSource.sources[${jsonEncode(source.key)}];',
          );
        }
      } catch (error, stack) {
        failures.add((
          resource: '${source.key} registry',
          error: error,
          stack: stack,
        ));
      }
      try {
        source.disposeRuntimeCallbacks();
      } catch (error, stack) {
        failures.add((
          resource: '${source.key} callbacks',
          error: error,
          stack: stack,
        ));
      }
    }
    _sources.clear();
    _availableUpdates.clear();
    _sourceEngine = null;
    if (identical(_instance, this)) {
      _instance = null;
      configureComicSourceRegistry(
        all: () => [],
        find: (_) => null,
        fromIntKey: (_) => null,
        isEmpty: () => true,
      );
      configureCategoryDataResolver(null);
      configureFavoriteDataResolver(null);
      configureComicSourceImageDownloader(
        thumbnailLoadingConfig: (_, _) => {},
        thumbnailCover: (_, _) async => null,
        comicImageLoadingConfig: (_, _, _, _) async => {},
      );
    }
    if (failures.isNotEmpty) throw JsResourceReleaseFailure(failures);
  }

  // Replaced and removed sources can still own accepted file writes even after
  // leaving the registry. Keep their completion and failures in this host.
  void _retireSourceDataWrites(ComicSource source) {
    late final Future<void> settled;
    settled = Future<void>.sync(source.closeDataWrites)
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            _dataWriteFailures.add((
              resource: '${source.key} data',
              error: error,
              stack: stack,
            ));
          },
        )
        .whenComplete(() => _pendingDataClosures.remove(settled));
    _pendingDataClosures.add(settled);
  }

  List<ComicSource> all() => List.from(_sources);

  ComicSource? find(String key) =>
      _sources.firstWhereOrNull((element) => element.key == key);

  ComicSource? fromIntKey(int key) =>
      _sources.firstWhereOrNull((element) => element.key.hashCode == key);

  CategoryData _findCategoryDataByKey(String key) {
    for (var source in all()) {
      if (source.categoryData?.key == key) {
        return source.categoryData!;
      }
    }
    throw "Unknown category key $key";
  }

  FavoriteData? _findFavoriteDataByKey(String key) {
    return find(key)?.favoriteData;
  }

  @override
  @protected
  // Initial loading mutates the same Dart/JS registries as reload and install.
  // Keep it inside their queue so no later mutation can replace staged state.
  Future<void> doInit() => _mutate(_loadSources, acceptedInitialization: true);

  Future<void> _loadSources({
    Set<String> existingFiles = const {},
    Set<ComicSource> preservedSources = const {},
  }) async {
    await SourceRepositories.instance.migrate();
    configureComicTypeSourceKeyResolver();
    configureComicSourceImageDownloader(
      thumbnailLoadingConfig: _getThumbnailLoadingConfig,
      thumbnailCover: _getThumbnailCover,
      comicImageLoadingConfig: _getComicImageLoadingConfig,
    );
    configureComicSourceJsDataBridge();
    await JsEngine().ensureInit();
    final loaded = <ComicSource>[];
    final parsers = <ComicSourceParser>[];
    final addedRuntime = <ComicSource>[];
    try {
      final path = "${App.dataPath}/comic_source";
      if (!(await Directory(path).exists())) {
        await Directory(path).create();
      } else {
        await for (var entity in Directory(path).list()) {
          if (entity is File && entity.path.endsWith(".js")) {
            try {
              final parser = ComicSourceParser(dataStorage: _dataStorage);
              final source = await parser.parse(
                await entity.readAsString(),
                entity.absolute.path,
                retainRollback: true,
              );
              parsers.add(parser);
              _sources.add(source);
              source.bindDataOwner();
              loaded.add(source);
            } catch (e, s) {
              if (existingFiles.any(
                (existing) => p.equals(existing, entity.absolute.path),
              )) {
                rethrow;
              }
              Log.error("ComicSource", "$e\n$s");
            }
          }
        }
      }
      final runtimeSources =
          _runtimeComicSourcesProvider?.call() ?? const <ComicSource>[];
      for (final source in runtimeSources) {
        if (find(source.key) == null) {
          _sources.add(source);
          source.bindDataOwner();
          addedRuntime.add(source);
        }
      }
    } catch (_) {
      // Only remove this attempt's registrations. Parser rollback restores the
      // previous JS slot and frees the callbacks belonging to each loaded file.
      final staged = Set<ComicSource>.identity()
        ..addAll(loaded)
        ..addAll(addedRuntime);
      _sources.removeWhere(staged.contains);
      for (final parser in parsers.reversed) {
        try {
          parser.rollback();
        } catch (error, stack) {
          Log.error('ComicSource rollback', error, stack);
        }
      }
      for (final source in addedRuntime) {
        if (!preservedSources.contains(source)) {
          source.disposeRuntimeCallbacks();
        }
      }
      rethrow;
    }
    for (final parser in parsers) {
      parser.commit();
    }
    // Register every source before invoking init. Network work in one source
    // must not hold up startup or prevent the other sources from initializing.
    _scheduleInitializations(loaded);
  }

  void _scheduleInitializations(List<ComicSource> loaded) {
    if (loaded.isEmpty) return;
    // This independently admitted task must not extend the startup Future or
    // borrow an import's exclusive scope. A queued reload may retire these
    // sources before it starts; only the instances still registered may init.
    AppDataOperations.instance.publish(() {
      final result = _trackMutation(
        AppDataOperations.instance.prepare(() async {
          await Future.wait([
            for (final source in loaded)
              if (identical(find(source.key), source))
                _initializeSource(source).catchError((
                  Object error,
                  StackTrace stack,
                ) {
                  Log.error('ComicSource', '${source.name}: $error', stack);
                }),
          ]);
          // The public 15-second timeout does not end an actual JS Promise.
          while (_pendingInitializations.isNotEmpty) {
            await Future.wait(_pendingInitializations.toList());
          }
        }),
      );
      unawaited(
        result.catchError((Object error, StackTrace stack) {
          Log.error('ComicSource initialization', error, stack);
        }),
      );
    });
  }

  Future<T> _trackMutation<T>(Future<T> result) {
    late final Future<void> settled;
    settled = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _acceptedMutations.remove(settled));
    _acceptedMutations.add(settled);
    return result;
  }

  Future<void> _mutationTail = Future.value();

  Future<T> _mutate<T>(
    Future<T> Function() action, {
    bool acceptedInitialization = false,
  }) {
    if (_closing && !acceptedInitialization) {
      return Future.error(StateError('Comic source manager is closing'));
    }
    // Acquire global preparation before joining the local queue. An import
    // that already owns exclusive access can reload without waiting for later
    // outside requests that are still queued behind that import.
    return _trackMutation(
      AppDataOperations.instance.prepare(() {
        final result = _mutationTail.then((_) {
          _sourceEngine = JsEngine();
          return action();
        });
        _mutationTail = result.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        );
        return result;
      }),
    );
  }

  /// A publisher may identify this reload's synchronous notification without
  /// suppressing independent changes while loading or initializing sources.
  Future<void> reload({void Function(void Function())? publishChange}) =>
      _mutate(() => _reloadSources(publishChange: publishChange));

  Future<void> _reloadSources({
    void Function(void Function())? publishChange,
  }) async {
    final previous = List<ComicSource>.of(_sources);
    final preserved = Set<ComicSource>.identity()..addAll(previous);
    final engine = JsEngine();
    JSInvokable? restore;
    final freezes = <ComicSource, SourceDataWriteFreeze>{};
    try {
      for (final source in previous) {
        freezes[source] = source.freezeDataWrites();
      }
      for (final freeze in freezes.values) {
        await freeze.waitForWrites();
      }
      restore =
          engine.runCode('''(() => {
      const previous = ComicSource.sources;
      ComicSource.sources = {};
      return () => { ComicSource.sources = previous; };
    })()''')
              as JSInvokable;
      _sources.clear();
      await _loadSources(
        existingFiles: previous
            .where((source) => source.filePath.isNotEmpty)
            .map((source) => File(source.filePath).absolute.path)
            .toSet(),
        preservedSources: preserved,
      );
    } catch (error, stack) {
      final failures = <SourceMutationError>[
        (stage: 'reload sources', error: error, stack: stack),
      ];
      _sources
        ..clear()
        ..addAll(previous);
      if (restore != null) {
        await _attempt(
          failures,
          'restore source registry',
          () => restore!.invoke([]),
        );
        await _attempt(failures, 'release registry backup', restore.free);
      }
      for (final freeze in freezes.values) {
        await _attempt(failures, 'resume source writes', freeze.resume);
      }
      _throwRecovery(failures);
    }
    final failures = <SourceMutationError>[];
    await _attempt(failures, 'release registry backup', restore.free);
    final current = Set<ComicSource>.identity()..addAll(_sources);
    for (final source in previous) {
      if (!current.contains(source)) {
        await _attempt(
          failures,
          'retire source writes',
          () => _retireSourceDataWrites(source),
        );
        await _attempt(
          failures,
          'release source callbacks',
          source.disposeRuntimeCallbacks,
        );
      } else {
        await _attempt(
          failures,
          'resume preserved source writes',
          freezes[source]!.resume,
        );
      }
    }
    await _attempt(failures, 'publish reloaded sources', () {
      if (publishChange == null) {
        notifyListeners();
      } else {
        publishChange(notifyListeners);
      }
    });
    if (failures.isNotEmpty) {
      throw SourceMutationFailure(
        state: SourceMutationState.applied,
        failures: failures,
      );
    }
  }

  Future<void> reloadForDebug() => _mutate(() async {
    final errors = <String>[];
    for (final source in all().where((source) => source.filePath.isNotEmpty)) {
      try {
        await _replaceScript(
          source,
          await File(source.filePath).readAsString(),
          validate: () {},
        );
      } catch (error) {
        errors.add('${source.name}: $error');
      }
    }
    notifyListeners();
    if (errors.isNotEmpty) throw ComicSourceParseException(errors.join('\n'));
  });

  Future<void> _initializeSource(
    ComicSource source, {
    bool settleOnFailure = false,
  }) async {
    final running = Future<void>.sync(source.initializeRuntime);
    late final Future<void> settled;
    settled = running
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _pendingInitializations.remove(settled));
    _pendingInitializations.add(settled);
    try {
      await running.timeout(const Duration(seconds: 15));
    } catch (error, stack) {
      if (settleOnFailure && error is TimeoutException) {
        // An init Promise can still call the key-based data bridge. Keep its
        // staged source registered until it really settles before rollback.
        try {
          await running;
        } catch (lateError, lateStack) {
          throw SourceMutationFailure(
            state: SourceMutationState.recoveryRequired,
            failures: [
              (
                stage: 'wait for source initialization',
                error: error,
                stack: stack,
              ),
              (
                stage: 'settle source initialization',
                error: lateError,
                stack: lateStack,
              ),
            ],
          );
        }
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> _attempt(
    List<SourceMutationError> failures,
    String stage,
    FutureOr<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error, stack) {
      failures.add((stage: stage, error: error, stack: stack));
    }
  }

  Never _throwRecovery(
    List<SourceMutationError> failures, {
    String? recoveryPath,
  }) {
    if (failures.length == 1) {
      Error.throwWithStackTrace(failures.single.error, failures.single.stack);
    }
    throw SourceMutationFailure(
      state: SourceMutationState.recoveryRequired,
      failures: failures,
      recoveryPath: recoveryPath,
    );
  }

  Future<void> _finishMutation(
    ComicSource source,
    ComicSourceParser parser, {
    required String dataPath,
    ComicSource? previous,
    List<SourceMutationError> failures = const [],
    SourceScriptCheckpoint? checkpoint,
  }) async {
    final errors = List<SourceMutationError>.of(failures);
    var committed = checkpoint == null;
    if (checkpoint != null) {
      await _attempt(errors, 'persist source commit decision', () {
        checkpoint.transaction.commit();
        committed = true;
      });
      if (!committed) {
        await _attempt(errors, 'freeze unresolved source writes', () {
          source.freezeDataWrites();
        });
      }
    }
    await _attempt(errors, 'commit source runtime', parser.commit);
    if (previous != null) {
      await _attempt(
        errors,
        'retire previous source writes',
        () => _retireSourceDataWrites(previous),
      );
      await _attempt(
        errors,
        'release previous source callbacks',
        previous.disposeRuntimeCallbacks,
      );
      await _attempt(
        errors,
        'clear source update',
        () => clearSourceUpdate(source.key),
      );
    }
    await _attempt(
      errors,
      'publish committed source data',
      source.publishDataWrites,
    );
    await _attempt(errors, 'publish source registry', notifyListeners);
    if (checkpoint != null && committed && errors.isEmpty) {
      await _attempt(
        errors,
        'clean committed script backup',
        () => finishSourceStorageRecovery(dataPath, checkpoint.discard),
      );
    }
    if (checkpoint != null) {
      await _attempt(errors, 'release source transaction', checkpoint.close);
    }
    if (errors.isNotEmpty) {
      throw SourceMutationFailure(
        state: SourceMutationState.applied,
        failures: errors,
        recoveryPath: checkpoint?.directory.path,
      );
    }
  }

  Future<List<SourceMutationError>> _commitSourceData(
    ComicSource source,
    SourceScriptCheckpoint checkpoint,
  ) async {
    try {
      await source.commitDataWrites(
        publish: false,
        beforeWrite: checkpoint.transaction.recordData,
      );
      return [];
    } on SourceMutationFailure catch (error, stack) {
      if (error.state != SourceMutationState.applied) rethrow;
      // Keep the data staging path as well as each nested file/cleanup failure.
      return [(stage: 'commit source data', error: error, stack: stack)];
    }
  }

  Future<void> _decideSourceRollback(
    SourceScriptCheckpoint? checkpoint,
    ComicSource? unresolved,
    List<SourceMutationError> failures,
  ) async {
    if (checkpoint == null) return;
    try {
      checkpoint.transaction.decideRollback();
    } catch (error, stack) {
      failures.add((
        stage: 'persist source rollback decision',
        error: error,
        stack: stack,
      ));
      if (unresolved != null) {
        await _attempt(failures, 'freeze unresolved source writes', () {
          unresolved.freezeDataWrites();
        });
      }
      await _attempt(
        failures,
        'release unresolved transaction',
        checkpoint.close,
      );
      _throwRecovery(failures, recoveryPath: checkpoint.directory.path);
    }
  }

  Future<ComicSource> installScript({
    required String js,
    required String fileName,
    required SourceOrigin origin,
    String? expectedKey,
    required void Function() beforeInstall,
  }) => _mutate(() async {
    beforeInstall();
    final path = App.dataPath;
    ComicSource? source;
    SourceConfigurationChange? configuration;
    SourceScriptCheckpoint? checkpoint;
    final parser = ComicSourceParser(dataStorage: _dataStorage);
    List<SourceMutationError> committedErrors;
    try {
      fileName = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9_.()-]'), '_');
      source = await parser.createAndParse(
        js,
        fileName,
        expectedKey: expectedKey,
        retainRollback: true,
        createFile: (file) async {
          checkpoint = await SourceScriptCheckpoint.prepare(
            dataPath: path,
            target: file,
            before: null,
            after: utf8.encode(js),
          );
          await checkpoint!.writeExpected();
        },
      );
      _sources.add(source);
      source.bindDataOwner();
      source.stageDataWrites();
      checkpoint!.transaction.bindKey(source.key);
      configuration = SourceConfigurationChange.register(
        source,
        origin: origin,
        dataPath: path,
      );
      await _initializeSource(source, settleOnFailure: true);
      await configuration.apply(transaction: checkpoint!.transaction);
      await checkpoint!.verifyExpected();
      committedErrors = await _commitSourceData(source, checkpoint!);
    } catch (error, stack) {
      final failures = <SourceMutationError>[
        (stage: 'install source', error: error, stack: stack),
      ];
      await _decideSourceRollback(checkpoint, source, failures);
      await _attempt(failures, 'restore source runtime', parser.rollback);
      if (source != null) {
        final failed = source;
        _sources.remove(failed);
        await _attempt(
          failures,
          'close failed source writes',
          failed.closeDataWrites,
        );
      }
      if (checkpoint != null) {
        await _attempt(failures, 'remove failed script', checkpoint!.restore);
      }
      if (configuration != null) {
        await _attempt(
          failures,
          'restore source configuration',
          configuration.rollback,
        );
      }
      await _attempt(failures, 'publish restored registry', notifyListeners);
      if (failures.length == 1 && checkpoint != null) {
        await _attempt(
          failures,
          'clean failed installation backup',
          () => finishSourceStorageRecovery(path, checkpoint!.discard),
        );
      }
      if (checkpoint != null) {
        await _attempt(
          failures,
          'release failed transaction',
          checkpoint!.close,
        );
      }
      _throwRecovery(failures, recoveryPath: checkpoint?.directory.path);
    }
    await _finishMutation(
      source,
      parser,
      dataPath: path,
      failures: committedErrors,
      checkpoint: checkpoint,
    );
    return source;
  });

  Future<void> replaceScript(
    ComicSource source,
    String js, {
    required void Function() validate,
    SourceOrigin? origin,
  }) => _mutate(
    () => _replaceScript(source, js, validate: validate, origin: origin),
  );

  Future<void> _replaceScript(
    ComicSource source,
    String js, {
    required void Function() validate,
    SourceOrigin? origin,
  }) async {
    validate();
    final index = _sources.indexWhere((item) => item.key == source.key);
    if (index < 0 || !identical(_sources[index], source)) {
      throw ComicSourceParseException('The source is no longer installed.');
    }
    final path = App.dataPath;
    final parser = ComicSourceParser(dataStorage: _dataStorage);
    final originalScript = await File(source.filePath).readAsBytes();
    SourceScriptCheckpoint? checkpoint;
    SourceConfigurationChange? configuration;
    ComicSource? replacement;
    SourceDataWriteFreeze? freeze;
    List<SourceMutationError> committedErrors;
    try {
      freeze = source.freezeDataWrites(captureData: true);
      await freeze.waitForWrites();
      replacement = await parser.parse(
        js,
        source.filePath,
        expectedKey: source.key,
        replacing: true,
        retainRollback: true,
      );
      replacement.stageDataWrites(initialData: freeze.data);
      _sources[index] = replacement;
      replacement.bindDataOwner();
      // Preserve the frozen memory snapshot even when init never calls saveData.
      await replacement.saveData();
      configuration = SourceConfigurationChange.register(
        replacement,
        origin: origin,
        dataPath: path,
      );
      await _initializeSource(replacement, settleOnFailure: true);
      if (App.dataPath != path) {
        throw StateError(
          'Source replacement belongs to a different data directory',
        );
      }
      checkpoint = await SourceScriptCheckpoint.prepare(
        dataPath: path,
        target: File(source.filePath),
        before: originalScript,
        after: utf8.encode(js),
      );
      checkpoint.transaction.bindKey(source.key);
      await checkpoint.verifyOriginal();
      await checkpoint.writeExpected();
      await configuration.apply(transaction: checkpoint.transaction);
      await checkpoint.verifyExpected();
      committedErrors = await _commitSourceData(replacement, checkpoint);
    } catch (error, stack) {
      final failures = <SourceMutationError>[
        (stage: 'replace source', error: error, stack: stack),
      ];
      await _decideSourceRollback(checkpoint, replacement, failures);
      _sources[index] = source;
      await _attempt(failures, 'restore source runtime', parser.rollback);
      if (replacement != null) {
        await _attempt(
          failures,
          'close failed source writes',
          replacement.closeDataWrites,
        );
      }
      if (checkpoint != null) {
        await _attempt(failures, 'restore source script', checkpoint.restore);
      }
      if (configuration != null) {
        await _attempt(
          failures,
          'restore source configuration',
          configuration.rollback,
        );
      }
      if (freeze != null) {
        await _attempt(
          failures,
          'resume original source writes',
          freeze.resume,
        );
      }
      await _attempt(failures, 'publish restored registry', notifyListeners);
      if (failures.length == 1 && checkpoint != null) {
        await _attempt(
          failures,
          'clean restored script backup',
          () => finishSourceStorageRecovery(path, checkpoint!.discard),
        );
      }
      if (checkpoint != null) {
        await _attempt(
          failures,
          'release failed transaction',
          checkpoint.close,
        );
      }
      _throwRecovery(failures, recoveryPath: checkpoint?.directory.path);
    }
    await _finishMutation(
      replacement,
      parser,
      dataPath: path,
      previous: source,
      failures: committedErrors,
      checkpoint: checkpoint,
    );
  }

  Future<void> uninstallScript(ComicSource source) => _mutate(() async {
    final index = _sources.indexOf(source);
    if (index < 0 || !identical(find(source.key), source)) {
      throw ComicSourceParseException('The source is no longer installed.');
    }
    final path = App.dataPath;
    final file = File(source.filePath);
    final script = await file.exists() ? await file.readAsBytes() : null;
    final configuration = SourceConfigurationChange.remove(
      source.key,
      remainingSources: () =>
          _sources.where((item) => !identical(item, source)),
      dataPath: path,
    );
    SourceScriptCheckpoint? checkpoint;
    JSInvokable? restoreRuntime;
    SourceDataWriteFreeze? freeze;
    try {
      freeze = source.freezeDataWrites();
      await freeze.waitForWrites();
      restoreRuntime =
          JsEngine().runCode('''(() => {
        const previous = ComicSource.sources[${jsonEncode(source.key)}];
        return () => {
          if (ComicSource.sources[${jsonEncode(source.key)}] !== previous) {
            ComicSource.sources[${jsonEncode(source.key)}] = previous;
          }
        };
      })()''')
              as JSInvokable;
      checkpoint = await SourceScriptCheckpoint.prepare(
        dataPath: path,
        target: file,
        before: script,
        after: null,
      );
      checkpoint.transaction.bindKey(source.key);
      await configuration.apply(transaction: checkpoint.transaction);
      await checkpoint.verifyOriginal();
      await checkpoint.writeExpected();
      final removed = JsEngine().runCode(
        'delete ComicSource.sources[${jsonEncode(source.key)}];',
      );
      if (removed != true) throw StateError('Source runtime refused removal');
      _sources.remove(source);
    } catch (error, stack) {
      final failures = <SourceMutationError>[
        (stage: 'uninstall source', error: error, stack: stack),
      ];
      await _decideSourceRollback(checkpoint, null, failures);
      if (restoreRuntime != null) {
        await _attempt(failures, 'restore uninstalled runtime', () {
          restoreRuntime!.invoke([]);
        });
        await _attempt(
          failures,
          'release uninstalled runtime backup',
          restoreRuntime.free,
        );
      }
      if (checkpoint != null) {
        await _attempt(
          failures,
          'restore uninstalled script',
          checkpoint.restore,
        );
      }
      await _attempt(
        failures,
        'restore source configuration',
        configuration.rollback,
      );
      if (freeze != null) {
        await _attempt(
          failures,
          'resume uninstalled source writes',
          freeze.resume,
        );
      }
      await _attempt(failures, 'publish restored registry', notifyListeners);
      if (failures.length == 1 && checkpoint != null) {
        await _attempt(
          failures,
          'clean restored script backup',
          () => finishSourceStorageRecovery(path, checkpoint!.discard),
        );
      }
      if (checkpoint != null) {
        await _attempt(
          failures,
          'release failed transaction',
          checkpoint.close,
        );
      }
      _throwRecovery(failures, recoveryPath: checkpoint?.directory.path);
    }
    final failures = <SourceMutationError>[];
    var committed = false;
    await _attempt(failures, 'persist source removal decision', () {
      checkpoint!.transaction.commit();
      committed = true;
    });
    await _attempt(
      failures,
      'release uninstalled runtime backup',
      restoreRuntime.free,
    );
    await _attempt(
      failures,
      'retire uninstalled source writes',
      () => _retireSourceDataWrites(source),
    );
    await _attempt(
      failures,
      'release uninstalled source callbacks',
      source.disposeRuntimeCallbacks,
    );
    await _attempt(failures, 'publish source removal', notifyListeners);
    if (committed && failures.isEmpty) {
      await _attempt(
        failures,
        'clean uninstalled script backup',
        () => finishSourceStorageRecovery(path, checkpoint!.discard),
      );
    }
    await _attempt(failures, 'release source transaction', checkpoint.close);
    if (failures.isNotEmpty) {
      throw SourceMutationFailure(
        state: SourceMutationState.applied,
        failures: failures,
        recoveryPath: checkpoint.directory.path,
      );
    }
  });

  void add(ComicSource source) {
    _checkAccepting();
    _sourceEngine = JsEngine();
    _sources.add(source);
    source.bindDataOwner();
    notifyListeners();
  }

  void remove(String key) {
    _checkAccepting();
    _remove(key);
  }

  void _remove(String key) {
    for (final source in _sources.where((source) => source.key == key)) {
      _retireSourceDataWrites(source);
      source.disposeRuntimeCallbacks();
    }
    _sources.removeWhere((element) => element.key == key);
    notifyListeners();
  }

  bool get isEmpty => _sources.isEmpty;

  FutureOr<Map<String, dynamic>> _getThumbnailLoadingConfig(
    String sourceKey,
    String url,
  ) {
    final comicSource = find(sourceKey);
    return comicSource?.getThumbnailLoadingConfig?.call(url) ?? {};
  }

  Future<String?> _getThumbnailCover(String sourceKey, String cid) async {
    final comicSource = find(sourceKey);
    if (comicSource?.loadComicInfo == null) {
      return null;
    }
    final comicInfo = await comicSource!.loadComicInfo!(cid);
    return comicInfo.data.cover;
  }

  Future<Map<String, dynamic>> _getComicImageLoadingConfig(
    String sourceKey,
    String imageKey,
    String cid,
    String eid,
  ) async {
    final comicSource = find(sourceKey);
    return await comicSource?.getImageLoadingConfig?.call(imageKey, cid, eid) ??
        {};
  }

  /// Key is the source key, value is the version.
  final _availableUpdates = <String, String>{};

  void updateAvailableUpdates(Map<String, String> updates) {
    _checkAccepting();
    _availableUpdates.clear();
    _availableUpdates.addAll(updates);
    notifyListeners();
  }

  Map<String, String> get availableUpdates => Map.from(_availableUpdates);

  void clearSourceUpdate(String key) {
    _checkAccepting();
    _availableUpdates.remove(key);
    notifyListeners();
  }

  void notifyStateChange() {
    notifyListeners();
  }
}
