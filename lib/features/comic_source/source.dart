import 'package:flutter_qjs/flutter_qjs.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';

import 'category.dart';
import 'favorites.dart';
import 'models.dart';
import 'normalization.dart';
import 'source_mutation_failure.dart';
import 'source_data_storage.dart';
import 'source_parser_context.dart';
import 'types.dart';

typedef ComicSourceListResolver = List<ComicSource> Function();
typedef ComicSourceResolver = ComicSource? Function(String key);
typedef ComicSourceIntKeyResolver = ComicSource? Function(int key);
typedef ComicSourceIsEmptyResolver = bool Function();
typedef ComicSourceDataSavedHandler = Future<void> Function();

ComicSourceListResolver? _comicSourceListResolver;
ComicSourceResolver? _comicSourceResolver;
ComicSourceIntKeyResolver? _comicSourceIntKeyResolver;
ComicSourceIsEmptyResolver? _comicSourceIsEmptyResolver;
ComicSourceDataSavedHandler? _comicSourceDataSavedHandler;

Future<void> _publishSourceDataSaved() {
  Future<void>? completion;
  AppDataOperations.instance.publish(() {
    completion = _comicSourceDataSavedHandler?.call();
  });
  return completion ?? Future<void>.value();
}

void configureComicSourceRegistry({
  required ComicSourceListResolver all,
  required ComicSourceResolver find,
  required ComicSourceIntKeyResolver fromIntKey,
  required ComicSourceIsEmptyResolver isEmpty,
}) {
  _comicSourceListResolver = all;
  _comicSourceResolver = find;
  _comicSourceIntKeyResolver = fromIntKey;
  _comicSourceIsEmptyResolver = isEmpty;
}

void configureComicSourceDataSavedHandler(
  ComicSourceDataSavedHandler? handler,
) {
  _comicSourceDataSavedHandler = handler;
}

class ComicSource {
  final JsCallbackScope? _runtimeCallbacks;
  final SourceDataStorage _dataStorage;
  final SourceParserContext? _runtimeContext;

  JsSourceIdentity? get runtimeIdentity => _runtimeContext?.identity;

  void disposeRuntimeCallbacks() => _runtimeCallbacks?.dispose();

  static List<ComicSource> all() => _comicSourceListResolver?.call() ?? [];

  static ComicSource? find(String key) => _comicSourceResolver?.call(key);

  static ComicSource requireRuntime(String key, JsSourceIdentity identity) {
    final source = find(key);
    if (source == null || source.runtimeIdentity != identity) {
      throw StateError('Source belongs to a different runtime instance');
    }
    return source;
  }

  static ComicSource? fromIntKey(int key) {
    return _comicSourceIntKeyResolver?.call(key);
  }

  static bool get isEmpty => _comicSourceIsEmptyResolver?.call() ?? true;

  /// Name of this source.
  final String name;

  /// Identifier of this source.
  final String key;

  int get intKey {
    return key.hashCode;
  }

  /// Account config.
  final AccountConfig? account;

  /// Category data used to build a static category tags page.
  final CategoryData? categoryData;

  /// Category comics data used to build a comics page with a category tag.
  final CategoryComicsData? categoryComicsData;

  /// Favorite data used to build favorite page.
  final FavoriteData? favoriteData;

  /// Explore pages.
  final List<ExplorePageData> explorePages;

  /// Search page.
  final SearchPageData? searchPageData;

  /// Load comic info.
  final LoadComicFunc? loadComicInfo;

  final ComicThumbnailLoader? loadComicThumbnail;

  /// Load comic pages.
  final LoadComicPagesFunc? loadComicPages;

  final GetImageLoadingConfigFunc? getImageLoadingConfig;

  final GetThumbnailLoadingConfigFunc? getThumbnailLoadingConfig;

  Map<String, dynamic> _data;

  /// An immutable snapshot, including every nested map/list. Editors receive
  /// detached drafts and cannot mutate this snapshot after publication.
  Map<String, dynamic> get data => _data;

