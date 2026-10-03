import 'source_failure.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/app_dio.dart';

import 'comic_source_manager.dart';
import 'source.dart';
import 'source_repositories.dart';

/// Source updates shared by interactive and headless callers.
/// Presentation owns dialogs; the service owns request and commit lifetimes.
class SourceUpdateService {
  SourceUpdateService({Dio Function()? createDio})
    : _createDio = createDio ?? (() => AppDio());

  static final instance = SourceUpdateService();

  final Dio Function() _createDio;
  final _updating = <String, CancelToken>{};
  Future<int>? _checking;
  SourceUpdateCheck? lastUpdateCheck;

  bool isUpdating(String sourceKey) => _updating.containsKey(sourceKey);

  void cancel(String sourceKey) {
    // Release synchronously so a retry can start before old I/O unwinds.
    _updating.remove(sourceKey)?.cancel();
  }

  Future<void> update(ComicSource source, {void Function()? onCommit}) async {
    if (isUpdating(source.key)) {
      throw const SourceFailure(SourceFailureCode.updateInProgress);
    }
    final token = CancelToken();
    _updating[source.key] = token;
    Dio? dio;
    try {
      dio = _createDio();
      final store = SourceRepositories.instance;
      final origin = store.originFor(source.key);
      final repository = store.find(origin?.repositoryId);
      final url = await store.updateUrl(
        source,
        client: dio,
        cancelToken: token,
      );
      if (token.isCancelled) throw token.cancelError!;
      final res = await dio.get<String>(
        url,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.plain,
          headers: {'cache-time': 'no'},
        ),
      );
      if (token.isCancelled) throw token.cancelError!;
      await ComicSourceManager().replaceScript(
        source,
        res.data!,
        validate: () {
          if (token.isCancelled) throw token.cancelError!;
          if (store.originFor(source.key)?.repositoryId !=
                  origin?.repositoryId ||
              store.originFor(source.key)?.url != origin?.url ||
              ComicSource.find(source.key)?.filePath != source.filePath ||
              (repository != null &&
                  store.find(repository.id)?.url != repository.url)) {
            throw const SourceFailure(SourceFailureCode.repositoryChanged);
          }
          // The serialized script commit is atomic; UI cancellation ends here.
          onCommit?.call();
        },
        origin: repository == null
            ? null
            : SourceOrigin(
                kind: 'repository',
                repositoryId: repository.id,
                repositoryName: repository.name,
                url: url,
              ),
      );
    } catch (error, stack) {
      if (token.isCancelled) {
        throw SourceFailure(
          SourceFailureCode.cancelled,
          cause: error,
          stackTrace: stack,
        );
      }
      Log.error('Update comic source', '$error\n$stack');
      rethrow;
    } finally {
      dio?.close();
      if (identical(_updating[source.key], token)) {
        _updating.remove(source.key);
      }
    }
  }

  Future<int> checkUpdates() {
    return _checking ??= _checkUpdates().whenComplete(() => _checking = null);
  }

  Future<int> _checkUpdates() async {
    ComicSourceManager().updateAvailableUpdates({});
    final revision = SourceRepositories.instance.revision;
    var result = await SourceRepositories.instance.checkUpdates(
      ComicSource.all().where((source) => source.filePath.isNotEmpty).toList(),
    );
    if (revision != SourceRepositories.instance.revision) {
      result = SourceUpdateCheck(
        updates: {},
        failures: [
          const SourceCheckFailure(
            SourceFailure(SourceFailureCode.repositoryChanged),
          ),
        ],
        checked: 0,
        skipped: ComicSource.all().length,
      );
    }
    lastUpdateCheck = result;
    ComicSourceManager().updateAvailableUpdates(result.updates);
    return result.updates.isEmpty && result.failures.isNotEmpty
        ? -1
        : result.updates.length;
  }
}
