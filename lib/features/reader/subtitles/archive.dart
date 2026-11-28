import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'binding.dart';
import 'document.dart';
import 'store.dart';

Future<SubtitleRevision?> readArchivedSubtitles(Directory directory) async {
  final acbf = File(path.join(directory.path, 'book.acbf'));
  final manifest = File(path.join(directory.path, 'book.pages.json'));
  if (!await acbf.exists() || !await manifest.exists()) return null;
  if (await acbf.length() + await manifest.length() >
      const SubtitleLimits().bytes) {
    throw const FormatException('Subtitle files exceed the size limit');
  }
  return SubtitleRevision(
    await acbf.readAsBytes(),
    await manifest.readAsBytes(),
    {},
    null,
  );
}

Future<File> writeSubtitleArchive(
  Directory workspace,
  SubtitleRevision revision,
  List<SubtitleBinding> bindings,
  List<SubtitleFile> chapter,
) async {
  if (revision.manifest == null ||
      bindings.any((binding) => binding.selected == null)) {
    throw const FormatException(
      'Export requires a manifest and all original pages',
    );
  }
  final names = <String, String>{};
  final target = File(path.join(workspace.path, 'chapter.cbz'));
  final encoder = ZipFileEncoder()..create(target.path);
  try {
    for (final (index, page) in chapter.indexed) {
      final original = File(page.path);
      final ext = path.extension(original.path).toLowerCase();
      if (!RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(ext)) {
        throw const FormatException('Invalid page extension');
      }
      final name = '${(index + 1).toString().padLeft(4, '0')}$ext';
      final staged = await original.copy(path.join(workspace.path, name));
      if ((await sha256.bind(staged.openRead()).first).toString() !=
          page.digest) {
        throw const FormatException('Original page bytes changed');
      }
      await encoder.addFile(staged, name, ZipFileEncoder.store);
      await staged.delete();
      names[page.path] = name;
    }
    final files = rewriteSubtitleReferences(revision.acbf, revision.manifest!, [
      for (final binding in bindings) names[binding.selected!.path]!,
    ]);
    encoder.addArchiveFile(ArchiveFile.bytes('book.acbf', files.acbf));
    encoder.addArchiveFile(
      ArchiveFile.bytes('book.pages.json', files.manifest),
    );
  } finally {
    await encoder.close();
  }
  return target;
}
