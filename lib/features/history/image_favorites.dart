import 'package:flutter/foundation.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'history_manager.dart';
import 'image_favorite_actions.dart';
import 'image_favorites_models.dart';
import 'image_favorites_provider.dart';
import 'image_favorites_statistics.dart';

class ImageFavoriteManager with ChangeNotifier {
  ImageFavoriteManager.create({
    required HistoryManager history,
    Future<void> Function(ImageFavorite)? deleteCache,
    Future<ImageFavoritesComputed> Function(String)? readStatistics,
  }) : _history = (() => history),
       _deleteCache = deleteCache ?? ImageFavoritesProvider.deleteFromCache,
       _readStatistics = readStatistics ?? readImageFavoritesStatistics;

  ImageFavoriteManager._()
    : _history = HistoryManager.new,
      _deleteCache = ImageFavoritesProvider.deleteFromCache,
      _readStatistics = readImageFavoritesStatistics;

  static ImageFavoriteManager? _cache;
  factory ImageFavoriteManager() => (_cache ??= ImageFavoriteManager._());
  final HistoryManager Function() _history;
  final Future<void> Function(ImageFavorite) _deleteCache;
  final Future<ImageFavoritesComputed> Function(String) _readStatistics;

  @override
  void notifyListeners() => _history().publishChange(super.notifyListeners);

  Future<List<ImageFavoritesComic>> getAll([String? keyword]) => _history()
      .accessImageFavorites((repository, _) => repository.getAll(keyword));

  Future<ImageFavoritesComic?> find(String id, String sourceKey) => _history()
      .accessImageFavorites((repository, _) => repository.find(id, sourceKey));

  Future<bool> isCollected(String id, String sourceKey, String eid, int page) =>
      _history().accessImageFavorites(
        (repository, _) =>
            repository
                .find(id, sourceKey)
                ?.images
                .any((image) => image.eid == eid && image.page == page) ??
            false,
      );

  /// Capture the intent now; read and mutate current data only after admission.
  Future<ImageFavoriteResult> toggle(
    ImageFavoriteInput input, {
    void Function()? checkActive,
  }) {
    final snapshot = input.detached();
    return _history().accessImageFavorites((repository, _) async {
      checkActive?.call();
      final removed = <ImageFavorite>[];
      var changed = false;
      final result = ImageFavoriteActions(
        findComic: repository.find,
        save: (comic) {
          repository.save(comic);
          changed = true;
        },
        remove: (image) {
          repository.removeImages([image]);
          removed.add(image);
          changed = true;
        },
      ).toggle(snapshot);
      if (changed) await _finishCommit(removed);
      return result;
    });
  }

  Future<void> deleteImageFavorite(Iterable<ImageFavorite> selected) {
    final images = selected.map((image) => image.copyWith()).toList();
    if (images.isEmpty) return Future.value();
    return _history().accessImageFavorites((repository, _) async {
      repository.removeImages(images);
      await _finishCommit(images);
    });
  }

  Future<void> _finishCommit(List<ImageFavorite> removed) async {
    final failures = <({Object error, StackTrace stackTrace})>[];
    // Start all cache removals before yielding; each captures its original path.
    await Future.wait(
      removed.map((image) async {
        try {
          await _deleteCache(image);
        } catch (error, stack) {
          failures.add((error: error, stackTrace: stack));
        }
      }),
    );
    try {
      notifyListeners();
    } catch (error, stack) {
      failures.add((error: error, stackTrace: stack));
    }
    if (failures.isNotEmpty) {
      final first = failures.first;
      Error.throwWithStackTrace(
        PersistenceFailure(
          commitState: PersistenceCommitState.committed,
          cause: first.error,
          stackTrace: first.stackTrace,
          cleanupFailures: failures.skip(1).toList(),
        ),
        first.stackTrace,
      );
    }
  }

  void notifyChanges() => notifyListeners();

  Future<ImageFavoritesComputed> compute() =>
      _history().accessImageFavorites((repository, path) {
        if (repository.count() > 100) return _readStatistics(path);
        return computeImageFavorites(repository.getAll());
      });
}
