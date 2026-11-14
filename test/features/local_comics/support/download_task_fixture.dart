import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/local_comics/download_directory_allocator.dart';
import 'package:venera_next/features/local_comics/download_task_storage.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/file_downloader.dart';

Future<void> waitForDownloadTask(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Download did not reach the expected state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

ComicSource downloadFixtureSource(
  String key, {
  LoadComicFunc? loadComicInfo,
  LoadComicPagesFunc? loadComicPages,
}) {
  return ComicSource(
    'Test Source',
    key,
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    loadComicInfo,
    null,
    loadComicPages,
    null,
    null,
    '',
    '',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}

class CompletionQueueTask extends DownloadTask {
  @override
  Future<void> get pendingCleanup => Future.value();
  CompletionQueueTask(this.id);
  @override
  final String id;
  int resumes = 0;
  @override
  ComicType get comicType => const ComicType(17);
  @override
  String get title => id;
  @override
  String? get cover => null;
  @override
  String get message => '';
  @override
  bool get isError => false;
  @override
  bool get isPaused => true;
  @override
  double get progress => 1;
  @override
  int get speed => 0;
  @override
  void cancel() {}
  @override
  void pause() {}
  @override
  void resume() => resumes++;
  @override
  Map<String, dynamic> toJson() => {'id': id};
  @override
  LocalComic toLocalComic() => LocalComic(
    id: id,
    title: id,
    subtitle: '',
    tags: [],
    directory: id,
    chapters: null,
    cover: '',
    comicType: comicType,
    downloadedChapters: [],
    createdAt: DateTime(2026),
  );
}

ImagesDownloadTask pendingImageDownloadTask(
  String source,
  String path, {
  List<String>? chapters,
  ComicImageLoader? loadImage,
}) => ImagesDownloadTask.fromJson(LocalManager(), {
  'type': 'ImagesDownloadTask',
  'source': source,
  'comicId': 'pending',
  'comic': {
    'title': 'Pending',
    'subtitle': '',
    'cover': 'cover.jpg',
    'description': '',
    'tags': <String, List<String>>{},
    'chapters': chapters == null ? null : {'kept': 'Kept', 'new/a': 'New'},
    'sourceKey': source,
    'comicId': 'pending',
  },
  'chapters': chapters,
  'path': path,
  'cover': 'cover.jpg',
  'images': {
    chapters == null ? '' : 'new/a': ['image'],
  },
  'downloadedCount': 0,
  'totalCount': 1,
  'index': 0,
  'chapter': 0,
}, loadImage: loadImage)!;

ComicDetails archiveDownloadComic(String source, {String id = 'archive'}) =>
    ComicDetails.fromJson({
      'title': 'Archive',
      'subtitle': '',
      'cover': 'cover.jpg',
      'description': '',
      'tags': <String, List<String>>{},
      'chapters': null,
      'sourceKey': source,
      'comicId': id,
    });

class ControlledArchiveDownloader extends FileDownloader {
  ControlledArchiveDownloader(super.url, super.savePath, this.statuses);
  final Stream<DownloadingStatus> statuses;
  bool stopped = false;
  @override
  Stream<DownloadingStatus> start() => statuses;

  @override
  Future<void> stop() async {
    await super.stop();
    stopped = true;
  }
}

class DownloadStorageFixture implements DownloadTaskStorage {
  DownloadStorageFixture(this.path);
  @override
  final String path;
  Future<void> Function()? afterAllocate;
  final completed = <DownloadTask>[];
  final removed = <DownloadTask>[];
  int saves = 0;
  LocalComic? comic;

  @override
  Future<DownloadDirectoryAllocation> allocateDownloadDirectory(
    String id,
    ComicType type,
    String name,
  ) async {
    final directory = Directory('$path/output')..createSync();
    await afterAllocate?.call();
    return DownloadDirectoryAllocation(directory, isNew: true);
  }

  @override
  LocalComic? find(String id, ComicType type) => comic;

  @override
  Future<void> saveCurrentDownloadingTasks() async => saves++;

  @override
  void completeTask(DownloadTask task) {
    completed.add(task);
    comic = task.toLocalComic();
  }

  @override
  void retainIncompleteTask(DownloadTask task) {
    comic = task.toLocalComic();
  }

  @override
  void removeTask(DownloadTask task) => removed.add(task);
}