  static Map<String, dynamic> _snapshot(Map<String, dynamic> value) {
    dynamic freeze(dynamic value) => switch (value) {
      Map value => Map<String, dynamic>.unmodifiable(
        value.map((key, value) => MapEntry(key as String, freeze(value))),
      ),
      List value => List<dynamic>.unmodifiable(value.map(freeze)),
      _ => value,
    };
    return freeze(jsonDecode(jsonEncode(value))) as Map<String, dynamic>;
  }

  bool get isLogged => data["account"] != null;

  final String filePath;

  final String url;

  final String version;

  final CommentsLoader? commentsLoader;

  final SendCommentFunc? sendCommentFunc;

  final ChapterCommentsLoader? chapterCommentsLoader;

  final SendChapterCommentFunc? sendChapterCommentFunc;

  final RegExp? idMatcher;

  final LikeOrUnlikeComicFunc? likeOrUnlikeComic;

  final VoteCommentFunc? voteCommentFunc;

  final LikeCommentFunc? likeCommentFunc;

  final Map<String, Map<String, dynamic>>? settings;

  final Map<String, Map<String, String>>? translations;

  final HandleClickTagEvent? handleClickTagEvent;

  /// Callback when a tag suggestion is selected in search.
  final TagSuggestionSelectFunc? onTagSuggestionSelected;

  final LinkHandler? linkHandler;

  final bool enableTagsSuggestions;

  final bool enableTagsTranslate;

  final StarRatingFunc? starRatingFunc;

  final ArchiveDownloader? archiveDownloader;

  Future<void> initializeRuntime() async {
    final context = _runtimeContext;
    if (context == null) return;
    await context.runCode('''(() => {
      const result = ${context.sourceExpression}.init?.();
      return result && typeof result.then === 'function'
        ? result.then(() => undefined) : undefined;
    })()''', filePath);
  }

  Future<void> loadData() async {
    _checkDataWrites();
    final path = _dataPath ??= App.dataPath;
    final epoch = _writeEpoch;
    await _trackSave(
      AppDataOperations.instance.access(() async {
        _checkDataAdmission(epoch);
        final file = File('$path/comic_source/$key.data');
        if (await file.exists()) {
          final loaded = Map<String, dynamic>.from(
            jsonDecode(await file.readAsString()),
          );
          _checkDataAdmission(epoch);
          _data = _snapshot(loaded);
        }
      }),
    );
  }

  String? _dataPath;
  bool _hasDataOwner = false;
  int _writeEpoch = 0;
  SourceDataWriteFreeze? _writeFreeze;
  Future<void> _fileTail = Future.value();
  Future<void> _notificationTail = Future.value();
  final _acceptedSaves = <Future<void>>{};
  Future<void>? _dataCloseFuture;
  ({Object error, StackTrace stack})? _saveFailure;
  bool _stagingData = false;
  bool _stagedSave = false;
  int _stagedRevision = 0;
  bool _committingData = false;
  bool _stagedDataApplied = false;
  final _dataCleanupFailures = <SourceMutationError>[];
  String? _stagedContents;
  String? _stagingPath;
  bool _dataPublicationPending = false;
  int _dataRevision = 0;

  /// A registered source must never redirect an old instance to a new owner.
  void bindDataOwner() => _hasDataOwner = true;

  void _checkDataWrites() {
    if (_dataCloseFuture != null || _writeFreeze != null) {
      throw StateError('Comic source data is closing or frozen');
    }
    if (_hasDataOwner && !identical(find(key), this)) {
      throw StateError('Comic source data belongs to a retired instance');
    }
    if (_dataPath != null && _dataPath != App.dataPath) {
      throw StateError('Comic source data belongs to another directory');
    }
  }

  void _checkDataAdmission(int epoch) {
    if (epoch != _writeEpoch ||
        (_hasDataOwner && !identical(find(key), this))) {
      throw StateError(
        'Source data operation was invalidated before completion',
      );
    }
  }

  /// Synchronous JS bridges validate before editing memory, preserving their
  /// return contract. Accepted persistence owns a separate completion Future.
  void editDataSync(void Function(Map<String, dynamic>) edit) {
    AppDataOperations.instance.accessSync(() {
      _checkDataWrites();
      _applyDataEdit(edit);
      unawaited(saveData());
    });
  }

