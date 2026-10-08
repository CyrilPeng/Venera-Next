import 'dart:io';

import 'package:path/path.dart' as p;

/// File/process boundary for editing. All paths belong to the caller's
/// captured session; no late operation resolves the application's paths again.
class SourceScriptFiles {
  const SourceScriptFiles();

  Future<String> read(String path) => File(path).readAsString();

  Future<String> createDraft({
    required String sourcePath,
    required String cachePath,
  }) async {
    final root = Directory(p.join(cachePath, 'source_edit'));
    await root.create(recursive: true);
    final directory = await root.createTemp('session-');
    final draft = await File(
      sourcePath,
    ).copy(p.join(directory.path, p.basename(sourcePath)));
    // An external editor can keep this file open after its reload dialog
    // closes, or even after launch reports failure. Leave it in the cache.
    return draft.path;
  }

  Future<void> openEditor(String path) async {
    final process = await Process.run('code', [path], runInShell: true);
    if (process.exitCode != 0) throw process.stderr.toString();
  }
}
