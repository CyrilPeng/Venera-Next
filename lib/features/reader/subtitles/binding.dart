import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'document.dart';

typedef SubtitleFile = ({String path, String digest, int number});
typedef SubtitleChoice = ({String path, String digest});

Future<List<SubtitleFile>> fingerprintSubtitleImages(
  List<String> images,
) async {
  final files = <SubtitleFile>[];
  for (final (index, image) in images.indexed) {
    if (!image.startsWith('file://')) continue;
    final name = image.substring(7);
    final file = File(name);
    if (!await file.exists()) continue;
    final handle = await file.open();
    try {
      final length = await handle.length();
      var read = 0;
      Stream<List<int>> chunks() async* {
        while (true) {
          final bytes = await handle.read(256 << 10);
          if (bytes.isEmpty) break;
          read += bytes.length;
          yield bytes;
        }
      }

      final digest = await sha256.bind(chunks()).first;
      if (read == 0 || (length > 0 && read != length)) {
        throw FileSystemException('Incomplete page read', name);
      }
      files.add((path: name, digest: digest.toString(), number: index + 1));
    } finally {
      await handle.close();
    }
  }
  return files;
}

class SubtitleBinding {
  const SubtitleBinding(this.page, this.candidates, this.selected);
  final SubtitlePage page;
  final List<SubtitleFile> candidates;
  final SubtitleFile? selected;
}

List<SubtitleBinding> bindSubtitlePages(
  SubtitleDocument document,
  List<SubtitleFile> files,
  Map<String, SubtitleChoice> choices,
) {
  final byDigest = <String, List<SubtitleFile>>{};
  for (final file in files) {
    (byDigest[file.digest] ??= []).add(file);
  }
  final multiplicity = <String?, int>{};
  for (final page in document.pages) {
    multiplicity.update(page.digest, (count) => count + 1, ifAbsent: () => 1);
  }
  final bindings = <SubtitleBinding>[];
  final used = <String, int>{};
  for (final page in document.pages) {
    final saved = choices[page.id];
    final digest = page.digest ?? saved?.digest;
    final candidates = digest == null
        ? files
        : byDigest[digest] ?? const <SubtitleFile>[];
    final selected =
        candidates
            .where(
              (file) =>
                  file.path == saved?.path && file.digest == saved?.digest,
            )
            .firstOrNull ??
        (digest != null &&
                candidates.length == 1 &&
                multiplicity[page.digest] == 1
            ? candidates.single
            : null);
    if (selected != null) {
      used.update(selected.path, (count) => count + 1, ifAbsent: () => 1);
    }
    bindings.add(SubtitleBinding(page, candidates, selected));
  }
  return [
    for (final binding in bindings)
      if (binding.selected != null && used[binding.selected!.path]! > 1)
        SubtitleBinding(binding.page, binding.candidates, null)
      else
        binding,
  ];
}

String subtitleFileLabel(SubtitleFile file) =>
    '${file.number} · ${path.basename(file.path)}';