  Future<void> editData(void Function(Map<String, dynamic>) edit) {
    try {
      return prepareDataEdit(edit).save();
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  /// Capture the source and directory before an asynchronous UI operation.
  /// Retrying an applied draft only persists the current snapshot, so later
  /// edits survive and business callbacks are not executed again.
  SourceDataEdit prepareDataEdit(void Function(Map<String, dynamic>) edit) {
    _checkDataWrites();
    return SourceDataEdit._(
      this,
      _dataPath ??= App.dataPath,
      _writeEpoch,
      edit,
    );
  }

  void _applyDataEdit(void Function(Map<String, dynamic>) edit) {
    final draft = Map<String, dynamic>.from(jsonDecode(jsonEncode(_data)));
    edit(draft);
    _data = _snapshot(draft);
  }

  Future<void> _saveEdit(SourceDataEdit edit) {
    try {
      _checkDataWrites();
      final writing = AppDataOperations.instance.access<int?>(() {
        _checkDataAdmission(edit._epoch);
        if (App.dataPath != edit._path) {
          throw StateError('Source edit belongs to another directory');
        }
        if (!edit._applied) {
          _applyDataEdit(edit._edit);
          edit._applied = true;
        }
        final contents = jsonEncode(_data);
        if (_stagingData) {
          _stagedSave = true;
          _stagedContents = contents;
          _stagedRevision++;
          return null;
        }
        return _enqueueFileWrite(edit._path, contents);
      });
      return _trackSave(_publishFileWrite(writing));
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  /// Freeze new edits before draining admitted files. Requests still awaiting
  /// global admission are invalidated, never awaited from an exclusive owner.
  SourceDataWriteFreeze freezeDataWrites({bool captureData = false}) {
    _checkDataWrites();
    final snapshot = captureData ? jsonEncode(data) : null;
    return _writeFreeze = SourceDataWriteFreeze._(
      this,
      ++_writeEpoch,
      snapshot,
      _fileTail,
    );
  }

  /// Until commit, saveData acknowledges a captured draft, not persistence.
  /// The manager can await init without committing credentials before scripts
  /// and settings are ready. A failed pre-commit draft may be discarded.
  void stageDataWrites({Map<String, dynamic>? initialData}) =>
      AppDataOperations.instance.accessSync(() {
        _checkDataWrites();
        if (_stagingData ||
            _committingData ||
            _stagedSave ||
            _acceptedSaves.isNotEmpty) {
          throw StateError('Source data already has pending writes');
        }
        if (initialData != null) _data = _snapshot(initialData);
        _dataPath ??= App.dataPath;
        _stagingPath = App.dataPath;
        _stagingData = true;
        _stagedDataApplied = false;
      });

  Future<void> commitDataWrites({
    bool publish = true,
    void Function(String path, String key, String contents)? beforeWrite,
  }) {
    try {
      _checkDataWrites();
      if (_committingData) {
        throw StateError('Source data commit is already running');
      }
      if (_stagingPath != null && _stagingPath != App.dataPath) {
        throw StateError('Staged source data belongs to another directory');
      }
      final path = _dataPath ??= App.dataPath;
      final epoch = _writeEpoch;
      _committingData = true;
      final writing = AppDataOperations.instance.access(() {
        _checkDataAdmission(epoch);
        final result = _fileTail.then(
          (_) => _commitStagedData(path, beforeWrite),
        );
        _fileTail = result.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        );
        return result;
      });
      final settled = writing.whenComplete(() {
        _committingData = false;
      });
      return _trackSave(
        publish
            ? _publishFileWrite(
                settled.then<int?>(
                  (_) => _dataPublicationPending ? _dataRevision : null,
                ),
              )
            : settled,
      );
    } catch (error, stack) {
      final rejected = Future<void>.error(error, stack);
      unawaited(rejected.catchError((Object _, StackTrace _) {}));
      return rejected;
    }
  }

  Future<void> _commitStagedData(
    String path,
    void Function(String path, String key, String contents)? beforeWrite,
  ) async {
    final previousCleanup = List<SourceMutationError>.of(_dataCleanupFailures);
    var applied = _stagedDataApplied;
    final failures = <SourceMutationError>[];
    String? recoveryPath;
    while (_stagedSave) {
      final revision = _stagedRevision;
      final contents = _stagedContents!;
      var written = false;
      try {
        beforeWrite?.call(path, key, contents);
        await _dataStorage.write(path, key, contents);
        written = true;
      } catch (error, stack) {
        if (error is SourceMutationFailure) {
          written = error.state == SourceMutationState.applied;
          failures.add((
            stage: 'commit source data snapshot',
            error: error,
            stack: stack,
          ));
          recoveryPath ??= error.recoveryPath;
          if (error.recoveryPath != null) {
            _dataCleanupFailures.add((
              stage: 'clean source data',
              error: error,
              stack: stack,
            ));
          }
        } else {
          failures.add((
            stage: 'commit source data',
            error: error,
            stack: stack,
          ));
        }
        if (!written) {
          // Once any snapshot reached disk, the manager must keep this source.
          // End staging so ordinary saves can retry the latest in-memory data;
          // retain the exact pending snapshot for an explicit commit retry too.
          if (applied) {
            _stagingData = false;
            final failure = SourceMutationFailure(
              state: SourceMutationState.applied,
              failures: failures,
              recoveryPath: recoveryPath,
            );
            _saveFailure = (error: failure, stack: stack);
            Error.throwWithStackTrace(failure, stack);
          }
          if (failures.length == 1 && error is! SourceMutationFailure) {
            Error.throwWithStackTrace(error, stack);
          }
          throw SourceMutationFailure(
            state: SourceMutationState.recoveryRequired,
            failures: failures,
            recoveryPath: recoveryPath,
          );
        }
      }
      applied = true;
      _stagedDataApplied = true;
      _saveFailure = null;
      _dataPublicationPending = true;
      _dataRevision++;
      // A callback can accept another snapshot during write or cleanup. Only
      // acknowledge the snapshot we wrote; drain later ones before closing.
      if (revision == _stagedRevision) {
        _stagedSave = false;
        _stagedContents = null;
      }
    }
    // No await between the final revision check and closing the staging window.
    _stagingData = false;
    await _retryDataCleanup(previousCleanup);
    if (failures.isNotEmpty) {
      throw SourceMutationFailure(
        state: SourceMutationState.applied,
        failures: failures,
        recoveryPath: recoveryPath,
      );
    }
  }

  /// Publication happens after script/settings/data commit. Its failure must
  /// not restore an old script on top of newly committed credentials.
  Future<void> publishDataWrites() => _dataPublicationPending
      ? _enqueueNotification(_dataRevision)
      : Future.value();

  Future<void> _enqueueNotification(int revision) {
    final result = _notificationTail.then((_) async {
      try {
        await _publishSourceDataSaved();
        if (revision == _dataRevision) _dataPublicationPending = false;
      } catch (error, stack) {
        throw SourceMutationFailure(
          state: SourceMutationState.applied,
          failures: [
            (stage: 'publish source data', error: error, stack: stack),
          ],
        );
      }
    });
    _notificationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> saveData() {
    try {
      _checkDataWrites();
      final path = _dataPath ??= App.dataPath;
      final contents = jsonEncode(data);
      if (_stagingData) {
        _stagedSave = true;
        _stagedContents = contents;
        _stagedRevision++;
        return Future.value();
      }
      final epoch = _writeEpoch;
      final writing = AppDataOperations.instance.access(() {
        _checkDataAdmission(epoch);
        return _enqueueFileWrite(path, contents);
      });
      // Notification may request fresh exclusive work. Release file admission
      // first and keep publication out of the file queue.
      return _trackSave(_publishFileWrite(writing));
    } catch (error, stack) {
      final rejected = Future<void>.error(error, stack);
      unawaited(rejected.catchError((Object _, StackTrace _) {}));
      return rejected;
    }
  }

  Future<void> _publishFileWrite(Future<int?> writing) async {
    int? revision;
    try {
      revision = await writing;
    } on SourceMutationFailure catch (error, stack) {
      if (error.state != SourceMutationState.applied) rethrow;
      try {
        await publishDataWrites();
      } catch (publication, publicationStack) {
        throw SourceMutationFailure(
          state: SourceMutationState.applied,
          failures: [
            ...error.failures,
            (
              stage: 'publish source data',
              error: publication,
              stack: publicationStack,
            ),
          ],
          recoveryPath: error.recoveryPath,
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
    if (revision != null) await _enqueueNotification(revision);
  }

  Future<void> _trackSave(Future<void> result) {
    late final Future<void> settled;
    settled = result
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            Log.error('ComicSource data', '$name: $error', stack);
          },
        )
        .whenComplete(() => _acceptedSaves.remove(settled));
    _acceptedSaves.add(settled);
    return result;
  }

  Future<int> _enqueueFileWrite(String path, String contents) {
    final result = _fileTail.then((_) async {
      final previousCleanup = List<SourceMutationError>.of(
        _dataCleanupFailures,
      );
      try {
        await _dataStorage.write(path, key, contents);
        _stagedSave = false;
        _stagedContents = null;
        _saveFailure = null;
        _dataPublicationPending = true;
        await _retryDataCleanup(previousCleanup);
        return ++_dataRevision;
      } catch (error, stack) {
        if (error is SourceMutationFailure) {
          if (error.recoveryPath != null) {
            _dataCleanupFailures.add((
              stage: 'clean source data',
              error: error,
              stack: stack,
            ));
          }
          if (error.state == SourceMutationState.applied) {
            _stagedSave = false;
            _stagedContents = null;
            _dataPublicationPending = true;
            _dataRevision++;
          }
        }
        _saveFailure = (error: error, stack: stack);
        rethrow;
      }
    });
    _fileTail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Retry cleanup without saving memory or replaying the original edit. A
  /// failed uncommitted write remains a save failure even after cleanup succeeds.
  Future<void> retryDataCleanup() {
    try {
      _checkDataWrites();
      final epoch = _writeEpoch;
      return _trackSave(
        AppDataOperations.instance.access(() {
          _checkDataAdmission(epoch);
          final result = _fileTail.then((_) async {
            final failures = await _retryDataCleanup();
            if (failures.isNotEmpty) {
              throw SourceMutationFailure(
                state: SourceMutationState.recoveryRequired,
                failures: failures,
              );
            }
          });
          _fileTail = result.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          );
          return result;
        }),
      );
    } catch (error, stack) {
      return _trackSave(Future.error(error, stack));
    }
  }

  Future<List<SourceMutationError>> _retryDataCleanup([
    List<SourceMutationError>? pending,
  ]) async {
    final failures = <SourceMutationError>[];
    for (final failure in pending ?? List.of(_dataCleanupFailures)) {
      final error = failure.error;
      if (error is! SourceDataWriteFailure) {
        // Adapters without an ownership receipt cannot be cleared by guessing
        // a directory from their diagnostic path.
        failures.add(failure);
        continue;
      }
      try {
        await _dataStorage.retryCleanup(error.cleanup);
        if (!error.cleanupResolvesFailure) {
          failures.add(failure);
          continue;
        }
        _dataCleanupFailures.remove(failure);
        if (error.state == SourceMutationState.applied &&
            identical(_saveFailure?.error, error)) {
          _saveFailure = null;
        }
      } catch (retry, stack) {
        failures.addAll([
          failure,
          (stage: 'retry source data cleanup', error: retry, stack: stack),
        ]);
      }
    }
    return failures;
  }

  /// Stop new saves after the host has drained source work, then settle every
  /// accepted write and its data-change notification before releasing bindings.
  Future<void> closeDataWrites() => _dataCloseFuture ??= _closeDataWrites();

  Future<void> _closeDataWrites() async {
    while (_acceptedSaves.isNotEmpty) {
      await Future.wait(_acceptedSaves.toList());
    }
    final failures = _dataCleanupFailures.isEmpty
        ? <SourceMutationError>[]
        : await AppDataOperations.instance.access(() => _retryDataCleanup());
    try {
      await publishDataWrites();
    } catch (error, stack) {
      failures.add((
        stage: 'finish source data publication',
        error: error,
        stack: stack,
      ));
    }
    final failure = _saveFailure;
    if (failure != null) {
      failures.add((
        stage: 'finish source data writes',
        error: failure.error,
        stack: failure.stack,
      ));
    }
    if (failures.length == 1) {
      Error.throwWithStackTrace(failures.single.error, failures.single.stack);
    }
    if (failures.isNotEmpty) {
      throw SourceMutationFailure(
        state: SourceMutationState.applied,
        failures: failures,
      );
    }
  }

  Future<bool> reLogin() async {
    if (data["account"] == null) {
      return false;
    }
    final List accountData = data["account"];
    var res = await account!.login!(accountData[0], accountData[1]);
    if (res.error) {
      Log.error("Failed to re-login", res.errorMessage ?? "Error");
    }
    return !res.error;
  }

  /// Get settings dynamically from JavaScript source.
  /// This allows sources to use getters for dynamic settings that can change at runtime.
  JsCallbackScope createSettingsCallbackScope() =>
      _runtimeCallbacks?.fork() ?? JsCallbackScope();

  Map<String, Map<String, dynamic>>? getSettingsDynamic({
    required JsCallbackScope callbacks,
  }) {
    dynamic value;
    try {
      final context = _runtimeContext;
      if (context == null) return settings;
      value = context.getValue('settings');
      return normalizeComicSourceSettings(
        value,
        retainCallback: (function) =>
            context.retainCallback(function, scope: callbacks),
      );
    } catch (e) {
      Log.error("ComicSource", "Failed to get dynamic settings: $e");
      return settings;
    } finally {
      JSRef.freeRecursive(value);
    }
  }

  ComicSource(
    this.name,
    this.key,
    this.account,
    this.categoryData,
    this.categoryComicsData,
    this.favoriteData,
    this.explorePages,
    this.searchPageData,
    this.settings,
    this.loadComicInfo,
    this.loadComicThumbnail,
    this.loadComicPages,
    this.getImageLoadingConfig,
    this.getThumbnailLoadingConfig,
    this.filePath,
    this.url,
    this.version,
    this.commentsLoader,
    this.sendCommentFunc,
    this.chapterCommentsLoader,
    this.sendChapterCommentFunc,
    this.likeOrUnlikeComic,
    this.voteCommentFunc,
    this.likeCommentFunc,
    this.idMatcher,
    this.translations,
    this.handleClickTagEvent,
    this.onTagSuggestionSelected,
    this.linkHandler,
    this.enableTagsSuggestions,
    this.enableTagsTranslate,
    this.starRatingFunc,
    this.archiveDownloader, {
    JsCallbackScope? runtimeCallbacks,
    SourceParserContext? runtimeContext,
    Map<String, dynamic> initialData = const {},
    SourceDataStorage dataStorage = const SourceDataStorage(),
  }) : _runtimeCallbacks = runtimeCallbacks,
       _runtimeContext = runtimeContext,
       _data = _snapshot(initialData),
       _dataStorage = dataStorage;
}

/// One draft application with retryable persistence in its original source.
class SourceDataEdit {
  SourceDataEdit._(this._source, this._path, this._epoch, this._edit);
  final ComicSource _source;
  final String _path;
  final int _epoch;
  final void Function(Map<String, dynamic>) _edit;
  bool _applied = false;

  void checkCurrent() {
    _source._checkDataWrites();
    _source._checkDataAdmission(_epoch);
    if (App.dataPath != _path) {
      throw StateError('Source edit belongs to another directory');
    }
  }

  Future<void> save() => _source._saveEdit(this);
}

/// Authentication succeeded; only the captured data edit needs retrying.
class SourceLoginPersistenceFailure implements Exception {
  SourceLoginPersistenceFailure(this.edit, this.cause, this.stackTrace);
  final SourceDataEdit edit;
  final Object cause;
  final StackTrace stackTrace;
  @override
  String toString() => cause.toString();
}

/// A single authentication attempt. Once authentication or its credential edit
/// succeeds, retries finish persistence without repeating the network action.
class SourceLoginAttempt {
  SourceLoginAttempt.password(this.source, String username, String password)
    : _authenticate = (() => source.account!.login!(username, password)),
      _cookies = false,
      _path = App.dataPath,
      _epoch = source._writeEpoch;

  SourceLoginAttempt.cookies(this.source, List<String> cookies)
    : _authenticate = _cookieValidator(source, cookies),
      _cookies = true,
      _path = App.dataPath,
      _epoch = source._writeEpoch;

  static Future<Res<bool>> Function() _cookieValidator(
    ComicSource source,
    List<String> cookies,
  ) {
    final captured = List<String>.unmodifiable(cookies);
    final validate = source.account!.validateCookies!;
    return () async => Res(await validate(List.of(captured)));
  }

  final ComicSource source;
  final Future<Res<bool>> Function() _authenticate;
  final bool _cookies;
  final String _path;
  final int _epoch;
  SourceDataEdit? _edit;
  bool _authenticated = false;
  bool _saving = false;

  Future<Res<bool>> save() async {
    if (_saving) throw StateError('Login attempt is already running');
    _saving = true;
    try {
      return await _save();
    } finally {
      _saving = false;
    }
  }

  Future<Res<bool>> _save() async {
    source._checkDataWrites();
    source._checkDataAdmission(_epoch);
    if (App.dataPath != _path) {
      throw StateError('Login belongs to another directory');
    }
    if (!_authenticated) {
      final result = await _authenticate();
      source._checkDataWrites();
      source._checkDataAdmission(_epoch);
      if (App.dataPath != _path) {
        throw StateError('Login belongs to another directory');
      }
      final failure = result.failure?.cause;
      if (failure is SourceLoginPersistenceFailure) {
        _edit = failure.edit;
        _authenticated = true;
        Error.throwWithStackTrace(failure.cause, failure.stackTrace);
      }
      if (result.error || !result.data) return result;
      _authenticated = true;
      if (_cookies) {
        _edit = source.prepareDataEdit((draft) => draft['account'] = 'ok');
      }
    }
    await _edit?.save();
    return const Res(true);
  }
}

/// A reversible owner for one source's admitted-write drain and data snapshot.
class SourceDataWriteFreeze {
  SourceDataWriteFreeze._(
    this._source,
    this._epoch,
    this._snapshot,
    this._settled,
  );
  final ComicSource _source;
  final int _epoch;
  final String? _snapshot;
  final Future<void> _settled;

  Map<String, dynamic> get data => Map.from(
    jsonDecode(
      _snapshot ??
          (throw StateError('This freeze does not capture source data')),
    ),
  );

  // Failed writes still settle the barrier. Their callers and eventual close
  // retain the failure; an old failure must not prevent an import from restoring
  // data. This barrier prevents overlap, not a claim that old data is durable.
  Future<void> waitForWrites() => _settled;

  void resume() {
    if (_source._writeEpoch != _epoch ||
        !identical(_source._writeFreeze, this)) {
      throw StateError('Source write freeze has expired');
    }
    if (_source._dataCloseFuture != null) {
      throw StateError('Source data is closed');
    }
    _source._writeFreeze = null;
  }
}

class AccountConfig {
  final LoginFunction? login;

  final String? loginWebsite;

  final String? registerWebsite;

  final FutureOr<void> Function() logout;

  final List<AccountInfoItem> infoItems;

  final bool Function(String url, String title)? checkLoginStatus;

  final FutureOr<void> Function()? onLoginWithWebviewSuccess;

  final List<String>? cookieFields;

  final Future<bool> Function(List<String>)? validateCookies;

  const AccountConfig(
    this.login,
    this.loginWebsite,
    this.registerWebsite,
    this.logout,
    this.checkLoginStatus,
    this.onLoginWithWebviewSuccess,
    this.cookieFields,
    this.validateCookies,
  ) : infoItems = const [];
}

class AccountInfoItem {
  final String title;
  final String Function()? data;
  final void Function()? onTap;
  final WidgetBuilder? builder;

  AccountInfoItem({required this.title, this.data, this.onTap, this.builder});
}

class LoadImageRequest {
  String url;

  Map<String, String> headers;

  LoadImageRequest(this.url, this.headers);
}

class ExplorePageData {
  final String title;

  final ExplorePageType type;

  final ComicListBuilder? loadPage;

  final ComicListBuilderWithNext? loadNext;

  final Future<Res<List<ExplorePagePart>>> Function()? loadMultiPart;

  /// return a `List` contains `List<Comic>` or `ExplorePagePart`
  final Future<Res<List<Object>>> Function(int index)? loadMixed;

  final Listenable? changeListenable;

  final Future<void> Function()? onRefresh;

  ExplorePageData(
    this.title,
    this.type,
    this.loadPage,
    this.loadNext,
    this.loadMultiPart,
    this.loadMixed, {
    this.changeListenable,
    this.onRefresh,
  });
}

class ExplorePagePart {
  final String title;

  final List<Comic> comics;

  /// If this is not null, the [ExplorePagePart] will show a button to jump to new page.
  ///
  /// Value of this field should match the following format:
  ///   - search:keyword
  ///   - category:categoryName
  ///
  /// End with `@`+`param` if the category has a parameter.
  final PageJumpTarget? viewMore;

  const ExplorePagePart(this.title, this.comics, this.viewMore);
}

enum ExplorePageType {
  multiPageComicList,
  singlePageWithMultiPart,
  mixed,
  override,
}

typedef SearchFunction =
    Future<Res<List<Comic>>> Function(
      String keyword,
      int page,
      List<String> searchOption,
    );

typedef SearchNextFunction =
    Future<Res<List<Comic>>> Function(
      String keyword,
      String? next,
      List<String> searchOption,
    );

class SearchPageData {
  /// If this is not null, the default value of search options will be first element.
  final List<SearchOptions>? searchOptions;

  final SearchFunction? loadPage;

  final SearchNextFunction? loadNext;

  const SearchPageData(this.searchOptions, this.loadPage, this.loadNext);
}

class SearchOptions {
  final LinkedHashMap<String, String> options;

  final String label;

  final String type;

  final String? defaultVal;

  const SearchOptions(this.options, this.label, this.type, this.defaultVal);

  String get defaultValue => defaultVal ?? options.keys.firstOrNull ?? "";
}

typedef CategoryComicsLoader =
    Future<Res<List<Comic>>> Function(
      String category,
      String? param,
      List<String> options,
      int page,
    );

typedef CategoryOptionsLoader =
    Future<Res<List<CategoryComicsOptions>>> Function(
      String category,
      String? param,
    );

class CategoryComicsData {
  /// options
  final List<CategoryComicsOptions>? options;

  final CategoryOptionsLoader? optionsLoader;

  /// [category] is the one clicked by the user on the category page.
  ///
  /// if [BaseCategoryPart.categoryParams] is not null, [param] will be not null.
  ///
  /// [Res.subData] should be maxPage or null if there is no limit.
  final CategoryComicsLoader load;

  final RankingData? rankingData;

  const CategoryComicsData({
    this.options,
    this.optionsLoader,
    required this.load,
    this.rankingData,
  });
}

class RankingData {
  final Map<String, String> options;

  final Future<Res<List<Comic>>> Function(String option, int page)? load;

  final Future<Res<List<Comic>>> Function(String option, String?)? loadWithNext;

  const RankingData(this.options, this.load, this.loadWithNext);
}

class CategoryComicsOptions {
  // The label will not be displayed if it is empty.
  final String label;

  /// Use a [LinkedHashMap] to describe an option list.
  /// key is for loading comics, value is the name displayed on screen.
  /// Default value will be the first of the Map.
  final LinkedHashMap<String, String> options;

  /// If [notShowWhen] contains category's name, the option will not be shown.
  final List<String> notShowWhen;

  final List<String>? showWhen;

  const CategoryComicsOptions(
    this.label,
    this.options,
    this.notShowWhen,
    this.showWhen,
  );
}

class LinkHandler {
  final List<String> domains;

  final String? Function(String url) linkToId;

  const LinkHandler(this.domains, this.linkToId);
}

class ArchiveDownloader {
  final Future<Res<List<ArchiveInfo>>> Function(String cid) getArchives;

  final Future<Res<String>> Function(String cid, String aid) getDownloadUrl;

  const ArchiveDownloader(this.getArchives, this.getDownloadUrl);
}
